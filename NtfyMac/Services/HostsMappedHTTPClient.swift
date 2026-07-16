//
//  HostsMappedHTTPClient.swift
//  NtfyMac
//
//  A small direct HTTP/1.1 transport with explicit Happy Eyeballs address
//  racing. URLSession does not expose the address it selected or let callers
//  separate that address from the TLS server name, which makes intermittent
//  IPv6/DNS failures difficult to recover from and diagnose.
//
//  Network.framework does expose that separation: NWConnection dials the
//  mapped IP while sec_protocol_options_set_tls_server_name keeps SNI and
//  certificate verification bound to the original hostname.
//


import Foundation
import Network
import Security

enum HostsMappedHTTPClient {
    enum ResolverSource: String {
        case hosts = "/etc/hosts"
        case dns = "System DNS"
        case literal = "Literal address"
    }

    struct Candidate: Equatable {
        let address: String

        var family: String { address.contains(":") ? "IPv6" : "IPv4" }
    }

    struct Endpoint {
        let candidates: [Candidate]
        let port: UInt16
        let originalHost: String
        let usesTLS: Bool
        let resolverSource: ResolverSource
    }

    struct ConnectionInfo: Equatable {
        let address: String
        let family: String
        let resolverSource: String
        let candidates: [String]
        let tlsServerName: String?
        let latencyMilliseconds: Int
    }

    struct ResponseHead {
        let statusCode: Int
        let headers: [String: String]
        var connectionInfo: ConnectionInfo? = nil
    }

    enum ClientError: LocalizedError {
        case invalidEndpoint
        case invalidRequest(String)
        case timedOut
        case connectionClosed
        case invalidResponse(String)
        case truncatedResponse
        case network(NWError)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "The direct server address is invalid"
            case .invalidRequest(let reason):
                return "Could not build the direct request: \(reason)"
            case .timedOut:
                return "The direct connection timed out"
            case .connectionClosed:
                return "The direct connection closed unexpectedly"
            case .invalidResponse(let reason):
                return "The server returned an invalid HTTP response: \(reason)"
            case .truncatedResponse:
                return "The direct HTTP response ended unexpectedly"
            case .network(let error):
                return error.localizedDescription
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.ntfymac.direct-http-client")
    private static let headerTerminator = Data([13, 10, 13, 10])

    /// Resolves every candidate address for a Direct-mode request. `/etc/hosts`
    /// remains authoritative; otherwise a fresh system lookup is used so every
    /// reconnect gets a current IPv4/IPv6 candidate set.
    static func endpoint(for url: URL) async -> Endpoint? {
        let scheme = url.scheme?.lowercased()
        let portValue = url.port ?? (scheme == "http" ? 80 : 443)
        guard ProxyConfig.current().mode == .direct,
              scheme == "https" || scheme == "http",
              let host = url.host,
              (1...65535).contains(portValue)
        else {
            return nil
        }

        let resolution = await EndpointResolver.resolveCandidates(for: host)
        guard !resolution.addresses.isEmpty else { return nil }

        return Endpoint(
            candidates: happyEyeballsOrder(resolution.addresses).map(Candidate.init),
            port: UInt16(portValue),
            originalHost: host,
            usesTLS: scheme == "https",
            resolverSource: resolution.source
        )
    }

    /// Runs a long-lived response and emits decoded HTTP body bytes. HTTP/1.1
    /// chunk framing is removed before body data reaches the caller.
    static func stream(
        request: URLRequest,
        endpoint: Endpoint,
        onConnected: (ConnectionInfo) -> Void = { _ in },
        onResponse: (ResponseHead) throws -> Void,
        onBody: (Data) -> Void
    ) async throws {
        let connected = try await connect(to: endpoint)
        let connection = connected.connection
        defer { connection.cancel() }

        onConnected(connected.info)
        try Task.checkCancellation()
        try await send(serialize(request, endpoint: endpoint, keepAlive: true), over: connection)

        let (head, initialBody) = try await receiveHead(from: connection)
        try onResponse(head)

        var decoder = try BodyDecoder(headers: head.headers)
        if !initialBody.isEmpty {
            try decoder.append(initialBody, emit: onBody)
        }

        while !decoder.isFinished {
            try Task.checkCancellation()
            let part = try await receive(from: connection)
            if !part.data.isEmpty {
                try decoder.append(part.data, emit: onBody)
            }
            if part.isComplete {
                try decoder.finishAtEOF(emit: onBody)
                return
            }
        }
    }

    /// Sends a finite request and returns as soon as the response headers are
    /// available. Publish and poll/Test calls only need the HTTP status.
    static func request(_ request: URLRequest, endpoint: Endpoint) async throws -> ResponseHead {
        let connected = try await connect(to: endpoint)
        let connection = connected.connection
        defer { connection.cancel() }

        try Task.checkCancellation()
        try await send(serialize(request, endpoint: endpoint, keepAlive: false), over: connection)
        var (head, _) = try await receiveHead(from: connection)
        head.connectionInfo = connected.info
        return head
    }

    private struct ConnectedSocket {
        let connection: NWConnection
        let info: ConnectionInfo
    }

    private enum AttemptResult {
        case success(ConnectedSocket)
        case failure(Error)
    }

    /// Starts candidates 250 ms apart and keeps the first connection that
    /// completes TCP + TLS. Losing attempts are cancelled before this returns.
    private static func connect(to endpoint: Endpoint) async throws -> ConnectedSocket {
        guard !endpoint.candidates.isEmpty else { throw ClientError.invalidEndpoint }

        return try await withThrowingTaskGroup(of: AttemptResult.self) { group in
            for (index, candidate) in endpoint.candidates.enumerated() {
                group.addTask {
                    do {
                        if index > 0 {
                            try await Task.sleep(
                                nanoseconds: UInt64(index) * 250_000_000
                            )
                        }
                        try Task.checkCancellation()
                        let connection = try makeConnection(to: candidate, endpoint: endpoint)
                        let startedAt = ContinuousClock.now
                        do {
                            try await start(connection)
                        } catch {
                            connection.cancel()
                            throw error
                        }
                        let elapsed = startedAt.duration(to: .now)
                        let milliseconds = max(0, Int(elapsed.components.seconds * 1_000)
                            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
                        return .success(ConnectedSocket(
                            connection: connection,
                            info: ConnectionInfo(
                                address: candidate.address,
                                family: candidate.family,
                                resolverSource: endpoint.resolverSource.rawValue,
                                candidates: endpoint.candidates.map(\.address),
                                tlsServerName: endpoint.usesTLS
                                    && !EndpointResolver.isIPAddress(endpoint.originalHost)
                                    ? endpoint.originalHost : nil,
                                latencyMilliseconds: milliseconds
                            )
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var lastError: Error = ClientError.connectionClosed
            while let result = try await group.next() {
                switch result {
                case .success(let connected):
                    group.cancelAll()
                    return connected
                case .failure(let error):
                    if error is CancellationError, Task.isCancelled {
                        throw CancellationError()
                    }
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func makeConnection(to candidate: Candidate, endpoint: Endpoint) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw ClientError.invalidEndpoint
        }

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.keepaliveInterval = 20

        let parameters: NWParameters
        if endpoint.usesTLS {
            let tls = NWProtocolTLS.Options()
            if !EndpointResolver.isIPAddress(endpoint.originalHost) {
                sec_protocol_options_set_tls_server_name(
                    tls.securityProtocolOptions,
                    endpoint.originalHost
                )
            }
            // The parser below is deliberately HTTP/1.1-only.
            sec_protocol_options_add_tls_application_protocol(
                tls.securityProtocolOptions,
                "http/1.1"
            )
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }

        return NWConnection(
            host: NWEndpoint.Host(candidate.address),
            port: port,
            using: parameters
        )
    }

    /// Preserve the resolver's preferred family, then alternate IPv6 and IPv4
    /// so a run of unreachable addresses from one family cannot delay the other.
    static func happyEyeballsOrder(_ addresses: [String]) -> [String] {
        var unique: [String] = []
        for address in addresses where !unique.contains(address) { unique.append(address) }
        guard let first = unique.first else { return [] }

        var ipv6 = unique.filter { $0.contains(":") }
        var ipv4 = unique.filter { !$0.contains(":") }
        let startsWithIPv6 = first.contains(":")
        var ordered: [String] = []
        while !ipv6.isEmpty || !ipv4.isEmpty {
            if startsWithIPv6 {
                if !ipv6.isEmpty { ordered.append(ipv6.removeFirst()) }
                if !ipv4.isEmpty { ordered.append(ipv4.removeFirst()) }
            } else {
                if !ipv4.isEmpty { ordered.append(ipv4.removeFirst()) }
                if !ipv6.isEmpty { ordered.append(ipv6.removeFirst()) }
            }
        }
        return ordered
    }

    private static func start(_ connection: NWConnection) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await startWithoutTimeout(connection)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw ClientError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ClientError.connectionClosed
            }
            return result
        }
    }

    private static func startWithoutTimeout(_ connection: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: ClientError.network(error))
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    case .setup, .preparing, .waiting:
                        break
                    @unknown default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func send(_ data: Data, over connection: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: ClientError.network(error))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private struct ReceivedPart {
        let data: Data
        let isComplete: Bool
    }

    private static func receive(from connection: NWConnection) async throws -> ReceivedPart {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: ClientError.network(error))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: ReceivedPart(data: data, isComplete: isComplete))
                    } else if isComplete {
                        continuation.resume(returning: ReceivedPart(data: Data(), isComplete: true))
                    } else {
                        continuation.resume(throwing: ClientError.connectionClosed)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private struct HeadAndBody {
        let head: ResponseHead
        let body: Data
    }

    private static func receiveHead(from connection: NWConnection) async throws -> (ResponseHead, Data) {
        try await withThrowingTaskGroup(of: HeadAndBody.self) { group in
            group.addTask {
                let result = try await receiveHeadWithoutTimeout(from: connection)
                return HeadAndBody(head: result.0, body: result.1)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw ClientError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ClientError.connectionClosed
            }
            return (result.head, result.body)
        }
    }

    private static func receiveHeadWithoutTimeout(
        from connection: NWConnection
    ) async throws -> (ResponseHead, Data) {
        var buffer = Data()

        while true {
            if let range = buffer.range(of: headerTerminator) {
                let headerData = buffer[..<range.lowerBound]
                let bodyStart = range.upperBound
                let body = bodyStart < buffer.endIndex ? Data(buffer[bodyStart...]) : Data()
                return (try parseHead(Data(headerData)), body)
            }
            guard buffer.count <= 64 * 1024 else {
                throw ClientError.invalidResponse("headers exceed 64 KiB")
            }

            let part = try await receive(from: connection)
            buffer.append(part.data)
            if part.isComplete {
                throw ClientError.truncatedResponse
            }
        }
    }

    private static func parseHead(_ data: Data) throws -> ResponseHead {
        guard let string = String(data: data, encoding: .isoLatin1) else {
            throw ClientError.invalidResponse("headers are not ISO-8859-1")
        }
        let lines = string.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ClientError.invalidResponse("missing status line")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/1."),
              let statusCode = Int(statusParts[1])
        else {
            throw ClientError.invalidResponse("invalid status line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw ClientError.invalidResponse("malformed header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return ResponseHead(statusCode: statusCode, headers: headers)
    }

    private static func serialize(
        _ request: URLRequest,
        endpoint: Endpoint,
        keepAlive: Bool
    ) throws -> Data {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw ClientError.invalidRequest("missing URL")
        }

        let method = request.httpMethod ?? "GET"
        var target = components.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            target += "?" + query
        }
        guard !method.containsNewline, !target.containsNewline else {
            throw ClientError.invalidRequest("invalid method or request target")
        }

        let headerHost = endpoint.originalHost.contains(":")
            ? "[\(endpoint.originalHost)]" : endpoint.originalHost
        let defaultPort = endpoint.usesTLS ? 443 : 80
        let hostHeader: String
        if let explicitPort = url.port, explicitPort != defaultPort {
            hostHeader = "\(headerHost):\(explicitPort)"
        } else {
            hostHeader = headerHost
        }

        var lines = [
            "\(method) \(target) HTTP/1.1",
            "Host: \(hostHeader)",
            "Connection: \(keepAlive ? "keep-alive" : "close")",
            "Accept-Encoding: identity",
        ]

        var hasUserAgent = false
        var hasAccept = false
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if ["host", "connection", "content-length", "accept-encoding"].contains(lower) {
                continue
            }
            guard !name.containsNewline, !value.containsNewline else {
                throw ClientError.invalidRequest("invalid header")
            }
            if lower == "user-agent" { hasUserAgent = true }
            if lower == "accept" { hasAccept = true }
            lines.append("\(name): \(value)")
        }
        if !hasUserAgent { lines.append("User-Agent: NtfyMac/1.0") }
        if !hasAccept { lines.append("Accept: */*") }

        let body = request.httpBody ?? Data()
        if request.httpBody != nil {
            lines.append("Content-Length: \(body.count)")
        }

        guard var result = (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8) else {
            throw ClientError.invalidRequest("headers are not UTF-8")
        }
        result.append(body)
        return result
    }

    private struct BodyDecoder {
        private enum Mode {
            case chunked
            case contentLength(Int)
            case untilEOF
        }

        private enum ChunkState {
            case size
            case data(Int)
            case trailers
            case finished
        }

        private let mode: Mode
        private var buffer = Data()
        private var chunkState: ChunkState = .size
        private var remainingLength: Int = 0
        private(set) var isFinished = false

        init(headers: [String: String]) throws {
            let transferEncoding = headers["transfer-encoding"]?.lowercased() ?? ""
            if transferEncoding.split(separator: ",").contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == "chunked"
            }) {
                mode = .chunked
            } else if let rawLength = headers["content-length"] {
                guard let length = Int(rawLength.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                    throw ClientError.invalidResponse("invalid Content-Length")
                }
                mode = .contentLength(length)
                remainingLength = length
                isFinished = length == 0
            } else {
                mode = .untilEOF
            }
        }

        mutating func append(_ data: Data, emit: (Data) -> Void) throws {
            guard !isFinished else { return }
            buffer.append(data)

            switch mode {
            case .chunked:
                try decodeChunks(emit: emit)
            case .contentLength:
                let count = min(remainingLength, buffer.count)
                if count > 0 {
                    emit(Data(buffer.prefix(count)))
                    buffer.removeFirst(count)
                    remainingLength -= count
                }
                if remainingLength == 0 { isFinished = true }
            case .untilEOF:
                if !buffer.isEmpty {
                    emit(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }

        mutating func finishAtEOF(emit: (Data) -> Void) throws {
            switch mode {
            case .untilEOF:
                if !buffer.isEmpty { emit(buffer) }
                buffer.removeAll()
                isFinished = true
            case .chunked, .contentLength:
                guard isFinished else { throw ClientError.truncatedResponse }
            }
        }

        private mutating func decodeChunks(emit: (Data) -> Void) throws {
            let crlf = Data([13, 10])

            while !isFinished {
                switch chunkState {
                case .size:
                    guard let range = buffer.range(of: crlf) else {
                        guard buffer.count <= 4096 else {
                            throw ClientError.invalidResponse("chunk-size line is too long")
                        }
                        return
                    }
                    let rawLine = buffer[..<range.lowerBound]
                    buffer.removeSubrange(..<range.upperBound)
                    guard let line = String(data: rawLine, encoding: .ascii),
                          let sizeToken = line.split(separator: ";", maxSplits: 1).first,
                          let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16),
                          size >= 0
                    else {
                        throw ClientError.invalidResponse("invalid chunk size")
                    }
                    chunkState = size == 0 ? .trailers : .data(size)

                case .data(let size):
                    guard buffer.count >= size + 2 else { return }
                    emit(Data(buffer.prefix(size)))
                    buffer.removeFirst(size)
                    guard buffer.starts(with: crlf) else {
                        throw ClientError.invalidResponse("missing chunk terminator")
                    }
                    buffer.removeFirst(2)
                    chunkState = .size

                case .trailers:
                    if buffer.starts(with: crlf) {
                        buffer.removeFirst(2)
                        chunkState = .finished
                        isFinished = true
                    } else if let range = buffer.range(of: HostsMappedHTTPClient.headerTerminator) {
                        buffer.removeSubrange(..<range.upperBound)
                        chunkState = .finished
                        isFinished = true
                    } else {
                        guard buffer.count <= 64 * 1024 else {
                            throw ClientError.invalidResponse("trailers exceed 64 KiB")
                        }
                        return
                    }

                case .finished:
                    isFinished = true
                }
            }
        }
    }
}

private extension String {
    var containsNewline: Bool {
        contains("\r") || contains("\n")
    }
}
