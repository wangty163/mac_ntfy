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
import CFNetwork

@MainActor
final class NtfyConnection {
    let subscriptionID: UUID
    private(set) var subscription: Subscription
    private(set) var state: ConnectionState = .idle

    /// Called for every real `message` event (control events are filtered out).
    var onMessage: ((NtfyMessage) -> Void)?
    /// Called whenever the connection state changes (for UI badges).
    var onStateChange: ((ConnectionState) -> Void)?
    /// Called when the server rejects the persisted `since` cursor, usually
    /// because the message ID has fallen out of the server-side cache.
    var onCursorInvalidated: (() -> Void)?

    private var task: Task<Void, Never>?

    init(subscription: Subscription) {
        self.subscriptionID = subscription.id
        self.subscription = subscription
    }

    /// A fresh session per connection attempt. Reusing one session across
    /// reconnects can hand us a half-dead pooled connection after a network
    /// change, which then stalls until it times out.
    private static func makeSession() -> URLSession {
        NtfyURLSessionFactory.makeSession(
            timeoutForRequest: 100,
            timeoutForResource: .infinity
        )
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
            } catch let error as NtfyError where error.isStaleCursor {
                // ntfy only caches messages for a limited time. If our saved
                // message ID is too old, the server can reject `since=<id>`.
                // Drop the cursor and retry immediately so the app can connect
                // instead of showing Offline forever while the server is fine.
                onCursorInvalidated?()
                backoff = 1
                continue
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
        guard let wsURL = subscription.webSocketURL(),
              let httpURL = subscription.streamURL() else {
            throw URLError(.badURL)
        }

        if NtfyURLSessionFactory.systemProxyIsConfigured() {
            // In Clash Verge rule mode, macOS exposes a system proxy even when a
            // particular destination is configured as DIRECT inside Clash. Long
            // lived HTTP/WebSocket streams can still be buffered or blocked by
            // that local proxy layer, while short browser requests work. Use
            // ntfy's finite poll endpoint in this mode so traffic still goes
            // through the proxy but never depends on a held-open stream.
            try await pollLoop()
            return
        }

        do {
            try await streamWebSocket(url: wsURL)
        } catch {
            if Task.isCancelled { throw error }
            // If a self-hosted server or proxy does not support WebSockets, fall
            // back to the original HTTP JSON stream. Both paths use the system
            // proxy, but WebSockets are preferred because proxies handle them as
            // upgrade tunnels instead of buffered HTTP responses.
            do {
                try await streamHTTPOnce(url: httpURL)
            } catch {
                if Task.isCancelled { throw error }
                try await pollLoop()
            }
        }
    }

    private func streamHTTPOnce(url: URL) async throws {
        do {
            try await stream(url: url)
        } catch {
            guard LocalHostsResolver.shouldRetryWithHostsMapping(for: url, error: error) else {
                throw error
            }
            let mappedURL = LocalHostsResolver.mappedURL(for: url)
            try await stream(url: mappedURL.url, hostHeader: mappedURL.hostHeader)
        }
    }

    private func pollLoop() async throws {
        while !Task.isCancelled {
            guard let url = subscription.streamURL(forcePoll: true) else {
                throw URLError(.badURL)
            }

            try await streamHTTPOnce(url: url)

            if Task.isCancelled { break }
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private func stream(url: URL, hostHeader: String? = nil) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 100
        if let hostHeader {
            request.setValue(hostHeader, forHTTPHeaderField: "Host")
        }
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)

        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                switch http.statusCode {
                case 400 where subscription.lastMessageID != nil:
                    throw NtfyError.staleCursor
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
        }

        if !state.isConnected { setState(.connected) }

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            handle(line: line)
        }
    }


    private func streamWebSocket(url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 100
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.setValue("NtfyMac/1.0", forHTTPHeaderField: "User-Agent")

        let session = Self.makeSession()
        let task = session.webSocketTask(with: request)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        while !Task.isCancelled {
            let message = try await task.receive()
            switch message {
            case let .string(text):
                handle(line: text)
            case let .data(data):
                if let text = String(data: data, encoding: .utf8) {
                    handle(line: text)
                }
            @unknown default:
                break
            }
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


/// Builds URLSession instances for ntfy server traffic. These sessions keep
/// macOS's system proxy settings enabled so users can route ntfy through Clash
/// Verge or another proxy, while still using bounded connectivity behavior.
enum NtfyURLSessionFactory {
    static func systemProxyIsConfigured() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return false
        }

        func isEnabled(_ key: String) -> Bool {
            (settings[key] as? NSNumber)?.boolValue == true
        }

        return isEnabled("HTTPEnable")
            || isEnabled("HTTPSEnable")
            || isEnabled("SOCKSEnable")
            || isEnabled("ProxyAutoConfigEnable")
    }

    static func makeSession(
        timeoutForRequest: TimeInterval,
        timeoutForResource: TimeInterval = 60
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutForRequest
        config.timeoutIntervalForResource = timeoutForResource
        // Never let URLSession park the request waiting for connectivity: its
        // connectivity assessment can be wrong (VPN/Wi-Fi transitions), leaving
        // us stuck in "Connecting…" forever while the network actually works.
        // Our own retry loop handles waiting and backoff.
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "NtfyMac/1.0"]
        return URLSession(configuration: config)
    }
}

enum NtfyError: LocalizedError {
    case http(String)
    case unauthorized(String)
    case staleCursor

    var errorDescription: String? {
        switch self {
        case let .http(reason): return reason
        case let .unauthorized(reason): return reason
        case .staleCursor:
            return "Saved sync cursor is no longer available on the server"
        }
    }

    /// Authentication/permission failures that won't be fixed by reconnecting.
    var isAuthFailure: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    /// A stale cursor is recoverable by clearing the saved last message ID.
    var isStaleCursor: Bool {
        if case .staleCursor = self { return true }
        return false
    }
}

/// Resolves hostnames explicitly from `/etc/hosts` and rewrites requests to the
/// mapped address while keeping the original HTTP Host header. URLSession
/// usually uses the system resolver, but some self-hosted ntfy setups are only
/// reachable through local hosts overrides and can otherwise fail with
/// `NSURLErrorNetworkConnectionLost` even though a browser can open the URL.
enum LocalHostsResolver {
    struct MappedURL {
        var url: URL
        var hostHeader: String?
    }

    static func shouldRetryWithHostsMapping(for url: URL, error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
            return mappedURL(for: url).hostHeader != nil
        default:
            return false
        }
    }

    static func mappedURL(for url: URL) -> MappedURL {
        guard let host = url.host,
              !isIPAddress(host),
              let address = hostsAddress(for: host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return MappedURL(url: url, hostHeader: nil)
        }

        components.host = address
        guard let resolvedURL = components.url else {
            return MappedURL(url: url, hostHeader: nil)
        }

        return MappedURL(
            url: resolvedURL,
            hostHeader: hostHeader(for: url, originalHost: host)
        )
    }

    private static func hostsAddress(for host: String) -> String? {
        guard let contents = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
            return nil
        }
        let wanted = host.lowercased()

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let fields = line.split { $0 == " " || $0 == "\t" }.map(String.init)
            guard fields.count >= 2 else { continue }

            let address = fields[0]
            for alias in fields.dropFirst() where alias.lowercased() == wanted {
                return address
            }
        }
        return nil
    }

    private static func hostHeader(for url: URL, originalHost: String) -> String {
        guard let port = url.port, !isDefaultPort(port, scheme: url.scheme) else {
            return originalHost
        }
        return "\(originalHost):\(port)"
    }

    private static func isDefaultPort(_ port: Int, scheme: String?) -> Bool {
        (scheme?.lowercased() == "http" && port == 80)
            || (scheme?.lowercased() == "https" && port == 443)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        isIPv4Address(host) || host.contains(":")
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
            return String(value) == part || part == "0"
        }
    }
}
