//
//  AppSettings.swift
//  NtfyMac
//
//  User preferences, backed by UserDefaults.
//

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let defaultServer = "defaultServer"
        static let showNotifications = "showNotifications"
        static let playSound = "playSound"
        static let minPriority = "minPriority"
        static let historyLimit = "historyLimitPerTopic"
        static let launchAtLogin = "launchAtLogin"
        static let showMenuBarCount = "showMenuBarCount"
    }

    @Published var defaultServer: String {
        didSet { defaults.set(defaultServer, forKey: Keys.defaultServer) }
    }
    @Published var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: Keys.showNotifications) }
    }
    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Keys.playSound) }
    }
    /// Notifications below this priority are stored but not surfaced as alerts.
    @Published var minNotificationPriority: Int {
        didSet { defaults.set(minNotificationPriority, forKey: Keys.minPriority) }
    }
    @Published var historyLimitPerTopic: Int {
        didSet { defaults.set(historyLimitPerTopic, forKey: Keys.historyLimit) }
    }
    @Published var showMenuBarCount: Bool {
        didSet { defaults.set(showMenuBarCount, forKey: Keys.showMenuBarCount) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            LaunchAtLogin.setEnabled(launchAtLogin)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.defaultServer: "https://ntfy.sh",
            Keys.showNotifications: true,
            Keys.playSound: true,
            Keys.minPriority: 1,
            Keys.historyLimit: 200,
            Keys.showMenuBarCount: true,
        ])
        defaultServer = defaults.string(forKey: Keys.defaultServer) ?? "https://ntfy.sh"
        showNotifications = defaults.bool(forKey: Keys.showNotifications)
        playSound = defaults.bool(forKey: Keys.playSound)
        minNotificationPriority = defaults.integer(forKey: Keys.minPriority)
        historyLimitPerTopic = defaults.integer(forKey: Keys.historyLimit)
        showMenuBarCount = defaults.bool(forKey: Keys.showMenuBarCount)
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}
