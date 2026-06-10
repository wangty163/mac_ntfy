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

    private var recentUnread: [StoredMessage] {
        Array(manager.recentMessages.filter { !$0.isRead }.prefix(3))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if recentUnread.isEmpty {
                emptyState
            } else {
                unreadSection
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(MenuPanelWindowResizer(sizeKey: recentUnread.count))
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

    private var unreadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Unread")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Latest 3")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            LazyVStack(spacing: 6) {
                ForEach(recentUnread) { item in
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(manager.messages.isEmpty ? "No notifications yet" : "No unread notifications")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

/// Keeps the menu-bar extra window fitted to the SwiftUI content as unread
/// rows are removed. `MenuBarExtra` windows can keep their previous taller
/// frame after content shrinks, which leaves a blank area above the footer.
private struct MenuPanelWindowResizer: NSViewRepresentable {
    let sizeKey: Int

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, let contentView = window.contentView else { return }
            let fittingSize = contentView.fittingSize
            guard fittingSize.width > 0, fittingSize.height > 0 else { return }

            let currentFrame = window.frame
            let targetHeight = fittingSize.height
            guard abs(currentFrame.height - targetHeight) > 0.5 else { return }

            let targetFrame = NSRect(
                x: currentFrame.minX,
                y: currentFrame.maxY - targetHeight,
                width: currentFrame.width,
                height: targetHeight
            )
            window.setFrame(targetFrame, display: true, animate: false)
        }
    }
}

/// Settings button for macOS 14+, using the official `SettingsLink`, which
/// opens the `Settings` scene reliably. Focus is handled by `SettingsView`'s
/// `onAppear` (which promotes the app to a regular, front window).
@available(macOS 14.0, *)
private struct ModernSettingsButton: View {
    var body: some View {
        SettingsLink {
            Image(systemName: "gearshape")
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
