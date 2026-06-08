//
//  MenuPanelView.swift
//  NtfyMac
//
//  The compact panel shown when clicking the menu-bar icon: connection status,
//  the most recent messages, and quick access to the main window / settings.
//

import SwiftUI

struct MenuPanelView: View {
    @EnvironmentObject var manager: SubscriptionManager
    @Environment(\.openWindow) private var openWindow

    private var recent: [StoredMessage] {
        Array(manager.recentMessages.prefix(12))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if recent.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(recent) { item in
                            MenuMessageRow(stored: item,
                                           subscription: manager.subscription(id: item.subscriptionID))
                                .onTapGesture {
                                    manager.markRead(subscriptionID: item.subscriptionID, messageID: item.message.id)
                                    manager.pendingReveal = (item.subscriptionID, item.message.id)
                                    openMain()
                                }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 360)
            }
            Divider()
            footer
        }
        .frame(width: 360)
        // Update instantly when content changes — no sliding/fly-in animations.
        .transaction { $0.animation = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 30, height: 30)
                Image(systemName: "bell.fill").foregroundStyle(.white).font(.caption)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Ntfy").font(.headline)
                HStack(spacing: 5) {
                    StatusDot(color: manager.anyConnected ? .green : .orange,
                              pulsing: manager.anyConnected)
                    Text(connectionSummary)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if manager.totalUnread > 0 {
                Chip(text: "\(manager.totalUnread) new", tint: .accentColor)
            }
        }
        .padding(12)
    }

    private var connectionSummary: String {
        let connected = manager.states.values.filter { $0.isConnected }.count
        let total = manager.subscriptions.count
        if total == 0 { return "No subscriptions" }
        return "\(connected)/\(total) topics connected"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("No notifications yet").font(.subheadline).foregroundStyle(.secondary)
            Button("Add a subscription") { openMain() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                openMain()
            } label: {
                Label("Open Ntfy", systemImage: "macwindow")
            }
            .buttonStyle(.borderedProminent)

            Button {
                manager.markAllRead()
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .help("Mark all as read")

            settingsButton
                .help("Settings")

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Ntfy")
        }
        .buttonStyle(.bordered)
        .padding(12)
    }

    /// Opens Settings reliably: the official `openSettings` action on macOS 14+,
    /// falling back to the responder-chain selector on macOS 13.
    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            ModernSettingsButton()
        } else {
            Button {
                AppActivation.enterWindowMode()
                if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            } label: {
                Image(systemName: "gearshape")
            }
        }
    }

    private func openMain() {
        // Become a regular app so the window is a normal, standalone window
        // (its own Stage Manager stage, Mission Control entry, etc.).
        AppActivation.enterWindowMode()
        openWindow(id: "main")
    }
}

/// Settings button for macOS 14+, using the official `openSettings` action.
@available(macOS 14.0, *)
private struct ModernSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            AppActivation.enterWindowMode()
            openSettings()
        } label: {
            Image(systemName: "gearshape")
        }
    }
}

struct MenuMessageRow: View {
    let stored: StoredMessage
    let subscription: Subscription?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(stored.isRead ? Color.clear : (subscription?.accentColor ?? .accentColor))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(stored.message.date, format: .relative(presentation: .numeric))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize()
                }
                if let body = stored.message.message, !body.isEmpty {
                    Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .contentShape(Rectangle())
    }

    private var title: String {
        let name = subscription?.name ?? stored.message.topic
        let prefix = stored.message.emojiTags.joined()
        let base = stored.message.displayTitle(fallbackTopic: name)
        return prefix.isEmpty ? base : "\(prefix) \(base)"
    }
}
