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
    @State private var selectedMessageIDs: Set<String> = []
    @State private var lastSelectedMessageID: String?

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
                                Button {
                                    selectMessage(item.id)
                                } label: {
                                    MessageRowView(
                                        stored: item,
                                        subscriptionName: manager.subscription(id: item.subscriptionID)?.name ?? "Topic",
                                        accent: manager.subscription(id: item.subscriptionID)?.accentColor ?? .accentColor,
                                        showSource: subscription == nil
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .background(
                                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                            .stroke(
                                                selectedMessageIDs.contains(item.id)
                                                    ? Color.accentColor
                                                    : .clear,
                                                lineWidth: 2
                                            )
                                    )
                                }
                                .buttonStyle(MessageSelectionButtonStyle())
                                .id(item.id)
                                .contextMenu {
                                    messageContextMenu(for: item)
                                }
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
        .onChange(of: selectedMessageID) { newValue in
            guard let newValue else {
                selectedMessageIDs.removeAll()
                lastSelectedMessageID = nil
                return
            }

            if !selectedMessageIDs.contains(newValue) {
                selectedMessageIDs = [newValue]
                lastSelectedMessageID = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedMessages)) { _ in
            guard !selectedMessageIDs.isEmpty else { return }
            deleteMessages(selectedMessageIDs)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(.title2, weight: .bold)
                Text(subtitle).appFont(.caption).foregroundStyle(.secondary)
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

    private func selectMessage(_ id: String) {
        let modifiers = NSEvent.modifierFlags
        let commandPressed = modifiers.contains(.command)
        let shiftPressed = modifiers.contains(.shift)

        if commandPressed {
            if selectedMessageIDs.contains(id) {
                selectedMessageIDs.remove(id)

                // If the primary message was deselected,
                // display another selected message.
                if selectedMessageID == id {
                    selectedMessageID = selectedMessageIDs.first
                }
            } else {
                selectedMessageIDs.insert(id)
                selectedMessageID = id
            }

            lastSelectedMessageID = id
        } else if shiftPressed {
            // Shift-click: select a contiguous range.
            if let anchor = lastSelectedMessageID,
            let start = items.firstIndex(where: { $0.id == anchor }),
            let end = items.firstIndex(where: { $0.id == id }) {

                let lower = min(start, end)
                let upper = max(start, end)

                selectedMessageIDs = Set(
                    items[lower...upper].map(\.id)
                )
            } else {
                selectedMessageIDs = [id]
                lastSelectedMessageID = id
            }

            selectedMessageID = id

        } else {
            // Normal click: select only one message.
            selectedMessageIDs = [id]
            lastSelectedMessageID = id
            selectedMessageID = id
        }

        // Mark the clicked message as read.
        if let item = items.first(where: { $0.id == id }) {
            manager.markRead(
                subscriptionID: item.subscriptionID,
                messageID: item.message.id
            )
        }
    }

    private func deleteMessages(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }

        // Clear the detail pane if its message is being deleted.
        if let selectedMessageID, ids.contains(selectedMessageID) {
            self.selectedMessageID = nil
        }

        // Delete messages.
        for id in ids {
            manager.deleteMessage(id: id)
        }

        // Update selection state.
        selectedMessageIDs.subtract(ids)

        if let lastSelectedMessageID,
        ids.contains(lastSelectedMessageID) {
            self.lastSelectedMessageID = nil
        }
    }

    private func messageContextMenu(for item: StoredMessage) -> some View {
        let isSelected = selectedMessageIDs.contains(item.id)
        let hasMultipleSelected = selectedMessageIDs.count > 1

        let title = contextMenuDeleteTitle(
            isSelected: isSelected,
            hasMultipleSelected: hasMultipleSelected
        )
        let idsToDelete = isSelected && hasMultipleSelected
            ? selectedMessageIDs
            : [item.id]

        return Button(title, systemImage: "trash", role: .destructive) {
            deleteMessages(idsToDelete)
        }
    }

    private func contextMenuDeleteTitle(isSelected: Bool, hasMultipleSelected: Bool) -> String {
        if isSelected && hasMultipleSelected {
            return "Delete selected messages"
        }
        if isSelected {
            return "Delete selected message"
        }
        return "Delete right-clicked message"
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
                .appFont(.title3, weight: .semibold)
            Text(isSubscription
                 ? "Messages published to this topic will appear here in real time."
                 : "Subscribe to a topic to start receiving notifications.")
                .appFont(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
