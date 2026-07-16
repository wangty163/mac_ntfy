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
    private(set) var diagnostics = ConnectionDiagnostics()

    /// Called for every real `message` event (control events are filtered out).
    var onMessage: ((NtfyMessage) -> Void)?
    /// Called whenever the connection state changes (for UI badges).
    var onStateChange: ((ConnectionState) -> Void)?
    /// Called when transport/address/event timing details change.
    var onDiagnosticsChange: ((ConnectionDiagnostics) -> Void)?
    /// Called when the server rejects the persisted `since` cursor, usually
    /// because the message ID has fallen out of the server-side cache.
    var onCursorInvalidated: (() -> Void)?

    private var task: Task<Void, Never>?

    init(subscription: Subscription) {
        self.subscriptionID = subscription.id
        self.subscription = subscription
        diagnostics.tlsServerName = URL(string: subscription.normalizedBaseURL)?.scheme == "https"
            ? subscription.serverHost
            : nil
    }

    /// A fresh session per connection attempt. Reusing one session across
    /// reconnects can hand us a half-dead pooled connection after a network
    /// change, which then stalls until it times out.
    ///
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
        // Explicit proxy mode instead of system-proxy auto-detection; tools
        // like Clash in system-proxy mode break long-lived streams even when
        // their own rules say DIRECT. See ProxyConfig.
        ProxyConfig.current().apply(to: config)
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
                diagnostics.nextRetryAt = nil
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
                recordFailure(error)
                backoff = 1
                continue
            } catch let error as NtfyError where error.isAuthFailure {
                // Bad credentials won't fix themselves by retrying; stop and
                // leave the error visible until the user edits the subscription
                // (which triggers an explicit restart).
                recordFailure(error)
                setState(.disconnected(reason: error.localizedDescription))
                return
            } catch {
                // Cancellation can surface as URLError(.cancelled) from
                // URLSession rather than CancellationError; don't let a stale
                // task overwrite the state a restarted connection just set.
                if Task.isCancelled { break }
                recordFailure(error)
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

        // In Direct mode, resolve all IPv4/IPv6 candidates and race them through
        // Network.framework while retaining the original hostname for TLS SNI.
        // `/etc/hosts` remains authoritative when it contains this hostname.
        if let endpoint = await HostsMappedHTTPClient.endpoint(for: url) {
            prepareDiagnostics(for: endpoint)
            try await stream(requestURL: url, through: endpoint)
            return
        }

        prepareURLSessionDiagnostics(for: url)
        try await stream(url: url)
    }

    private func stream(
        requestURL url: URL,
        through endpoint: HostsMappedHTTPClient.Endpoint
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 100
        request.setValue("NtfyMac/1.0", forHTTPHeaderField: "User-Agent")
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        var lines = NDJSONLineBuffer()
        try await HostsMappedHTTPClient.stream(
            request: request,
            endpoint: endpoint,
            onConnected: { info in
                self.recordConnected(info)
            },
            onResponse: { response in
                try self.validateHTTPStatus(response.statusCode)
            },
            onBody: { data in
                lines.append(data) { line in
                    self.handle(line: line)
                }
            }
        )
        lines.finish { line in
            handle(line: line)
        }
    }

    private func stream(url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 100
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)

        if let http = response as? HTTPURLResponse {
            try validateHTTPStatus(http.statusCode)
        }

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            handle(line: line)
        }
    }

    private func validateHTTPStatus(_ statusCode: Int) throws {
        guard !(200...299).contains(statusCode) else { return }
        switch statusCode {
        case 400 where subscription.lastMessageID != nil:
            throw NtfyError.staleCursor
        case 401, 403:
            throw NtfyError.unauthorized("Authentication failed (\(statusCode))")
        case 404:
            throw NtfyError.http("Topic or server not found (404)")
        case 429:
            throw NtfyError.http("Rate limited (429)")
        default:
            throw NtfyError.http("Server returned HTTP \(statusCode)")
        }
    }

    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        guard let event = try? JSONDecoder().decode(NtfyMessage.self, from: data) else { return }

        switch event.event {
        case .open:
            diagnostics.connectedAt = Date()
            recordEvent(.open)
            setState(.connected)
        case .keepalive:
            recordEvent(.keepalive)
            // Connection is healthy; make sure UI reflects "connected".
            if !state.isConnected { setState(.connected) }
        case .message:
            recordEvent(.message)
            if !state.isConnected { setState(.connected) }
            onMessage?(event)
        case .pollRequest, .messageDelete, .messageClear, .unknown:
            break
        }
    }

    private func setState(_ newState: ConnectionState) {
        state = newState
        diagnostics.state = newState
        switch newState {
        case .idle:
            diagnostics.nextRetryAt = nil
        case .connected:
            diagnostics.retryCount = 0
            diagnostics.nextRetryAt = nil
            diagnostics.lastError = nil
        case .reconnecting(let nextAttempt):
            diagnostics.nextRetryAt = nextAttempt
        case .disconnected(let reason):
            diagnostics.lastError = reason
        case .connecting:
            diagnostics.remoteAddress = nil
            diagnostics.addressFamily = nil
            diagnostics.connectionLatencyMilliseconds = nil
        }
        onStateChange?(newState)
        publishDiagnostics()
    }

    private enum DiagnosticEvent {
        case open, keepalive, message
    }

    private func recordEvent(_ event: DiagnosticEvent) {
        let now = Date()
        diagnostics.lastEventAt = now
        switch event {
        case .open: break
        case .keepalive: diagnostics.lastKeepaliveAt = now
        case .message: diagnostics.lastMessageAt = now
        }
        publishDiagnostics()
    }

    private func recordFailure(_ error: Error) {
        diagnostics.retryCount += 1
        diagnostics.lastError = error.localizedDescription
        publishDiagnostics()
    }

    private func prepareDiagnostics(for endpoint: HostsMappedHTTPClient.Endpoint) {
        diagnostics.route = "Direct · Happy Eyeballs"
        diagnostics.resolverSource = endpoint.resolverSource.rawValue
        diagnostics.resolvedAddresses = endpoint.candidates.map(\.address)
        diagnostics.tlsServerName = endpoint.usesTLS
            && !EndpointResolver.isIPAddress(endpoint.originalHost)
            ? endpoint.originalHost : nil
        publishDiagnostics()
    }

    private func recordConnected(_ info: HostsMappedHTTPClient.ConnectionInfo) {
        diagnostics.remoteAddress = info.address
        diagnostics.addressFamily = info.family
        diagnostics.resolverSource = info.resolverSource
        diagnostics.resolvedAddresses = info.candidates
        diagnostics.tlsServerName = info.tlsServerName
        diagnostics.connectionLatencyMilliseconds = info.latencyMilliseconds
        publishDiagnostics()
    }

    private func prepareURLSessionDiagnostics(for url: URL) {
        let proxy = ProxyConfig.current()
        diagnostics.route = "\(proxy.mode.label) · URLSession"
        diagnostics.resolverSource = proxy.mode == .direct
            ? "System resolver fallback"
            : "Managed by \(proxy.mode.label.lowercased())"
        diagnostics.resolvedAddresses = []
        diagnostics.remoteAddress = nil
        diagnostics.addressFamily = nil
        diagnostics.tlsServerName = url.scheme?.lowercased() == "https" ? url.host : nil
        diagnostics.connectionLatencyMilliseconds = nil
        publishDiagnostics()
    }

    private func publishDiagnostics() {
        onDiagnosticsChange?(diagnostics)
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

/// Resolves the complete address set used by the direct Happy Eyeballs path.
/// `/etc/hosts` is authoritative; otherwise a fresh `getaddrinfo` lookup avoids
/// reusing URLSession's process-wide DNS/connection cache after network changes.
enum EndpointResolver {
    struct CandidateResolution {
        let addresses: [String]
        let source: HostsMappedHTTPClient.ResolverSource
    }

    /// Resolves all usable addresses for Happy Eyeballs. An explicit hosts entry
    /// is authoritative; otherwise `getaddrinfo` supplies the current system-DNS
    /// ordering. Literal addresses bypass resolution entirely.
    static func resolveCandidates(for host: String) async -> CandidateResolution {
        if isIPAddress(host) {
            return CandidateResolution(addresses: [host], source: .literal)
        }
        let mapped = hostsAddresses(for: host)
        if !mapped.isEmpty {
            return CandidateResolution(addresses: mapped, source: .hosts)
        }
        return CandidateResolution(addresses: await freshAddresses(for: host), source: .dns)
    }

    private static func freshAddresses(for host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: blockingResolveAll(host))
            }
        }
    }

    private static func blockingResolveAll(_ host: String) -> [String] {
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
        guard getaddrinfo(host, nil, &hints, &result) == 0, result != nil else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var node = result
        while let current = node {
            let info = current.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen,
                           &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: buffer)
                if (info.ai_family == AF_INET || info.ai_family == AF_INET6),
                   !addresses.contains(address) {
                    addresses.append(address)
                }
            }
            node = info.ai_next
        }
        return addresses
    }

    static func hostsAddresses(for host: String) -> [String] {
        guard let contents = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
            return []
        }
        let wanted = host.lowercased()
        var addresses: [String] = []

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let fields = line.split { $0 == " " || $0 == "\t" }.map(String.init)
            guard fields.count >= 2 else { continue }

            let address = fields[0]
            for alias in fields.dropFirst() where alias.lowercased() == wanted {
                if isIPAddress(address), !addresses.contains(address) {
                    addresses.append(address)
                }
            }
        }
        return addresses
    }

    static func isIPAddress(_ host: String) -> Bool {
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

/// Converts arbitrary HTTP/chunk boundaries into the NDJSON lines expected by
/// ntfy. A line can span any number of TCP or HTTP chunks.
private struct NDJSONLineBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data, handle: (String) -> Void) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            if let string = String(data: line, encoding: .utf8) {
                handle(string)
            }
        }
    }

    mutating func finish(handle: (String) -> Void) {
        guard !buffer.isEmpty else { return }
        if buffer.last == 13 { buffer.removeLast() }
        if let string = String(data: buffer, encoding: .utf8) {
            handle(string)
        }
        buffer.removeAll()
    }
}
