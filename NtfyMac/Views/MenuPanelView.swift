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
    @State private var panelContentHeight: CGFloat = 0

    private var unreadMessages: [StoredMessage] {
        manager.recentMessages.filter { !$0.isRead }
    }

    /// Fixed message area height so the menu-bar panel keeps the original
    /// compact size. Extra unread messages are shown by scrolling instead of
    /// growing the popover.
    private static let messageAreaHeight: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageArea
            Divider()
            footer
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: MenuPanelHeightKey.self,
                        value: proxy.size.height
                    )
            }
        }
        .onPreferenceChange(MenuPanelHeightKey.self) { panelContentHeight = $0 }
        .background(MenuPanelWindowResizer(targetHeight: panelContentHeight))
        // Update instantly when content changes — no sliding/fly-in animations.
        .transaction { $0.animation = nil }
    }

    /// Fixed-height content area. Unread rows scroll inside this space so the
    /// menu-bar popover height never changes as messages arrive or are read.
    @ViewBuilder
    private var messageArea: some View {
        Group {
            if unreadMessages.isEmpty {
                emptyState
            } else {
                unreadSection
            }
        }
        .frame(height: Self.messageAreaHeight, alignment: .top)
        .clipped()
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

    private var unreadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Unread")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(unreadMessages.count) total")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(unreadMessages) { item in
                        MenuMessageRow(
                            stored: item,
                            subscription: manager.subscription(id: item.subscriptionID),
                            markRead: {
                                manager.markRead(subscriptionID: item.subscriptionID, messageID: item.message.id)
                            }
                        )
                        .onTapGesture {
                            manager.markRead(subscriptionID: item.subscriptionID, messageID: item.message.id)
                            manager.pendingReveal = (item.subscriptionID, item.message.id)
                            openMain()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(manager.messages.isEmpty ? "No notifications yet" : "No unread notifications")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Opens the dedicated settings window and immediately promotes it above
    /// the menu-bar panel. Using an addressable `Window` avoids the `Settings`
    /// scene being created but left inactive behind the panel.
    private var settingsButton: some View {
        Button {
            SettingsWindow.prepareToOpen()
            openWindow(id: "settings")
            SettingsWindow.focusSoon()
        } label: {
            Image(systemName: "gearshape")
        }
    }

    private func openMain() {
        // Become a regular app so the window is a normal, standalone window
        // (its own Stage Manager stage, Mission Control entry, etc.).
        AppActivation.enterWindowMode()
        openWindow(id: "main")
    }
}

private struct MenuPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Keeps the menu-bar extra window fitted to the measured SwiftUI content as
/// unread rows are removed. `MenuBarExtra` windows can keep their previous
/// taller frame after content shrinks, which leaves translucent blank areas
/// around the now-smaller content.
private struct MenuPanelWindowResizer: NSViewRepresentable {
    let targetHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard targetHeight > 0, let window = view.window else { return }

            let currentFrame = window.frame
            let roundedHeight = ceil(targetHeight)
            guard abs(currentFrame.height - roundedHeight) > 0.5 else { return }

            let targetFrame = NSRect(
                x: currentFrame.minX,
                y: currentFrame.maxY - roundedHeight,
                width: currentFrame.width,
                height: roundedHeight
            )
            window.setFrame(targetFrame, display: true, animate: false)
        }
    }
}

struct MenuMessageRow: View {
    let stored: StoredMessage
    let subscription: Subscription?
    var markRead: () -> Void

    private var accent: Color { subscription?.accentColor ?? .accentColor }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    RelativeTimeText(date: stored.message.date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                if let body = stored.message.message, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Label(channelName, systemImage: "number")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        markRead()
                    } label: {
                        Label("Mark Read", systemImage: "checkmark.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .font(.caption2.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .help("Mark this notification as read")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .contentShape(Rectangle())
    }

    private var title: String {
        let prefix = stored.message.emojiTags.joined()
        let base = stored.message.displayTitle(fallbackTopic: channelName)
        return prefix.isEmpty ? base : "\(prefix) \(base)"
    }

    private var channelName: String {
        subscription?.name ?? stored.message.topic
    }
}
