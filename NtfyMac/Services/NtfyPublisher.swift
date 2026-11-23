//
//  NtfyPublisher.swift
//  NtfyMac
//
//  Publishes messages using ntfy's HTTP headers API and provides a
//  lightweight reachability check used when adding a subscription.
//

import Foundation

struct PublishRequest {
    var title: String = ""
    var message: String = ""
    var priority: Int = 3
    var tags: [String] = []
    var click: String = ""
    var delay: String = ""
    var attachURL: String = ""
    var email: String = ""
    var markdown: Bool = false
}

struct LocalAttachment {
    let data: Data
    let filename: String
    let contentType: String
}

@MainActor enum NtfyPublisher {
    private struct ServerError: Decodable {
        let code: Int
    }

    // MARK: - Publishing

    static func publish(
        _ req: PublishRequest, to subscription: Subscription, attachment: LocalAttachment? = nil
    ) async throws {
        guard let baseURL = URL(string: subscription.normalizedBaseURL) else {
            throw URLError(.badURL)
        }

        let url = baseURL.appendingPathComponent(subscription.topic)
        var request = URLRequest(url: url)

        if let attachment {
            // Local file: PUT raw file bytes.
            request.httpMethod = "PUT"
            request.httpBody = attachment.data
            request.setValue(attachment.contentType, forHTTPHeaderField: "Content-Type")

            setHeader(encodedHeaderValue(attachment.filename), name: "X-Filename", on: &request)
            // The request body contains the file, so the message
            // must be supplied through the X-Message header.
            setHeader(encodedHeaderValue(req.message), name: "X-Message", on: &request)
        } else {
            // Regular message or URL attachment: POST message body.
            request.httpMethod = "POST"
            request.httpBody = Data(req.message.utf8)
            request.setValue(
                req.markdown ? "text/markdown" : "text/plain", forHTTPHeaderField: "Content-Type")

            if !req.attachURL.isEmpty { setHeader(encodedHeaderValue(req.attachURL), name: "X-Attach", on: &request) }
        }

        // Common notification metadata.
        setHeader(encodedHeaderValue(req.title), name: "X-Title", on: &request)
        setHeader(String(req.priority), name: "X-Priority", on: &request)

        if !req.tags.isEmpty {
            setHeader(encodedHeaderValue(req.tags.joined(separator: ",")), name: "X-Tags", on: &request)
        }

        setHeader(encodedHeaderValue(req.click), name: "X-Click", on: &request)
        setHeader(encodedHeaderValue(req.email), name: "X-Email", on: &request)

        if !req.delay.isEmpty {
            setHeader(req.delay, name: "X-Delay", on: &request)
            // To interpret a natural language time or even a simple time (e.g. 22:30),
            // we need a timezone header.
            setHeader(TimeZone.current.identifier, name: "X-Timezone", on: &request)
        }

        if req.markdown && attachment != nil { setHeader("true", name: "X-Markdown", on: &request) }

        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (statusCode, data) = try await sendRequest(request)

        guard (200...299).contains(statusCode) else {
            // Attachment expiry before delayed delivery date
            if isResponseCode(data, code: 40015) {
                throw NtfyError.http("Attachment expires before send. Send sooner.")
            }

            // Standard error, if not handled explicitly
            throw NtfyError.http("Publish failed (HTTP \(statusCode))")
        }
    }

    // MARK: - Header helpers

    private static func setHeader(_ value: String, name: String, on request: inout URLRequest) {
        guard !value.isEmpty else { return }

        // Pass Unicode strings directly. URLSession handles HTTP
        // header serialization; ntfy supports UTF-8 headers.
        request.setValue(value, forHTTPHeaderField: name)
    }

    private static func encodedHeaderValue(_ value: String) -> String {
        let isASCII = value.unicodeScalars.allSatisfy { $0.isASCII }
        let shouldEncode = value.contains(where: \.isNewline)
            || (ProxyConfig.current().mode != .direct && !isASCII)
        guard shouldEncode else { return value }

        let encoded = Data(value.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    // MARK: - Shared HTTP transport

    private static func sendRequest(_ request: URLRequest) async throws -> (statusCode: Int, data: Data) {
        guard let url = request.url else { throw URLError(.badURL) }

        if let endpoint = await HostsMappedHTTPClient.endpoint(for: url) {
            let response = try await HostsMappedHTTPClient.requestWithBody(request, endpoint: endpoint)
            let body = (200...299).contains(response.head.statusCode) ? Data() : response.body
            return (response.head.statusCode, body)
        }

        let session = ProxyConfig.makeEphemeralSession()
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw NtfyError.http("No response") }

        let body = (200...299).contains(http.statusCode) ? Data() : data
        return (http.statusCode, body)
    }

    private static func isResponseCode(_ data: Data, code: Int) -> Bool {
        guard let error = try? JSONDecoder().decode(
            ServerError.self,
            from: data
        ) else {
            return false
        }
        return error.code == code
    }

    // MARK: - Reachability

    /// Quick poll=1 request that verifies the server + topic + auth work.
    static func test(subscription: Subscription) async -> Result<Void, Error> {
        guard let url = subscription.streamURL(forcePoll: true, includeCursor: false) else {
            return .failure(URLError(.badURL))
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15

            if let auth = subscription.auth.authorizationHeader {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }

            let (statusCode, _) = try await sendRequest(request)

            switch statusCode {
                case 200...299:
                    return .success(())
                case 401, 403:
                    return .failure(NtfyError.http("Authentication failed"))
                case 404:
                    return .failure(NtfyError.http("Topic or server not found"))
                default:
                    return .failure(NtfyError.http("HTTP \(statusCode)"))
            }
        } catch { return .failure(error) }
    }
}
