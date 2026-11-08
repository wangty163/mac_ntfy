//
//  MultiSelectionSummaryView.swift
//  NtfyMac
//

import SwiftUI

struct MultiSelectionSummaryView: View {
    let messages: [StoredMessage]
    let onClearSelection: () -> Void

    @EnvironmentObject var manager: SubscriptionManager

    private var readCount: Int {
        messages.filter(\.isRead).count
    }

    private var unreadCount: Int {
        messages.count - readCount
    }

    private var attachmentCount: Int {
        messages.filter { $0.message.attachment != nil }.count
    }

    private var actionCount: Int {
        messages.reduce(0) { $0 + ($1.message.actions?.count ?? 0) }
    }

    private var subscriptionCount: Int {
        Set(messages.map(\.subscriptionID)).count
    }

    private var priorityCounts: [(priority: NtfyPriority, count: Int)] {
        let grouped = Dictionary(grouping: messages) {
            $0.message.resolvedPriority
        }

        return grouped.map { priority, messages in
            (priority: priority, count: messages.count)
        }
        .sorted {
            if $0.count != $1.count {
                return $0.count > $1.count
            }

            return $0.priority.rawValue > $1.priority.rawValue
        }
    }

    private var subscriptionBreakdown: [(id: UUID, name: String, count: Int)] {
        let grouped = Dictionary(grouping: messages, by: \.subscriptionID)

        return grouped.map { id, messages in
            let name = manager.subscription(id: id)?.name ?? "Unknown subscription"
            return (id: id, name: name, count: messages.count)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.brandGradient)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(messages.count) messages selected")
                            .appFont(.title2, weight: .semibold)

                        Text("\(subscriptionCount) subscriptions")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    if unreadCount > 0 {
                        Button {
                            for stored in messages where !stored.isRead {
                                manager.markRead(
                                    subscriptionID: stored.subscriptionID,
                                    messageID: stored.message.id
                                )
                            }
                        } label: {
                            Label("Mark read", systemImage: "envelope.open")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button {
                        onClearSelection()
                    } label: {
                        Label("Clear selection", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Read status")
                        .appFont(.headline)

                    metricRow("Read", value: readCount, icon: "envelope.open")
                    metricRow("Unread", value: unreadCount, icon: "envelope")
                }
                .padding(16)
                .cardBackground()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Priority")
                        .appFont(.headline)

                    ForEach(priorityCounts, id: \.priority) { item in
                        HStack(spacing: 10) {
                            Label(item.priority.label, systemImage: "flag")
                                .foregroundStyle(item.priority.tint)

                            Spacer()

                            Text("\(item.count)")
                                .appFont(.body, weight: .semibold)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(16)
                .cardBackground()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Content")
                        .appFont(.headline)

                    metricRow("Attachments", value: attachmentCount, icon: "paperclip")
                    metricRow("Actions", value: actionCount, icon: "bolt")
                }
                .padding(16)
                .cardBackground()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Subscriptions")
                        .appFont(.headline)

                    ForEach(subscriptionBreakdown, id: \.id) { item in
                        HStack(spacing: 10) {
                            Text(item.name)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("\(item.count)")
                                .appFont(.body, weight: .semibold)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(16)
                .cardBackground()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func metricRow(_ title: String, value: Int, icon: String) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon)
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(value)")
                .appFont(.body, weight: .semibold)
                .monospacedDigit()
        }
    }
}
