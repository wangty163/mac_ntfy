//
//  SidebarView.swift
//  NtfyMac
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var manager: SubscriptionManager
    @Binding var selection: SidebarSelection?
    @Binding var showingAdd: Bool
    @Binding var editing: Subscription?

    var body: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: SidebarSelection.all) {
                    Label {
                        HStack {
                            Text("All Messages")
                            Spacer()
                            if manager.totalUnread > 0 {
                                Chip(text: "\(manager.totalUnread)", tint: .accentColor)
                            }
                        }
                    } icon: {
                        Image(systemName: "tray.full")
                    }
                }
            }

            Section("Subscriptions") {
                ForEach(manager.subscriptions) { sub in
                    NavigationLink(value: SidebarSelection.subscription(sub.id)) {
                        SubscriptionRow(subscription: sub)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") {
                            editing = sub
                        }
                        Button(sub.isMuted ? "Unmute" : "Mute", systemImage: sub.isMuted ? "bell" : "bell.slash") {
                            var copy = sub; copy.isMuted.toggle()
                            manager.updateSubscription(copy)
                        }
                        Button("Mark All Read", systemImage: "checkmark.circle") {
                            manager.markAllRead(subscriptionID: sub.id)
                        }
                        Divider()
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            manager.removeSubscription(sub.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                showingAdd = true
            } label: {
                Label("Add Subscription", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(12)
        }
    }
}

struct SubscriptionRow: View {
    @EnvironmentObject var manager: SubscriptionManager
    let subscription: Subscription

    var body: some View {
        let state = manager.state(for: subscription.id)
        let unread = manager.unreadCount(for: subscription.id)
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(subscription.accentColor.opacity(0.18))
                    .frame(width: 26, height: 26)
                Image(systemName: subscription.isMuted ? "bell.slash.fill" : "number")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(subscription.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(subscription.name).lineLimit(1)
                Text(subscription.serverHost)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if unread > 0 {
                Chip(text: "\(unread)", tint: subscription.accentColor)
            }
            StatusDot(color: state.tint, pulsing: state.isConnected)
        }
    }
}

enum SidebarSelection: Hashable {
    case all
    case subscription(UUID)
}
