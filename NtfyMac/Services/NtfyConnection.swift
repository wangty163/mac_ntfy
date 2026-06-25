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
import Security

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
    ///
    /// `pinnedHost` is set when we connect to a raw IP (to bypass a stale DNS
    /// cache, see `EndpointResolver`): the TLS certificate is then evaluated
    /// against that original hostname instead of the IP we dialed.
    private static func makeSession(pinnedHost: String? = nil) -> URLSession {
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
        // Explicit proxy mode instead of system-proxy auto-detection; tools
        // like Clash in system-proxy mode break long-lived streams even when
        // their own rules say DIRECT. See ProxyConfig.
        ProxyConfig.current().apply(to: config)
        if let pinnedHost {
            return URLSession(
                configuration: config,
                delegate: HostnamePinningDelegate(expectedHost: pinnedHost),
                delegateQueue: nil
            )
        }
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
        guard let url = subscription.streamURL() else {
            throw URLError(.badURL)
        }

        do {
            try await stream(url: url)
        } catch {
            // A connection-level failure on an unchanged hostname can mean a
            // stale DNS cache or a host reachable only via /etc/hosts. Re-resolve
            // the host ourselves and retry the resolved IP directly, as a
            // fallback — the hostname attempt above is the normal path and keeps
            // TLS SNI correct for reverse proxies, so we only reach here when it
            // actually failed.
            guard EndpointResolver.shouldRetryWithResolvedAddress(for: url, error: error) else {
                throw error
            }
            let endpoint = await EndpointResolver.resolvedEndpoint(for: url)
            guard endpoint.hostHeader != nil else { throw error }
            try await stream(
                url: endpoint.url,
                hostHeader: endpoint.hostHeader,
                pinnedHost: endpoint.pinnedHostname
            )
        }
    }

    private func stream(url: URL, hostHeader: String? = nil, pinnedHost: String? = nil) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 100
        if let hostHeader {
            request.setValue(hostHeader, forHTTPHeaderField: "Host")
        }
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let session = Self.makeSession(pinnedHost: pinnedHost)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
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

/// Resolves a request's hostname to a concrete IP and rewrites the request to
/// dial that IP directly, while keeping the original HTTP `Host` header (and, for
/// HTTPS, validating the certificate against the original hostname).
///
/// Two problems this solves:
///   * **Stale DNS cache.** When a server's IP changes but its hostname does
///     not (dynamic DNS / failover), URLSession's process-wide DNS cache keeps
///     handing back the old, dead IP, so reconnects fail indefinitely even
///     though a browser — a separate process — connects fine. A fresh
///     `getaddrinfo` query honors the record TTL and returns the current IP.
///   * **`/etc/hosts` overrides.** Some self-hosted ntfy setups are only
///     reachable through a local hosts entry and otherwise fail with
///     `NSURLErrorNetworkConnectionLost` even though a browser can open the URL.
///
/// `/etc/hosts` takes precedence (it is an explicit user override); otherwise we
/// fall back to a fresh DNS lookup.
enum EndpointResolver {
    struct ResolvedEndpoint {
        var url: URL
        /// Original `host[:port]` to send as the `Host` header when we dial an IP.
        var hostHeader: String?
        /// Original hostname to validate the TLS certificate against (HTTPS only).
        var pinnedHostname: String?
    }

    /// Whether a failed request is worth retrying against a freshly-resolved IP.
    ///
    /// Restricted to **plain HTTP** on a hostname. Dialing a raw IP keeps the
    /// `Host` header but drops TLS SNI — an IP literal can't appear in SNI — so
    /// an HTTPS reverse proxy that selects its certificate or backend by SNI
    /// would route the request to the wrong place. HTTPS therefore always stays
    /// on the hostname, which already resolves through `/etc/hosts` via the
    /// system resolver — the same path the browser uses to reach the server.
    static func shouldRetryWithResolvedAddress(for url: URL, error: Error) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = url.host, !isIPAddress(host) else { return false }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// Resolve the URL's host to an IP, bypassing URLSession's DNS cache. Prefers
    /// an `/etc/hosts` override, otherwise performs a fresh `getaddrinfo` lookup.
    static func resolvedEndpoint(for url: URL) async -> ResolvedEndpoint {
        let unresolved = ResolvedEndpoint(url: url, hostHeader: nil, pinnedHostname: nil)
        guard let host = url.host, !isIPAddress(host) else { return unresolved }

        // `await` can't appear inside the `??` autoclosure, so fall back explicitly.
        var address = hostsAddress(for: host)
        if address == nil {
            address = await freshAddress(for: host)
        }
        guard let address else { return unresolved }
        return endpoint(for: url, host: host, dialing: address) ?? unresolved
    }

    /// Build an endpoint that dials `address` directly while preserving the
    /// original host for the `Host` header and (for HTTPS) certificate checks.
    private static func endpoint(for url: URL, host: String, dialing address: String) -> ResolvedEndpoint? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.host = address
        guard let resolvedURL = components.url else { return nil }

        return ResolvedEndpoint(
            url: resolvedURL,
            hostHeader: hostHeader(for: url, originalHost: host),
            // Only HTTPS needs certificate re-evaluation; plain HTTP does not.
            pinnedHostname: url.scheme?.lowercased() == "https" ? host : nil
        )
    }

    /// A fresh DNS lookup via `getaddrinfo`, run off the main thread. Unlike
    /// URLSession's cache, this re-queries the system resolver, so a changed IP
    /// behind an unchanged hostname is picked up once the record's TTL expires.
    private static func freshAddress(for host: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: blockingResolve(host))
            }
        }
    }

    private static func blockingResolve(_ host: String) -> String? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, result != nil else { return nil }
        defer { freeaddrinfo(result) }

        var ipv4: String?
        var ipv6: String?
        var node = result
        while let current = node {
            let info = current.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen,
                           &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: buffer)
                if info.ai_family == AF_INET {
                    if ipv4 == nil { ipv4 = address }
                } else if info.ai_family == AF_INET6 {
                    if ipv6 == nil { ipv6 = address }
                }
            }
            node = info.ai_next
        }
        // Prefer IPv4 to sidestep IPv6 literal/bracketing edge cases in URLs.
        return ipv4 ?? ipv6
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

/// Validates the TLS server certificate against an expected hostname rather than
/// the address URLSession actually connected to. Used when `EndpointResolver`
/// dials a raw IP to bypass a stale DNS cache: without this, URLSession would
/// evaluate the certificate against the IP and reject an otherwise-valid cert.
final class HostnamePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedHost: String

    init(expectedHost: String) {
        self.expectedHost = expectedHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Re-evaluate the presented chain against the original hostname.
        SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, expectedHost as CFString))
        if SecTrustEvaluateWithError(serverTrust, nil) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
