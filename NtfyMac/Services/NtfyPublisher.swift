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
        guard let url = URL(string: subscription.topicURLString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let auth = subscription.auth.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if !req.title.isEmpty { request.setValue(req.title, forHTTPHeaderField: "Title") }
        request.setValue(String(req.priority), forHTTPHeaderField: "Priority")
        if !req.tags.isEmpty {
            request.setValue(req.tags.joined(separator: ","), forHTTPHeaderField: "Tags")
        }
        if !req.click.isEmpty { request.setValue(req.click, forHTTPHeaderField: "Click") }
        if !req.delay.isEmpty { request.setValue(req.delay, forHTTPHeaderField: "Delay") }
        if !req.attachURL.isEmpty { request.setValue(req.attachURL, forHTTPHeaderField: "Attach") }
        if !req.email.isEmpty { request.setValue(req.email, forHTTPHeaderField: "Email") }
        if req.markdown { request.setValue("text/markdown", forHTTPHeaderField: "Content-Type") }

        request.httpBody = Data(req.message.utf8)

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
