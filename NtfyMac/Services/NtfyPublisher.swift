//
//  NtfyPublisher.swift
//  NtfyMac
//
//  Publishes messages to a topic using ntfy's HTTP headers API, and provides a
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

@MainActor
enum NtfyPublisher {
    static func publish(_ req: PublishRequest, to subscription: Subscription) async throws {
        // Publish using ntfy's JSON body API (POST to the server root with the
        // topic in the payload) rather than the header API. HTTP header values
        // can't reliably carry non-ASCII text, so a header-based title/tags
        // would mangle or drop Unicode (e.g. Chinese, emoji); a JSON body is
        // UTF-8 throughout.
        guard let url = URL(string: subscription.normalizedBaseURL) else {
            throw URLError(.badURL)
        }

        var payload: [String: Any] = [
            "topic": subscription.topic,
            "message": req.message,
            "priority": req.priority,
        ]
        if !req.title.isEmpty { payload["title"] = req.title }
        if !req.tags.isEmpty { payload["tags"] = req.tags }
        if !req.click.isEmpty { payload["click"] = req.click }
        if !req.delay.isEmpty { payload["delay"] = req.delay }
        if !req.attachURL.isEmpty { payload["attach"] = req.attachURL }
        if !req.email.isEmpty { payload["email"] = req.email }
        if req.markdown { payload["markdown"] = true }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NtfyError.http("Publish failed (HTTP \(code))")
        }
    }

    /// Quick `poll=1` request that verifies the server + topic + auth work.
    static func test(subscription: Subscription) async -> Result<Void, Error> {
        guard var components = URLComponents(string: "\(subscription.normalizedBaseURL)/\(subscription.topic)/json") else {
            return .failure(URLError(.badURL))
        }
        components.queryItems = [URLQueryItem(name: "poll", value: "1")]
        guard let url = components.url else { return .failure(URLError(.badURL)) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(NtfyError.http("No response"))
            }
            switch http.statusCode {
            case 200...299: return .success(())
            case 401, 403: return .failure(NtfyError.http("Authentication failed"))
            case 404: return .failure(NtfyError.http("Topic or server not found"))
            default: return .failure(NtfyError.http("HTTP \(http.statusCode)"))
            }
        } catch {
            return .failure(error)
        }
    }
}
