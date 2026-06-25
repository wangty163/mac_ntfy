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
    /// Subscriptions that are currently not connected (offline or stuck
    /// reconnecting). Drives the menu-bar trouble indicator. Sticky across a
    /// reconnect attempt so the brief `.connecting` phase doesn't clear it.
    @Published private(set) var offlineSubscriptionIDs: Set<UUID> = []
    /// Pending grace-period tasks for the offline notification, keyed by
    /// subscription, so a quick reconnect can cancel the alert before it fires.
    private var dropNotifyTasks: [UUID: Task<Void, Never>] = [:]
    /// Subscriptions that have connected at least once since their current
    /// endpoint was set. Used to distinguish a real outage (was working, now
    /// down) from one that never managed to connect, so we only alert on the
    /// former.
    private var everConnectedIDs: Set<UUID> = []
    /// Subscriptions for which an offline notification was actually delivered, so
    /// that a matching "back online" notification is posted only after a real,
    /// announced outage (not after a brief blip that was never announced).
    private var notifiedOfflineIDs: Set<UUID> = []

    private let settings: AppSettings
    private let store = PersistenceStore.shared
    private var connections: [UUID: NtfyConnection] = [:]

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.ntfymac.network-monitor")
    private var cancellables = Set<AnyCancellable>()
    private var hasNetwork = true
    /// Which interfaces the current path uses (e.g. ["en0"]). Switching Wi-Fi
    /// networks or hopping between Wi-Fi/Ethernet/VPN keeps the path
    /// "satisfied" but silently kills established streams, so we track the
    /// interface set and reconnect when it changes.
    private var pathInterfaces: Set<String>?
    /// Watches `/etc/hosts` so that editing the file (e.g. pointing a hostname
    /// at a new IP after the server moved) reconnects the running app on its
    /// own, without a quit/relaunch.
    private var hostsWatcher: HostsFileWatcher?
    private let hostsChanged = PassthroughSubject<Void, Never>()

    init(settings: AppSettings) {
        self.settings = settings
        self.subscriptions = store.loadSubscriptions()
        self.messages = store.loadMessages()

        NotificationService.shared.onActivated = { [weak self] subID, messageID in
            self?.markRead(subscriptionID: subID, messageID: messageID)
            // Set the reveal target *before* surfacing the window so the views
            // pick it up as they appear (the window may be closed at this point).
            self?.pendingReveal = (subID, messageID)
            MainWindow.show()
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

    /// True when at least one (non-muted) subscription is offline — used to badge
    /// the menu-bar icon so a dropped connection is visible without opening a
    /// window.
    var hasOfflineSubscriptions: Bool {
        !offlineSubscriptionIDs.isEmpty
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
        if endpointChanged {
            sub.lastMessageID = nil
            // The new endpoint must connect once before a drop counts as an
            // outage, so it isn't immediately reported offline if unreachable.
            everConnectedIDs.remove(sub.id)
            notifiedOfflineIDs.remove(sub.id)
        }

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
        offlineSubscriptionIDs.remove(id)
        everConnectedIDs.remove(id)
        notifiedOfflineIDs.remove(id)
        cancelPendingDropNotification(id)
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
            offlineSubscriptionIDs.remove(sub.id)
            notifiedOfflineIDs.remove(sub.id)
            cancelPendingDropNotification(sub.id)
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
            self?.handleStateChange(sub.id, state)
        }
        connection.onCursorInvalidated = { [weak self] in
            self?.clearCursor(for: sub.id)
        }
        connection.onMessage = { [weak self] message in
            self?.ingest(message, for: sub.id)
        }
        connections[sub.id] = connection
        connection.start()
    }

    /// Tracks per-subscription connection state, maintains the offline set that
    /// badges the menu bar, and fires a one-shot notification the moment a live
    /// connection drops.
    private func handleStateChange(_ id: UUID, _ newState: ConnectionState) {
        states[id] = newState

        switch newState {
        case .connected:
            everConnectedIDs.insert(id)
            offlineSubscriptionIDs.remove(id)
            cancelPendingDropNotification(id)
            // Mirror the offline alert: announce recovery only if we actually
            // told the user it had gone offline.
            if notifiedOfflineIDs.remove(id) != nil,
               settings.showNotifications,
               let sub = subscription(id: id), !sub.isMuted {
                NotificationService.shared.presentConnectionRestored(subscription: sub)
            }
        case .disconnected(let reason):
            markOffline(id, reason: reason)
        case .reconnecting:
            markOffline(id, reason: "The connection to the server was lost. Reconnecting…")
        case .connecting, .idle:
            // Sticky: leave the offline flag as-is. A still-broken subscription
            // briefly passes through `.connecting` on each retry (and `.idle` on
            // restart); keeping the flag avoids the badge flickering off while it
            // is plainly still down.
            break
        }
    }

    /// Flag a subscription offline and, on the *first* transition into an outage
    /// (not repeats within the same outage), alert if it had previously been
    /// connected. Keying on "ever connected" rather than "the immediately
    /// previous state was connected" means an outage that arrives via a restart
    /// — `reconnectAll()` after a network/hosts change passes through
    /// `.idle`/`.connecting` first — still notifies.
    private func markOffline(_ id: UUID, reason: String) {
        let freshlyOffline = !offlineSubscriptionIDs.contains(id)
        offlineSubscriptionIDs.insert(id)
        guard freshlyOffline, everConnectedIDs.contains(id),
              settings.showNotifications,
              let sub = subscription(id: id), !sub.isMuted else { return }
        scheduleDropNotification(for: sub, reason: reason)
    }

    /// Fire the offline notification only if the subscription is *still* down
    /// after a short grace period, so a brief blip (Wi-Fi switch, sleep/wake)
    /// that reconnects within seconds doesn't pop a banner.
    private func scheduleDropNotification(for sub: Subscription, reason: String) {
        dropNotifyTasks[sub.id]?.cancel()
        dropNotifyTasks[sub.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.offlineSubscriptionIDs.contains(sub.id) {
                NotificationService.shared.presentConnectionDrop(subscription: sub, reason: reason)
                self.notifiedOfflineIDs.insert(sub.id)
            }
            self.dropNotifyTasks[sub.id] = nil
        }
    }

    private func cancelPendingDropNotification(_ id: UUID) {
        dropNotifyTasks[id]?.cancel()
        dropNotifyTasks[id] = nil
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

    private func clearCursor(for subscriptionID: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        guard subscriptions[idx].lastMessageID != nil else { return }
        subscriptions[idx].lastMessageID = nil
        connections[subscriptionID]?.updateSubscription(subscriptions[idx])
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
            let online = path.status == .satisfied
            let interfaces = Set(path.availableInterfaces.map(\.name))
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = !self.hasNetwork
                let interfacesChanged = self.pathInterfaces != nil
                    && self.pathInterfaces != interfaces
                self.hasNetwork = online
                self.pathInterfaces = interfaces
                if online && (wasOffline || interfacesChanged) {
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
            Task { @MainActor [weak self] in self?.reconnectAll() }
        }

        // Proxy settings changed: tear down the streams so they come back up
        // with the new session configuration. Debounced because typing a host
        // or port fires once per keystroke.
        NotificationCenter.default.publisher(for: .ntfyProxyConfigChanged)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconnectAll() }
            }
            .store(in: &cancellables)

        // `/etc/hosts` changed: a host reachable only via a hosts override may
        // now point at a new IP. Reconnect so the streams re-resolve and pick it
        // up without the user quitting the app. Debounced because an editor save
        // can emit several filesystem events; the 1s delay also lets the system
        // resolver reload the file before we re-resolve.
        hostsChanged
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconnectAll() }
            }
            .store(in: &cancellables)
        hostsWatcher = HostsFileWatcher(path: "/etc/hosts") { [weak self] in
            Task { @MainActor [weak self] in self?.hostsChanged.send() }
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

/// Watches a single file (e.g. `/etc/hosts`) and calls `onChange` whenever it is
/// modified or replaced. Re-arms itself across atomic saves (write-to-temp +
/// rename), which replace the inode and would otherwise leave a vnode source
/// watching the old, now-orphaned file. All state is confined to `queue`.
final class HostsFileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.ntfymac.hosts-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    deinit {
        source?.cancel()
    }

    private func arm() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File momentarily absent (e.g. mid-rename); retry shortly.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
            return
        }
        descriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let flags = source.data
            self.onChange()
            // An atomic save replaces the file's inode; reopen to keep watching.
            if !flags.intersection([.delete, .rename]).isEmpty {
                self.rearm()
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        source = src
        src.resume()
    }

    private func rearm() {
        source?.cancel()   // closes the old descriptor via the cancel handler
        source = nil
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.arm() }
    }
}
