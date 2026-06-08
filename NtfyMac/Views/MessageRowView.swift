//
//  MessageRowView.swift
//  NtfyMac
//

import SwiftUI

struct MessageRowView: View {
    let stored: StoredMessage
    var subscriptionName: String
    var accent: Color
    var showSource: Bool = false

    private var message: NtfyMessage { stored.message }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Priority rail / unread dot
            VStack {
                Circle()
                    .fill(stored.isRead ? Color.clear : accent)
                    .frame(width: 8, height: 8)
                Spacer(minLength: 0)
            }
            .frame(width: 8)
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(stored.isRead ? .semibold : .bold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(message.date, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                if let body = message.message, !body.isEmpty {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(3)
                }

                HStack(spacing: 6) {
                    if message.resolvedPriority != .default {
                        Chip(text: message.resolvedPriority.label,
                             systemImage: message.resolvedPriority.symbol,
                             tint: message.resolvedPriority.tint)
                    }
                    ForEach(message.labelTags.prefix(3), id: \.self) { tag in
                        Chip(text: tag, tint: .secondary)
                    }
                    if message.attachment != nil {
                        Chip(text: "Attachment", systemImage: "paperclip", tint: .teal)
                    }
                    if let actions = message.actions, !actions.isEmpty {
                        Chip(text: "\(actions.count) action\(actions.count == 1 ? "" : "s")",
                             systemImage: "bolt", tint: .purple)
                    }
                    if showSource {
                        Spacer(minLength: 0)
                        Chip(text: subscriptionName, systemImage: "number", tint: accent)
                    }
                }
            }
        }
        .padding(12)
        .cardBackground(highlighted: !stored.isRead)
    }

    private var title: String {
        let prefix = message.emojiTags.joined()
        let base = message.displayTitle(fallbackTopic: subscriptionName)
        return prefix.isEmpty ? base : "\(prefix) \(base)"
    }
}
