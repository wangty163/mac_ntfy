//
//  Subscription.swift
//  NtfyMac
//
//  A user-defined subscription to one ntfy topic on one server, plus the
//  stored-message wrapper used for history.
//

import Foundation
import SwiftUI

/// Credentials used to authenticate against a protected topic.
enum NtfyAuth: Codable, Equatable, Hashable {
    case none
    case basic(username: String, password: String)
    case token(String)

    /// Value for the `Authorization` HTTP header, if any.
    var authorizationHeader: String? {
        switch self {
        case .none:
            return nil
        case let .basic(username, password):
            let raw = "\(username):\(password)"
            let encoded = Data(raw.utf8).base64EncodedString()
            return "Basic \(encoded)"
        case let .token(token):
            return "Bearer \(token)"
        }
    }

    var summary: String {
        switch self {
        case .none: return "No authentication"
        case let .basic(username, _): return "Basic · \(username)"
        case .token: return "Access token"
        }
    }
}

/// Optional server-side filters applied to the subscription stream.
struct SubscriptionFilters: Codable, Equatable, Hashable {
    /// Only deliver messages with one of these priorities (empty = all).
    var priorities: Set<Int> = []
    /// Only deliver messages carrying *all* of these tags.
    var tags: [String] = []

    var isEmpty: Bool { priorities.isEmpty && tags.isEmpty }
}

/// A single topic subscription. `baseURL` is the server root (e.g. `https://ntfy.sh`).
struct Subscription: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var baseURL: String = "https://ntfy.sh"
    var topic: String = ""
    var displayName: String = ""
    var auth: NtfyAuth = .none
    var filters: SubscriptionFilters = SubscriptionFilters()
    var notificationsEnabled: Bool = true
    var isMuted: Bool = false
    var accentHex: String = "#3B82F6"

    /// Last seen message id — used as the `since` cursor so messages that
    /// arrive while the app is closed are recovered on reconnect.
    var lastMessageID: String?

    var name: String {
        displayName.isEmpty ? topic : displayName
    }

    var normalizedBaseURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "https://" + s }
        return s
    }

    /// Human friendly server label, e.g. `ntfy.sh`.
    var serverHost: String {
        URL(string: normalizedBaseURL)?.host ?? normalizedBaseURL
    }

    var topicURLString: String {
        "\(normalizedBaseURL)/\(topic)"
    }

    var accentColor: Color {
        Color(hex: accentHex) ?? .accentColor
    }

    /// Builds the JSON HTTP subscription URL with cursor + filters applied.
    func streamURL(forcePoll: Bool = false, includeCursor: Bool = true) -> URL? {
        subscriptionURL(endpoint: "json", forcePoll: forcePoll, includeCursor: includeCursor)
    }

    private func subscriptionURL(
        endpoint: String,
        forcePoll: Bool = false,
        includeCursor: Bool = true
    ) -> URL? {
        guard var components = URLComponents(string: "\(normalizedBaseURL)/\(topic)/\(endpoint)") else {
            return nil
        }
        var items: [URLQueryItem] = []
        if includeCursor, let lastMessageID {
            items.append(URLQueryItem(name: "since", value: lastMessageID))
        }
        if forcePoll {
            items.append(URLQueryItem(name: "poll", value: "1"))
        }
        if !filters.priorities.isEmpty {
            let value = filters.priorities.sorted().map(String.init).joined(separator: ",")
            items.append(URLQueryItem(name: "priority", value: value))
        }
        if !filters.tags.isEmpty {
            items.append(URLQueryItem(name: "tags", value: filters.tags.joined(separator: ",")))
        }
        // Scheduled/delayed messages are a finite catch-up query. Including
        // them on the live stream is unnecessary once they are delivered, and
        // some self-hosted/proxied setups handle that combination poorly.
        if forcePoll {
            items.append(URLQueryItem(name: "sched", value: "1"))
        }
        if !items.isEmpty { components.queryItems = items }
        return components.url
    }
}

/// A message persisted to history, tied to the subscription that received it.
struct StoredMessage: Identifiable, Codable, Equatable {
    let subscriptionID: UUID
    var message: NtfyMessage
    var isRead: Bool
    var receivedAt: Date

    var id: String { "\(subscriptionID.uuidString)::\(message.id)" }

    init(subscriptionID: UUID, message: NtfyMessage, isRead: Bool = false, receivedAt: Date = Date()) {
        self.subscriptionID = subscriptionID
        self.message = message
        self.isRead = isRead
        self.receivedAt = receivedAt
    }
}
