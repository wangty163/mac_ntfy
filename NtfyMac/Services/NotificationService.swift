//
//  NotificationService.swift
//  NtfyMac
//
//  Bridges ntfy messages to native macOS notifications via UserNotifications,
//  mapping ntfy priority onto interruption level / sound and forwarding clicks.
//

import Foundation
import UserNotifications
import AppKit

struct NativeNotificationText: Equatable {
    let title: String
    let body: String
}

enum NativeNotificationFormatter {
    static func format(topic: String, title: String, body: String) -> NativeNotificationText {
        let topicLine = "#\(topic)"
        let renderedBody: String
        if body.isEmpty {
            renderedBody = topicLine
        } else if body.hasSuffix("\n") {
            renderedBody = body + topicLine
        } else {
            renderedBody = "\(body)\n\(topicLine)"
        }

        return NativeNotificationText(
            title: title,
            body: renderedBody
        )
    }

    static func message(
        _ message: NtfyMessage,
        subscription: Subscription
    ) -> NativeNotificationText {
        let emojiPrefix = message.emojiTags.joined()
        let baseTitle = message.displayTitle(fallbackTopic: subscription.name)
        let title = emojiPrefix.isEmpty ? baseTitle : "\(emojiPrefix) \(baseTitle)"

        var body = message.message ?? ""
        if !message.labelTags.isEmpty {
            let chips = message.labelTags.map { "#\($0)" }.joined(separator: " ")
            body += body.isEmpty ? chips : "\n\(chips)"
        }
        if let attachment = message.attachment {
            let size = attachment.humanSize.map { " · \($0)" } ?? ""
            body += body.isEmpty ? "📎 \(attachment.name)\(size)" : "\n📎 \(attachment.name)\(size)"
        }

        return format(topic: subscription.name, title: title, body: body)
    }
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Invoked when the user clicks a delivered notification. Carries the
    /// subscription + message ids so the app can reveal it.
    var onActivated: ((_ subscriptionID: UUID, _ messageID: String) -> Void)?

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                NSLog("Notification authorization error: \(error.localizedDescription)")
            } else {
                NSLog("Notification authorization granted: \(granted)")
            }
        }
    }

    /// Posts a native notification for an incoming ntfy message.
    func present(message: NtfyMessage,
                 subscription: Subscription,
                 playSound: Bool) {
        let content = UNMutableNotificationContent()
        let text = NativeNotificationFormatter.message(message, subscription: subscription)
        content.title = text.title
        content.body = text.body

        // Group notifications from the same subscription together in
        // Notification Center.
        content.threadIdentifier = subscription.id.uuidString

        let priority = message.resolvedPriority
        content.interruptionLevel = interruptionLevel(for: priority)
        content.relevanceScore = Double(priority.rawValue) / 5.0

        if playSound && priority.rawValue >= 3 {
            // `.defaultCritical` / `.critical` interruption require the special
            // critical-alerts entitlement, so we stick to the default sound.
            content.sound = .default
        }

        content.userInfo = [
            "subscriptionID": subscription.id.uuidString,
            "messageID": message.id,
            "click": message.click ?? "",
        ]

        let request = UNNotificationRequest(
            identifier: "\(subscription.id.uuidString)-\(message.id)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    /// Posts a local notification when a subscription that was online drops, so
    /// the user is alerted to the outage even with no window open. Unlike message
    /// notifications this carries no message payload; a stable identifier means a
    /// repeat drop replaces the previous alert rather than stacking.
    func presentConnectionDrop(subscription: Subscription, reason: String) {
        let content = UNMutableNotificationContent()
        let body = reason.isEmpty
            ? "The connection to the server was lost. Reconnecting…"
            : reason
        let text = NativeNotificationFormatter.format(
            topic: subscription.name,
            title: "Subscription offline",
            body: body
        )
        content.title = text.title
        content.body = text.body
        content.interruptionLevel = .active
        content.threadIdentifier = "connection-\(subscription.id.uuidString)"
        content.userInfo = [
            "subscriptionID": subscription.id.uuidString,
            "messageID": "",
            "click": "",
        ]

        let request = UNNotificationRequest(
            identifier: "offline-\(subscription.id.uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("Failed to deliver offline notification: \(error.localizedDescription)")
            }
        }
    }

    /// Posts a local notification when a subscription that had dropped comes back
    /// online, and clears the earlier offline banner so Notification Center isn't
    /// left showing a stale "offline" next to the recovery.
    func presentConnectionRestored(subscription: Subscription) {
        center.removeDeliveredNotifications(
            withIdentifiers: ["offline-\(subscription.id.uuidString)"]
        )

        let content = UNMutableNotificationContent()
        let text = NativeNotificationFormatter.format(
            topic: subscription.name,
            title: "Subscription back online",
            body: "The connection to the server was restored."
        )
        content.title = text.title
        content.body = text.body
        content.interruptionLevel = .active
        content.threadIdentifier = "connection-\(subscription.id.uuidString)"
        content.userInfo = [
            "subscriptionID": subscription.id.uuidString,
            "messageID": "",
            "click": "",
        ]

        let request = UNNotificationRequest(
            identifier: "online-\(subscription.id.uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("Failed to deliver recovery notification: \(error.localizedDescription)")
            }
        }
    }

    /// Reads the current authorization status (for surfacing in the UI when the
    /// user hasn't granted permission yet).
    nonisolated func currentAuthorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    private func interruptionLevel(for priority: NtfyPriority) -> UNNotificationInterruptionLevel {
        switch priority {
        case .min, .low: return .passive
        case .default: return .active
        case .high, .max: return .timeSensitive
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banners + play sound even while the app is frontmost.
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let clickString = info["click"] as? String ?? ""
        let subIDString = info["subscriptionID"] as? String ?? ""
        let messageID = info["messageID"] as? String ?? ""

        Task { @MainActor in
            if !clickString.isEmpty, let url = URL(string: clickString) {
                NSWorkspace.shared.open(url)
            }
            if let subID = UUID(uuidString: subIDString) {
                self.onActivated?(subID, messageID)
            }
        }
        completionHandler()
    }
}
