//
//  ConfigurationBackup.swift
//  NtfyMac
//
//  Portable, versioned configuration backup. Credentials, message history and
//  sync cursors are deliberately excluded from the exported JSON.
//

import Foundation

struct ConfigurationBackup: Codable {
    static let currentVersion = 1

    let format: String
    let version: Int
    let createdAt: Date
    let subscriptions: [BackupSubscription]
    let settings: BackupSettings
}

struct BackupSubscription: Codable {
    let id: UUID
    let baseURL: String
    let topic: String
    let displayName: String
    let filters: SubscriptionFilters
    let notificationsEnabled: Bool
    let isMuted: Bool
    let accentHex: String

    init(_ subscription: Subscription) {
        id = subscription.id
        baseURL = subscription.normalizedBaseURL
        topic = subscription.topic
        displayName = subscription.displayName
        filters = subscription.filters
        notificationsEnabled = subscription.notificationsEnabled
        isMuted = subscription.isMuted
        accentHex = subscription.accentHex
    }

    func restored(id: UUID? = nil, auth: NtfyAuth = .none, cursor: String? = nil) -> Subscription {
        Subscription(
            id: id ?? self.id,
            baseURL: baseURL,
            topic: topic,
            displayName: displayName,
            auth: auth,
            filters: filters,
            notificationsEnabled: notificationsEnabled,
            isMuted: isMuted,
            accentHex: accentHex,
            lastMessageID: cursor
        )
    }
}

struct BackupSettings: Codable {
    let defaultServer: String
    let showNotifications: Bool
    let playSound: Bool
    let minNotificationPriority: Int
    let historyLimitPerTopic: Int
    let launchAtLogin: Bool
    let showMenuBarCount: Bool
    let openWindowAtLaunch: Bool
    let proxyMode: String
    let proxyType: String
    let proxyHost: String
    let proxyPort: Int
    let quietHoursEnabled: Bool
    let quietStartMinutes: Int
    let quietEndMinutes: Int

    @MainActor
    init(_ settings: AppSettings) {
        defaultServer = settings.defaultServer
        showNotifications = settings.showNotifications
        playSound = settings.playSound
        minNotificationPriority = settings.minNotificationPriority
        historyLimitPerTopic = settings.historyLimitPerTopic
        launchAtLogin = settings.launchAtLogin
        showMenuBarCount = settings.showMenuBarCount
        openWindowAtLaunch = settings.openWindowAtLaunch
        proxyMode = settings.proxyMode.rawValue
        proxyType = settings.proxyType.rawValue
        proxyHost = settings.proxyHost
        proxyPort = settings.proxyPort
        quietHoursEnabled = settings.quietHoursEnabled
        quietStartMinutes = settings.quietStartMinutes
        quietEndMinutes = settings.quietEndMinutes
    }

    @MainActor
    func apply(to settings: AppSettings) {
        settings.defaultServer = defaultServer
        settings.showNotifications = showNotifications
        settings.playSound = playSound
        settings.minNotificationPriority = max(1, min(5, minNotificationPriority))
        settings.historyLimitPerTopic = max(20, min(2_000, historyLimitPerTopic))
        settings.launchAtLogin = launchAtLogin
        settings.showMenuBarCount = showMenuBarCount
        settings.openWindowAtLaunch = openWindowAtLaunch
        settings.proxyMode = ProxyMode(rawValue: proxyMode) ?? .direct
        settings.proxyType = ProxyType(rawValue: proxyType) ?? .http
        settings.proxyHost = proxyHost
        settings.proxyPort = max(1, min(65_535, proxyPort))
        settings.quietHoursEnabled = quietHoursEnabled
        settings.quietStartMinutes = max(0, min(1_439, quietStartMinutes))
        settings.quietEndMinutes = max(0, min(1_439, quietEndMinutes))
    }
}

struct ConfigurationImportSummary {
    let added: Int
    let updated: Int

    var description: String {
        "Imported \(added) new and updated \(updated) existing subscription\(updated == 1 ? "" : "s"). Credentials were not changed."
    }
}

enum ConfigurationBackupError: LocalizedError {
    case invalidFormat
    case unsupportedVersion(Int)
    case tooManySubscriptions
    case invalidSubscription(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "This is not an NtfyMac configuration backup."
        case .unsupportedVersion(let version):
            return "Backup version \(version) is not supported by this app."
        case .tooManySubscriptions:
            return "The backup contains too many subscriptions."
        case .invalidSubscription(let topic):
            return "The backup contains an invalid subscription: \(topic.isEmpty ? "unnamed topic" : topic)."
        }
    }
}

enum ConfigurationBackupService {
    @MainActor
    static func encode(subscriptions: [Subscription], settings: AppSettings) throws -> Data {
        let backup = ConfigurationBackup(
            format: "NtfyMacConfiguration",
            version: ConfigurationBackup.currentVersion,
            createdAt: Date(),
            subscriptions: subscriptions.map(BackupSubscription.init),
            settings: BackupSettings(settings)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> ConfigurationBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(ConfigurationBackup.self, from: data)
        guard backup.format == "NtfyMacConfiguration" else {
            throw ConfigurationBackupError.invalidFormat
        }
        guard backup.version == ConfigurationBackup.currentVersion else {
            throw ConfigurationBackupError.unsupportedVersion(backup.version)
        }
        guard backup.subscriptions.count <= 10_000 else {
            throw ConfigurationBackupError.tooManySubscriptions
        }
        for subscription in backup.subscriptions {
            let topic = subscription.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty,
                  let components = URLComponents(string: subscription.baseURL),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host != nil else {
                throw ConfigurationBackupError.invalidSubscription(topic)
            }
        }
        return backup
    }

    static func merge(
        _ imported: [BackupSubscription],
        into current: [Subscription]
    ) -> (subscriptions: [Subscription], summary: ConfigurationImportSummary) {
        var merged = current
        var added = 0
        var updated = 0
        var seenKeys: Set<String> = []

        for item in imported {
            let key = configurationKey(baseURL: item.baseURL, topic: item.topic)
            guard seenKeys.insert(key).inserted else { continue }

            let index = merged.firstIndex(where: { $0.id == item.id })
                ?? merged.firstIndex(where: {
                    configurationKey(baseURL: $0.baseURL, topic: $0.topic) == key
                })

            if let index {
                let existing = merged[index]
                let sameEndpoint = configurationKey(
                    baseURL: existing.baseURL,
                    topic: existing.topic
                ) == key
                merged[index] = item.restored(
                    id: existing.id,
                    auth: existing.auth,
                    cursor: sameEndpoint ? existing.lastMessageID : nil
                )
                updated += 1
            } else {
                let importedID = merged.contains(where: { $0.id == item.id }) ? UUID() : item.id
                merged.append(item.restored(id: importedID))
                added += 1
            }
        }

        return (merged, ConfigurationImportSummary(added: added, updated: updated))
    }

    private static func configurationKey(baseURL: String, topic: String) -> String {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if !normalized.contains("://") { normalized = "https://" + normalized }
        return normalized.lowercased()
            + "\n"
            + topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
