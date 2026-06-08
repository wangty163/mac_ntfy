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
    private let session: URLSession

    init(subscription: Subscription) {
        self.subscriptionID = subscription.id
        self.subscription = subscription

        let config = URLSessionConfiguration.default
        // Streaming connections must not time out while idle; ntfy sends a
        // keepalive roughly every 45s, but we allow generous slack.
        config.timeoutIntervalForRequest = 360
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = ["User-Agent": "NtfyMac/1.0"]
        self.session = URLSession(configuration: config)
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
            } catch {
                setState(.disconnected(reason: error.localizedDescription))
            }

            if Task.isCancelled { break }

            let jitter = Double.random(in: 0...0.5)
            let wait = backoff + jitter
            setState(.reconnecting(nextAttempt: Date().addingTimeInterval(wait)))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            backoff = min(backoff * 2, maxBackoff)
        }
        setState(.idle)
    }

    private func streamOnce() async throws {
        guard let url = subscription.streamURL() else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 360
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (bytes, response) = try await session.bytes(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let reason: String
            switch http.statusCode {
            case 401, 403: reason = "Authentication failed (\(http.statusCode))"
            case 404: reason = "Topic or server not found (404)"
            case 429: reason = "Rate limited (429)"
            default: reason = "Server returned HTTP \(http.statusCode)"
            }
            throw NtfyError.http(reason)
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

    var errorDescription: String? {
        switch self {
        case let .http(reason): return reason
        }
    }
}
