//
//  HostsMappedHTTPClient.swift
//  NtfyMac
//
//  A small HTTP/1.1 transport for HTTPS hosts that have an explicit
//  /etc/hosts mapping. URLSession cannot publicly separate the address it
//  dials from the TLS server name, so a stale/unreachable AAAA record can win
//  even though /etc/hosts points the hostname at a working IPv4 address.
//
//  Network.framework does expose that separation: NWConnection dials the
//  mapped IP while sec_protocol_options_set_tls_server_name keeps SNI and
//  certificate verification bound to the original hostname.
//


import Foundation
import Network
import Security

enum HostsMappedHTTPClient {
    struct Endpoint {
        let address: String
        let port: UInt16
        let originalHost: String
        let usesTLS: Bool
    }

    struct ResponseHead {
        let statusCode: Int
        let headers: [String: String]
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
                return "The hosts-mapped server address is invalid"
            case .invalidRequest(let reason):
                return "Could not build the hosts-mapped request: \(reason)"
            case .timedOut:
                return "The hosts-mapped connection timed out"
            case .connectionClosed:
                return "The hosts-mapped connection closed unexpectedly"
            case .invalidResponse(let reason):
                return "The server returned an invalid HTTP response: \(reason)"
            case .truncatedResponse:
                return "The hosts-mapped HTTP response ended unexpectedly"
            case .network(let error):
                return error.localizedDescription
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.ntfymac.hosts-http-client")
    private static let headerTerminator = Data([13, 10, 13, 10])

    /// Returns a direct endpoint only for HTTPS + Direct proxy mode + an
    /// explicit /etc/hosts entry. Other requests keep using URLSession.
    static func endpoint(for url: URL) -> Endpoint? {
        let portValue = url.port ?? 443
        guard ProxyConfig.current().mode == .direct,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !EndpointResolver.isIPAddress(host),
              let address = EndpointResolver.hostsAddress(for: host),
              (1...65535).contains(portValue)
        else {
            return nil
        }

        return Endpoint(
            address: address,
            port: UInt16(portValue),
            originalHost: host,
            usesTLS: true
        )
    }

    /// Runs a long-lived response and emits decoded HTTP body bytes. HTTP/1.1
    /// chunk framing is removed before body data reaches the caller.
    static func stream(
        request: URLRequest,
        endpoint: Endpoint,
        onResponse: (ResponseHead) throws -> Void,
        onBody: (Data) -> Void
    ) async throws {
        let connection = try makeConnection(to: endpoint)
        defer { connection.cancel() }

        try await start(connection)
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
        let connection = try makeConnection(to: endpoint)
        defer { connection.cancel() }

        try await start(connection)
        try Task.checkCancellation()
        try await send(serialize(request, endpoint: endpoint, keepAlive: false), over: connection)
        let (head, _) = try await receiveHead(from: connection)
        return head
    }

    private static func makeConnection(to endpoint: Endpoint) throws -> NWConnection {
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
            sec_protocol_options_set_tls_server_name(
                tls.securityProtocolOptions,
                endpoint.originalHost
            )
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
            host: NWEndpoint.Host(endpoint.address),
            port: port,
            using: parameters
        )
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

        let hostHeader: String
        if let explicitPort = url.port, explicitPort != 443 {
            hostHeader = "\(endpoint.originalHost):\(explicitPort)"
        } else {
            hostHeader = endpoint.originalHost
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
