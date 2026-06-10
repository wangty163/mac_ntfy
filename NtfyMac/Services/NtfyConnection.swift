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

@MainActor
final class NtfyConnection {
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
            do {
                setState(.connecting)
                try await streamOnce()
                // A normal stream end (server closed the connection) — reconnect
                // promptly without escalating the backoff.
                backoff = 1
            } catch is CancellationError {
                break
            } catch let error as NtfyError where error.isAuthFailure {
                // Bad credentials won't fix themselves by retrying; stop and
                // leave the error visible until the user edits the subscription
                // (which triggers an explicit restart).
                setState(.disconnected(reason: error.localizedDescription))
                return
            } catch {
                // Cancellation can surface as URLError(.cancelled) from
                // URLSession rather than CancellationError; don't let a stale
                // task overwrite the state a restarted connection just set.
                if Task.isCancelled { break }
                setState(.disconnected(reason: error.localizedDescription))
            }

            if Task.isCancelled { break }

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

    private func streamOnce() async throws {
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

        let (bytes, response) = try await session.bytes(for: request)

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

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            handle(line: line)
        }
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
