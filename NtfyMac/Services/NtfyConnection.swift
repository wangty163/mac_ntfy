//
//  NtfyConnection.swift
//  NtfyMac
//
//  Maintains one long-lived streaming connection to an ntfy topic's
//  `/<topic>/json` endpoint. The server emits newline-delimited JSON; we read
//  it line-by-line and reconnect automatically with exponential backoff so the
//  subscription survives network drops, server restarts and system sleep.
//

import Foundation
import os

@MainActor
final class NtfyConnection {
    /// Diagnostics: `log stream --predicate 'subsystem == "com.ntfymac"' --info`
    private static let log = Logger(subsystem: "com.ntfymac", category: "connection")

    let subscriptionID: UUID
    private(set) var subscription: Subscription
    private(set) var state: ConnectionState = .idle

    /// Called for every real `message` event (control events are filtered out).
    var onMessage: ((NtfyMessage) -> Void)?
    /// Called whenever the connection state changes (for UI badges).
    var onStateChange: ((ConnectionState) -> Void)?

    private var task: Task<Void, Never>?

    init(subscription: Subscription) {
        self.subscriptionID = subscription.id
        self.subscription = subscription
    }

    /// A fresh session per connection attempt. Reusing one session across
    /// reconnects can hand us a half-dead pooled connection after a network
    /// change, which then stalls until it times out.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // ntfy sends a keepalive roughly every 45s; if we miss two in a row the
        // connection is dead — fail the request so the loop reconnects, instead
        // of stalling for minutes on a silently broken socket.
        config.timeoutIntervalForRequest = 100
        config.timeoutIntervalForResource = .infinity
        // Never let URLSession park the request waiting for connectivity: its
        // connectivity assessment can be wrong (VPN/Wi-Fi transitions), leaving
        // us stuck in "Connecting…" forever while the network actually works.
        // Our own retry loop handles waiting and backoff.
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "NtfyMac/1.0"]
        return URLSession(configuration: config)
    }

    func updateSubscription(_ sub: Subscription) {
        subscription = sub
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        setState(.idle)
    }

    /// Restart the connection immediately (e.g. after network/sleep changes or
    /// a settings edit).
    func restart() {
        stop()
        start()
    }

    // MARK: - Reconnect loop

    private func runLoop() async {
        var backoff: TimeInterval = 1
        let maxBackoff: TimeInterval = 30

        while !Task.isCancelled {
            var establishedAt: Date?

            do {
                setState(.connecting)
                try await streamOnce { establishedAt = Date() }
                // A normal stream end (server closed the connection) — reconnect
                // promptly without escalating the backoff.
                backoff = 1
            } catch is CancellationError {
                break
            } catch let error as NtfyError where error.isAuthFailure {
                if Task.isCancelled { break }
                // Usually bad credentials, but reverse proxies can also return
                // transient 401/403s while the server itself is fine — keep
                // retrying at the slowest cadence instead of giving up for
                // good, and leave the reason visible in the UI meanwhile.
                Self.log.error("[\(self.subscription.topic, privacy: .public)] auth failed: \(error.localizedDescription, privacy: .public)")
                setState(.disconnected(reason: error.localizedDescription))
                backoff = maxBackoff
            } catch {
                // Cancellation can surface as URLError(.cancelled) from
                // URLSession rather than CancellationError; don't let a stale
                // task overwrite the state a restarted connection just set.
                if Task.isCancelled { break }
                Self.log.error("[\(self.subscription.topic, privacy: .public)] stream failed: \(error.localizedDescription, privacy: .public)")
                setState(.disconnected(reason: error.localizedDescription))
            }

            if Task.isCancelled { break }

            // A stream that lived for a while means this failure is a fresh
            // outage, not an escalating one — start the backoff over so a
            // long-lived stream that drops reconnects in ~1s instead of
            // inheriting a delay escalated by failures from hours ago.
            if let establishedAt, Date().timeIntervalSince(establishedAt) >= 30 {
                backoff = 1
            }

            let jitter = Double.random(in: 0...0.5)
            let wait = backoff + jitter
            setState(.reconnecting(nextAttempt: Date().addingTimeInterval(wait)))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            backoff = min(backoff * 2, maxBackoff)
        }
        // No trailing setState(.idle): the loop only exits on cancellation, and
        // stop() already set .idle. Setting it here would race with a restarted
        // connection that has since moved to .connecting.
    }

    /// Connects once and reads the stream until it ends or fails.
    /// `onEstablished` fires after the server has accepted the request.
    private func streamOnce(onEstablished: () -> Void) async throws {
        guard let url = subscription.streamURL() else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 100
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }

        Self.log.info("[\(self.subscription.topic, privacy: .public)] connecting to \(url.absoluteString, privacy: .public)")

        // Race the handshake against a short timeout. The 100s request timeout
        // is sized for missed keepalives on an established stream; a hung
        // *connection attempt* (stale route, dead DNS, half-open socket) should
        // fail in seconds and retry, not occupy "Connecting…" for minutes.
        let (bytes, response) = try await withThrowingTaskGroup(
            of: (URLSession.AsyncBytes, URLResponse).self
        ) { group in
            group.addTask {
                try await session.bytes(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw URLError(.timedOut)
            }
            guard let first = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return first
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            switch http.statusCode {
            case 401, 403:
                throw NtfyError.unauthorized("Authentication failed (\(http.statusCode))")
            case 404:
                throw NtfyError.http("Topic or server not found (404)")
            case 429:
                throw NtfyError.http("Rate limited (429)")
            default:
                throw NtfyError.http("Server returned HTTP \(http.statusCode)")
            }
        }

        onEstablished()
        Self.log.info("[\(self.subscription.topic, privacy: .public)] stream established")

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            handle(line: line)
        }

        Self.log.info("[\(self.subscription.topic, privacy: .public)] stream closed by server")
    }

    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        guard let event = try? JSONDecoder().decode(NtfyMessage.self, from: data) else { return }

        switch event.event {
        case .open:
            setState(.connected)
        case .keepalive:
            // Connection is healthy; make sure UI reflects "connected".
            if !state.isConnected { setState(.connected) }
        case .message:
            if !state.isConnected { setState(.connected) }
            onMessage?(event)
        case .pollRequest, .messageDelete, .messageClear, .unknown:
            break
        }
    }

    private func setState(_ newState: ConnectionState) {
        state = newState
        onStateChange?(newState)
    }
}

enum NtfyError: LocalizedError {
    case http(String)
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case let .http(reason): return reason
        case let .unauthorized(reason): return reason
        }
    }

    /// Authentication/permission failures that won't be fixed by reconnecting.
    var isAuthFailure: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}
