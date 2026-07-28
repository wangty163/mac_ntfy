//
//  SidebarView.swift
//  NtfyMac
//

import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject var manager: SubscriptionManager
    @Binding var selection: SidebarSelection?
    @Binding var showingAdd: Bool
    @Binding var editing: Subscription?

    var body: some View {
        List(selection: $selection) {
            Section {
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
                .tag(SidebarSelection.all)
            }

            Section("Subscriptions") {
                ForEach(manager.subscriptions) { sub in
                    HStack(spacing: 4) {
                        SubscriptionRow(subscription: sub)
                        ConnectionStatusIndicator(subscription: sub)
                    }
                    // Keep the selectable value on the List row itself. A
                    // NavigationLink nested beside the diagnostics button is
                    // not treated as the row's selection on macOS, so the
                    // highlight can move while the bound content stays on the
                    // previous subscription.
                    .tag(SidebarSelection.subscription(sub.id))
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
        }
        .frame(maxWidth: .infinity)
    }
}

/// The normal UI remains a tiny status dot. Clicking it reveals diagnostics in
/// a transient popover, so connection details consume no permanent list space.
struct ConnectionStatusIndicator: View {
    @EnvironmentObject var manager: SubscriptionManager
    let subscription: Subscription
    @State private var showingDetails = false

    var body: some View {
        let state = manager.state(for: subscription.id)
        Button {
            showingDetails.toggle()
        } label: {
            StatusDot(color: state.tint, pulsing: state.isConnected)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
            .buttonStyle(.borderless)
            .help("Connection details")
            .accessibilityLabel("\(state.label). Show connection details")
            .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
                ConnectionDiagnosticsPopover(subscription: subscription)
                    .environmentObject(manager)
            }
    }
}

private struct ConnectionDiagnosticsPopover: View {
    @EnvironmentObject var manager: SubscriptionManager
    let subscription: Subscription
    @State private var copied = false

    private var details: ConnectionDiagnostics {
        manager.diagnostics(for: subscription.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: details.state.symbol)
                    .foregroundStyle(details.state.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subscription.name).font(.headline)
                    Text(details.state.label)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                diagnosticRow("Route", details.route)
                diagnosticRow("Remote", remoteDescription)
                diagnosticRow("Resolver", details.resolverSource)
                diagnosticRow("TLS SNI", details.tlsServerName ?? "—")
                diagnosticRow("Latency", details.connectionLatencyMilliseconds.map { "\($0) ms" } ?? "—")
                diagnosticRow("Last event", relative(details.lastEventAt))
                diagnosticRow("Keepalive", relative(details.lastKeepaliveAt))
                if details.retryCount > 0 {
                    diagnosticRow("Retries", "\(details.retryCount)")
                }
            }
            .font(.caption)

            if !details.resolvedAddresses.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Candidates")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(details.resolvedAddresses.joined(separator: "  ·  "))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = details.lastError, !details.state.isConnected {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Reconnect", systemImage: "arrow.clockwise") {
                    manager.reconnect(subscription.id)
                }
                .disabled(subscription.isMuted)
                Spacer()
                Button(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        details.report(subscription: subscription),
                        forType: .string
                    )
                    copied = true
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 330)
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var remoteDescription: String {
        guard let address = details.remoteAddress else { return "—" }
        if let family = details.addressFamily { return "\(address) · \(family)" }
        return address
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.relative(presentation: .named))
    }
}

enum SidebarSelection: Hashable {
    case all
    case subscription(UUID)
}
