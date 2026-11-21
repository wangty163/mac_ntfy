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

            setHeader(attachment.filename, name: "X-Filename", on: &request)
            // The request body contains the file, so the message
            // must be supplied through the X-Message header.
            setHeader(req.message, name: "X-Message", on: &request)
        } else {
            // Regular message or URL attachment: POST message body.
            request.httpMethod = "POST"
            request.httpBody = Data(req.message.utf8)
            request.setValue(
                req.markdown ? "text/markdown" : "text/plain", forHTTPHeaderField: "Content-Type")

            if !req.attachURL.isEmpty { setHeader(req.attachURL, name: "X-Attach", on: &request) }
        }

        // Common notification metadata.
        setHeader(req.title, name: "X-Title", on: &request)
        setHeader(String(req.priority), name: "X-Priority", on: &request)

        if !req.tags.isEmpty {
            setHeader(req.tags.joined(separator: ","), name: "X-Tags", on: &request)
        }

        setHeader(req.click, name: "X-Click", on: &request)
        setHeader(req.email, name: "X-Email", on: &request)

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

        let statusCode = try await sendRequest(request)

        guard (200...299).contains(statusCode) else {
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

    // MARK: - Shared HTTP transport

    private static func sendRequest(_ request: URLRequest) async throws -> Int {
        guard let url = request.url else { throw URLError(.badURL) }

        if let endpoint = await HostsMappedHTTPClient.endpoint(for: url) {
            let response = try await HostsMappedHTTPClient.request(request, endpoint: endpoint)
            return response.statusCode
        }

        let session = ProxyConfig.makeEphemeralSession()
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw NtfyError.http("No response") }

        return http.statusCode
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

            let statusCode = try await sendRequest(request)

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
