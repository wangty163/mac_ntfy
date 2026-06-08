//
//  SubscriptionManager.swift
//  NtfyMac
//
//  The app's brain: owns subscriptions + message history, drives one
//  NtfyConnection per topic, persists state, and reconnects everything when the
//  network returns or the machine wakes from sleep.
//

import Foundation
import Combine
import Network
import AppKit

@MainActor
final class SubscriptionManager: ObservableObject {
    @Published private(set) var subscriptions: [Subscription] = []
    @Published private(set) var messages: [StoredMessage] = []
    @Published private(set) var states: [UUID: ConnectionState] = [:]

    private let settings: AppSettings
    private let store = PersistenceStore.shared
    private var connections: [UUID: NtfyConnection] = [:]

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.ntfymac.network-monitor")
    private var hasNetwork = true

    init(settings: AppSettings) {
        self.settings = settings
        self.subscriptions = store.loadSubscriptions()
        self.messages = store.loadMessages()

        NotificationService.shared.onActivated = { [weak self] subID, messageID in
            self?.markRead(subscriptionID: subID, messageID: messageID)
            self?.pendingReveal = (subID, messageID)
        }

        startMonitoring()
        connectAll()
    }

    /// A message the UI should scroll to/select after a notification tap.
    @Published var pendingReveal: (subscriptionID: UUID, messageID: String)?

    // MARK: - Derived data

    var totalUnread: Int {
        messages.filter { !$0.isRead }.count
    }

    func unreadCount(for subscriptionID: UUID) -> Int {
        messages.filter { $0.subscriptionID == subscriptionID && !$0.isRead }.count
    }

    func messages(for subscriptionID: UUID) -> [StoredMessage] {
        messages
            .filter { $0.subscriptionID == subscriptionID }
            .sorted { $0.message.time > $1.message.time }
    }

    var recentMessages: [StoredMessage] {
        messages.sorted { $0.receivedAt > $1.receivedAt }
    }

    func state(for subscriptionID: UUID) -> ConnectionState {
        states[subscriptionID] ?? .idle
    }

    var anyConnected: Bool {
        states.values.contains { $0.isConnected }
    }

    func subscription(id: UUID) -> Subscription? {
        subscriptions.first { $0.id == id }
    }

    // MARK: - CRUD

    func addSubscription(_ sub: Subscription) {
        subscriptions.append(sub)
        persistSubscriptions()
        connect(sub)
    }

    func updateSubscription(_ sub: Subscription) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) else { return }
        let old = subscriptions[idx]
        var sub = sub

        // A different topic/server invalidates the `since` cursor.
        let endpointChanged = old.normalizedBaseURL != sub.normalizedBaseURL || old.topic != sub.topic
        if endpointChanged { sub.lastMessageID = nil }

        subscriptions[idx] = sub
        persistSubscriptions()

        // Reconnect only when something connection-relevant changed.
        let needsReconnect = endpointChanged
            || old.auth != sub.auth
            || old.filters != sub.filters
            || old.isMuted != sub.isMuted

        connections[sub.id]?.updateSubscription(sub)
        if needsReconnect {
            connect(sub, restart: true)
        }
    }

    func removeSubscription(_ id: UUID) {
        connections[id]?.stop()
        connections[id] = nil
        states[id] = nil
        subscriptions.removeAll { $0.id == id }
        messages.removeAll { $0.subscriptionID == id }
        persistSubscriptions()
        persistMessages()
    }

    // MARK: - Connections

    func connectAll() {
        for sub in subscriptions { connect(sub) }
    }

    func reconnectAll() {
        for (_, connection) in connections { connection.restart() }
    }

    private func connect(_ sub: Subscription, restart: Bool = false) {
        if sub.isMuted {
            connections[sub.id]?.stop()
            return
        }
        if let existing = connections[sub.id] {
            existing.updateSubscription(sub)
            if restart { existing.restart() }
            else if !existing.isRunning { existing.start() }
            return
        }
        let connection = NtfyConnection(subscription: sub)
        connection.onStateChange = { [weak self] state in
            self?.states[sub.id] = state
        }
        connection.onMessage = { [weak self] message in
            self?.ingest(message, for: sub.id)
        }
        connections[sub.id] = connection
        connection.start()
    }

    // MARK: - Message ingestion

    private func ingest(_ message: NtfyMessage, for subscriptionID: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }

        // Deduplicate by ntfy message id within the subscription.
        let storedID = "\(subscriptionID.uuidString)::\(message.id)"
        if messages.contains(where: { $0.id == storedID }) {
            updateCursor(message.id, for: idx)
            return
        }

        let stored = StoredMessage(subscriptionID: subscriptionID, message: message)
        messages.append(stored)
        trimHistory(for: subscriptionID)
        updateCursor(message.id, for: idx)
        persistMessages()

        // Surface as a native notification when allowed.
        let sub = subscriptions[idx]
        let priority = message.resolvedPriority.rawValue
        let allowed = settings.showNotifications
            && sub.notificationsEnabled
            && !sub.isMuted
            && priority >= settings.minNotificationPriority

        if allowed {
            NotificationService.shared.present(
                message: message,
                subscription: sub,
                playSound: settings.playSound
            )
        }
    }

    private func updateCursor(_ messageID: String, for index: Int) {
        subscriptions[index].lastMessageID = messageID
        connections[subscriptions[index].id]?.updateSubscription(subscriptions[index])
        persistSubscriptions()
    }

    private func trimHistory(for subscriptionID: UUID) {
        let limit = max(20, settings.historyLimitPerTopic)
        let forSub = messages.filter { $0.subscriptionID == subscriptionID }
        guard forSub.count > limit else { return }
        let toRemove = forSub
            .sorted { $0.message.time < $1.message.time }
            .prefix(forSub.count - limit)
            .map(\.id)
        let removeSet = Set(toRemove)
        messages.removeAll { removeSet.contains($0.id) }
    }

    // MARK: - Read state

    func markRead(subscriptionID: UUID, messageID: String) {
        let storedID = "\(subscriptionID.uuidString)::\(messageID)"
        guard let idx = messages.firstIndex(where: { $0.id == storedID }) else { return }
        guard !messages[idx].isRead else { return }
        messages[idx].isRead = true
        persistMessages()
    }

    func markAllRead(subscriptionID: UUID? = nil) {
        var changed = false
        for idx in messages.indices {
            if let subscriptionID, messages[idx].subscriptionID != subscriptionID { continue }
            if !messages[idx].isRead { messages[idx].isRead = true; changed = true }
        }
        if changed { persistMessages() }
    }

    func clearHistory(subscriptionID: UUID? = nil) {
        if let subscriptionID {
            messages.removeAll { $0.subscriptionID == subscriptionID }
        } else {
            messages.removeAll()
        }
        persistMessages()
    }

    // MARK: - System monitoring

    private func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let wasOffline = !self.hasNetwork
                self.hasNetwork = online
                if online && wasOffline {
                    self.reconnectAll()
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconnectAll() }
        }
    }

    // MARK: - Persistence

    private func persistSubscriptions() {
        store.saveSubscriptions(subscriptions)
    }

    private func persistMessages() {
        store.saveMessages(messages)
    }
}
