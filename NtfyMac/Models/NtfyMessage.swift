//
//  NtfyMessage.swift
//  NtfyMac
//
//  The wire model for messages delivered by an ntfy server over the
//  newline-delimited JSON (`/<topic>/json`) streaming endpoint.
//  See: https://docs.ntfy.sh/subscribe/api/
//

import Foundation
import SwiftUI

/// A single event delivered by the ntfy server. The same envelope is used for
/// real messages and for connection control events (`open`, `keepalive`, …).
struct NtfyMessage: Codable, Equatable, Hashable {
    enum Event: String, Codable {
        case open
        case keepalive
        case message
        case pollRequest = "poll_request"
        case messageDelete = "message_delete"
        case messageClear = "message_clear"

        /// Unknown / future event types decode to `.unknown` instead of failing.
        case unknown
    }

    let id: String
    let time: Int
    let expires: Int?
    let event: Event
    let topic: String
    let sequenceID: String?
    let message: String?
    let title: String?
    let tags: [String]?
    let priority: Int?
    let click: String?
    let actions: [NtfyAction]?
    let attachment: NtfyAttachment?
    let icon: String?
    let contentType: String?

    enum CodingKeys: String, CodingKey {
        case id, time, expires, event, topic, message, title, tags, priority
        case click, actions, attachment, icon
        case sequenceID = "sequence_id"
        case contentType = "content_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        time = (try? c.decode(Int.self, forKey: .time)) ?? Int(Date().timeIntervalSince1970)
        expires = try? c.decode(Int.self, forKey: .expires)
        let raw = (try? c.decode(String.self, forKey: .event)) ?? "message"
        event = Event(rawValue: raw) ?? .unknown
        topic = (try? c.decode(String.self, forKey: .topic)) ?? ""
        sequenceID = try? c.decode(String.self, forKey: .sequenceID)
        message = try? c.decode(String.self, forKey: .message)
        title = try? c.decode(String.self, forKey: .title)
        tags = try? c.decode([String].self, forKey: .tags)
        priority = try? c.decode(Int.self, forKey: .priority)
        click = try? c.decode(String.self, forKey: .click)
        actions = try? c.decode([NtfyAction].self, forKey: .actions)
        attachment = try? c.decode(NtfyAttachment.self, forKey: .attachment)
        icon = try? c.decode(String.self, forKey: .icon)
        contentType = try? c.decode(String.self, forKey: .contentType)
    }
}

// MARK: - Convenience accessors

extension NtfyMessage {
    var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }

    var resolvedPriority: NtfyPriority {
        NtfyPriority(rawValue: priority ?? 3) ?? .default
    }

    /// `true` when the body should be rendered as Markdown.
    var isMarkdown: Bool {
        contentType?.localizedCaseInsensitiveContains("markdown") == true
    }

    /// Emoji shortcodes that map to an emoji glyph (rendered as a prefix).
    var emojiTags: [String] {
        (tags ?? []).compactMap { EmojiMap.emoji(for: $0) }
    }

    /// Tags that are *not* known emoji shortcodes — shown as text chips.
    var labelTags: [String] {
        (tags ?? []).filter { EmojiMap.emoji(for: $0) == nil }
    }

    /// The title to show, falling back to the topic name like the ntfy clients do.
    func displayTitle(fallbackTopic: String) -> String {
        if let t = title, !t.isEmpty { return t }
        return fallbackTopic
    }

    var clickURL: URL? {
        guard let click, let url = URL(string: click) else { return nil }
        return url
    }
}

/// Priority levels 1–5 as defined by ntfy (3 is the default).
enum NtfyPriority: Int, CaseIterable, Codable {
    case min = 1
    case low = 2
    case `default` = 3
    case high = 4
    case max = 5

    var label: String {
        switch self {
        case .min: return "Min"
        case .low: return "Low"
        case .default: return "Default"
        case .high: return "High"
        case .max: return "Max"
        }
    }

    var symbol: String {
        switch self {
        case .min: return "arrow.down.circle"
        case .low: return "arrow.down"
        case .default: return "equal.circle"
        case .high: return "exclamationmark"
        case .max: return "exclamationmark.2"
        }
    }

    var tint: Color {
        switch self {
        case .min: return .secondary
        case .low: return .teal
        case .default: return .accentColor
        case .high: return .orange
        case .max: return .red
        }
    }
}

/// An action button attached to a message (`view`, `broadcast`, or `http`).
struct NtfyAction: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case view, broadcast, http, unknown
    }

    let id: String
    let action: Kind
    let label: String
    let clear: Bool?

    // view + http
    let url: String?
    // http
    let method: String?
    let headers: [String: String]?
    let body: String?
    // broadcast
    let intent: String?
    let extras: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, action, label, clear, url, method, headers, body, intent, extras
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        let raw = (try? c.decode(String.self, forKey: .action)) ?? "unknown"
        action = Kind(rawValue: raw) ?? .unknown
        label = (try? c.decode(String.self, forKey: .label)) ?? raw.capitalized
        clear = try? c.decode(Bool.self, forKey: .clear)
        url = try? c.decode(String.self, forKey: .url)
        method = try? c.decode(String.self, forKey: .method)
        headers = try? c.decode([String: String].self, forKey: .headers)
        body = try? c.decode(String.self, forKey: .body)
        intent = try? c.decode(String.self, forKey: .intent)
        extras = try? c.decode([String: String].self, forKey: .extras)
    }

    var symbol: String {
        switch action {
        case .view: return "safari"
        case .http: return "arrow.up.right.square"
        case .broadcast: return "antenna.radiowaves.left.and.right"
        case .unknown: return "questionmark"
        }
    }
}

/// File attached to a message. May live on the ntfy server or an external URL.
struct NtfyAttachment: Codable, Equatable, Hashable {
    let name: String
    let url: String
    let type: String?
    let size: Int?
    let expires: Int?

    var fileURL: URL? { URL(string: url) }

    var humanSize: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var isImage: Bool {
        if let type { return type.hasPrefix("image/") }
        let lower = name.lowercased()
        return [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"].contains { lower.hasSuffix($0) }
    }
}
