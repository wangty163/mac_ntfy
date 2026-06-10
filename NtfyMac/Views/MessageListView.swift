//
//  MessageListView.swift
//  NtfyMac
//

import SwiftUI

struct MessageListView: View {
    @EnvironmentObject var manager: SubscriptionManager
    let selection: SidebarSelection
    @Binding var selectedMessageID: String?
    @State private var searchText = ""
    @State private var showingCompose = false
    @FocusState private var searchFocused: Bool

    private var subscription: Subscription? {
        if case let .subscription(id) = selection { return manager.subscription(id: id) }
        return nil
    }

    private var items: [StoredMessage] {
        let base: [StoredMessage]
        switch selection {
        case .all:
            base = manager.recentMessages
        case let .subscription(id):
            base = manager.messages(for: id)
        }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter {
            ($0.message.message?.lowercased().contains(q) ?? false)
                || ($0.message.title?.lowercased().contains(q) ?? false)
                || ($0.message.tags?.contains { $0.lowercased().contains(q) } ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if items.isEmpty {
                EmptyMessagesView(isSubscription: subscription != nil)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { item in
                                MessageRowView(
                                    stored: item,
                                    subscriptionName: manager.subscription(id: item.subscriptionID)?.name ?? "Topic",
                                    accent: manager.subscription(id: item.subscriptionID)?.accentColor ?? .accentColor,
                                    showSource: subscription == nil
                                )
                                .id(item.id)
                                .onTapGesture {
                                    selectedMessageID = item.id
                                    manager.markRead(subscriptionID: item.subscriptionID, messageID: item.message.id)
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                        .stroke(selectedMessageID == item.id ? Color.accentColor : .clear, lineWidth: 2)
                                )
                            }
                        }
                        .padding(12)
                    }
                    // `.task(id:)` fires both on change and when this view first
                    // appears, so a reveal queued before the window opened (e.g.
                    // tapping a notification while closed) still selects/scrolls
                    // to the message.
                    .task(id: manager.pendingReveal?.messageID) {
                        guard let reveal = manager.pendingReveal else { return }
                        let id = "\(reveal.subscriptionID.uuidString)::\(reveal.messageID)"
                        // Give a freshly-opened window a moment to lay out its
                        // list before selecting/scrolling.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        selectedMessageID = id
                        withAnimation { proxy.scrollTo(id, anchor: .top) }
                        manager.pendingReveal = nil
                    }
                }
            }
        }
        .sheet(isPresented: $showingCompose) {
            if let subscription {
                ComposeView(subscription: subscription)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 140)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            // ⌘F focuses the search field, as in every standard Mac app.
            .overlay {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            }

            if subscription != nil {
                Button { showingCompose = true } label: {
                    Image(systemName: "paperplane")
                }
                .help("Publish a message to this topic")
            }

            Menu {
                Button("Mark All Read", systemImage: "checkmark.circle") {
                    manager.markAllRead(subscriptionID: subscription?.id)
                }
                Button("Clear History", systemImage: "trash", role: .destructive) {
                    manager.clearHistory(subscriptionID: subscription?.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(14)
    }

    private var title: String {
        switch selection {
        case .all: return "All Messages"
        case .subscription: return subscription?.name ?? "Topic"
        }
    }

    private var subtitle: String {
        switch selection {
        case .all:
            return "\(manager.messages.count) messages across \(manager.subscriptions.count) topics"
        case let .subscription(id):
            let state = manager.state(for: id)
            return "\(subscription?.topicURLString ?? "") · \(state.label)"
        }
    }
}

struct EmptyMessagesView: View {
    var isSubscription: Bool
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell.badge")
                .font(.system(size: 46))
                .foregroundStyle(Theme.brandGradient)
            Text("No messages yet")
                .font(.title3.weight(.semibold))
            Text(isSubscription
                 ? "Messages published to this topic will appear here in real time."
                 : "Subscribe to a topic to start receiving notifications.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
