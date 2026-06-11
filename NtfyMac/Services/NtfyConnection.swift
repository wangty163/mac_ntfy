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
        NtfyURLSessionFactory.makeStreamingSession()
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
            guard LocalHostsResolver.shouldRetryWithHostsMapping(for: url, error: error) else {
                throw error
            }
            let mappedURL = LocalHostsResolver.mappedURL(for: url)
            try await stream(url: mappedURL.url, hostHeader: mappedURL.hostHeader)
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

/// Creates URLSession instances with explicit proxy settings for ntfy traffic.
///
/// Long-lived ntfy subscriptions are HTTP streams. When tools such as Clash
/// Verge enable the macOS system HTTP proxy, relying on URLSession's implicit
/// proxy discovery can be brittle for those streams: the short test request may
/// work while the streaming request never reaches the proxy path that supports
/// CONNECT/streaming correctly. Copy the active macOS proxy settings into each
/// fresh session so HTTP, HTTPS and SOCKS proxies are applied deliberately.
enum NtfyURLSessionFactory {
    static let userAgent = "NtfyMac/1.0"

    static func makeStreamingSession() -> URLSession {
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
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.connectionProxyDictionary = explicitProxyDictionary()
        return URLSession(configuration: config)
    }

    static func makeDataSession(timeout: TimeInterval = 60) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.connectionProxyDictionary = explicitProxyDictionary()
        return URLSession(configuration: config)
    }

    private static func explicitProxyDictionary() -> [AnyHashable: Any]? {
        guard let unmanagedSettings = CFNetworkCopySystemProxySettings() else {
            return nil
        }
        let settingsDictionary = unmanagedSettings.takeRetainedValue() as NSDictionary
        guard let systemSettings = settingsDictionary as? [String: Any] else {
            return nil
        }

        var proxy: [String: Any] = [:]
        copyProxy(
            from: systemSettings,
            to: &proxy,
            enable: kCFNetworkProxiesHTTPEnable,
            host: kCFNetworkProxiesHTTPProxy,
            port: kCFNetworkProxiesHTTPPort
        )
        copyProxy(
            from: systemSettings,
            to: &proxy,
            enable: kCFNetworkProxiesHTTPSEnable,
            host: kCFNetworkProxiesHTTPSProxy,
            port: kCFNetworkProxiesHTTPSPort
        )
        copyProxy(
            from: systemSettings,
            to: &proxy,
            enable: kCFNetworkProxiesSOCKSEnable,
            host: kCFNetworkProxiesSOCKSProxy,
            port: kCFNetworkProxiesSOCKSPort
        )
        copyValue(from: systemSettings, to: &proxy, key: kCFNetworkProxiesExceptionsList)
        copyValue(from: systemSettings, to: &proxy, key: kCFNetworkProxiesExcludeSimpleHostnames)

        // Some proxy apps expose a single HTTP proxy port and expect HTTPS to
        // use the same endpoint with CONNECT. Make that mapping explicit for
        // URLSession instead of leaving HTTPS streams to auto-detection.
        if proxy[kCFNetworkProxiesHTTPEnable as String] as? Int == 1,
           proxy[kCFNetworkProxiesHTTPSEnable as String] == nil,
           let httpHost = proxy[kCFNetworkProxiesHTTPProxy as String],
           let httpPort = proxy[kCFNetworkProxiesHTTPPort as String] {
            proxy[kCFNetworkProxiesHTTPSEnable as String] = 1
            proxy[kCFNetworkProxiesHTTPSProxy as String] = httpHost
            proxy[kCFNetworkProxiesHTTPSPort as String] = httpPort
        }

        if !proxy.isEmpty {
            return anyHashableDictionary(proxy)
        }

        // Fall back to the full system dictionary for PAC/WPAD-only setups.
        return systemSettings.isEmpty ? nil : anyHashableDictionary(systemSettings)
    }

    private static func copyProxy(
        from source: [String: Any],
        to destination: inout [String: Any],
        enable: CFString,
        host: CFString,
        port: CFString
    ) {
        let enableKey = enable as String
        let hostKey = host as String
        let portKey = port as String
        guard intValue(source[enableKey]) == 1,
              let proxyHost = source[hostKey],
              let proxyPort = source[portKey]
        else { return }

        destination[enableKey] = 1
        destination[hostKey] = proxyHost
        destination[portKey] = proxyPort
    }

    private static func copyValue(from source: [String: Any], to destination: inout [String: Any], key: CFString) {
        let stringKey = key as String
        if let value = source[stringKey] {
            destination[stringKey] = value
        }
    }

    private static func anyHashableDictionary(_ dictionary: [String: Any]) -> [AnyHashable: Any] {
        Dictionary(uniqueKeysWithValues: dictionary.map { (AnyHashable($0.key), $0.value) })
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
