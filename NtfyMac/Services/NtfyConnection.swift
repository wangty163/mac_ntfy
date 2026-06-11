//
//  NtfyConnection.swift
//  NtfyMac
//
//  Maintains a resilient ntfy subscription using finite poll requests to the
//  `/<topic>/json?poll=1` endpoint. Polling keeps traffic compatible with
//  local system proxies that can buffer or stall long-lived streaming responses,
//  while the reconnect loop survives network drops, server restarts and sleep.
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
        // Always use ntfy's finite poll endpoint. It still follows macOS system
        // proxy settings (so Clash Verge can route it), but unlike WebSocket or
        // HTTP streaming it never requires a local proxy to keep a long-lived
        // response open without buffering/stalling.
        try await pollLoop()
    }

    private func pollLoop() async throws {
        while !Task.isCancelled {
            guard let url = subscription.streamURL(forcePoll: true) else {
                throw URLError(.badURL)
            }

            try await pollOnce(url: url)

            if Task.isCancelled { break }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func pollOnce(url: URL) async throws {
        do {
            try await poll(url: url)
        } catch {
            guard LocalHostsResolver.shouldRetryWithHostsMapping(for: url, error: error) else {
                throw error
            }
            let mappedURL = LocalHostsResolver.mappedURL(for: url)
            try await poll(url: mappedURL.url, hostHeader: mappedURL.hostHeader)
        }
    }

    private func poll(url: URL, hostHeader: String? = nil) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let hostHeader {
            request.setValue(hostHeader, forHTTPHeaderField: "Host")
        }
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let session = NtfyURLSessionFactory.makeSession(
            timeoutForRequest: 15,
            timeoutForResource: 30
        )
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        if !state.isConnected { setState(.connected) }

        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            if Task.isCancelled { break }
            handle(line: line)
        }
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }

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
        if let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any] {
            config.connectionProxyDictionary = proxySettings
        }
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
