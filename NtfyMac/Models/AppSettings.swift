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
        static let openWindowAtLaunch = "openWindowAtLaunch"
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
    /// Show the main window when the app launches (off = start in the menu bar
    /// only, useful when launching at login).
    @Published var openWindowAtLaunch: Bool {
        didSet { defaults.set(openWindowAtLaunch, forKey: Keys.openWindowAtLaunch) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            LaunchAtLogin.setEnabled(launchAtLogin)
        }
    }

    // Proxy handling for all ntfy traffic; see ProxyConfig for the rationale.
    @Published var proxyMode: ProxyMode {
        didSet {
            defaults.set(proxyMode.rawValue, forKey: ProxyConfig.Keys.mode)
            notifyProxyChanged()
        }
    }
    @Published var proxyType: ProxyType {
        didSet {
            defaults.set(proxyType.rawValue, forKey: ProxyConfig.Keys.type)
            notifyProxyChanged()
        }
    }
    @Published var proxyHost: String {
        didSet {
            defaults.set(proxyHost, forKey: ProxyConfig.Keys.host)
            notifyProxyChanged()
        }
    }
    @Published var proxyPort: Int {
        didSet {
            defaults.set(proxyPort, forKey: ProxyConfig.Keys.port)
            notifyProxyChanged()
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
            Keys.openWindowAtLaunch: true,
        ])
        defaults.register(defaults: ProxyConfig.registrationDefaults)
        defaultServer = defaults.string(forKey: Keys.defaultServer) ?? "https://ntfy.sh"
        showNotifications = defaults.bool(forKey: Keys.showNotifications)
        playSound = defaults.bool(forKey: Keys.playSound)
        minNotificationPriority = defaults.integer(forKey: Keys.minPriority)
        historyLimitPerTopic = defaults.integer(forKey: Keys.historyLimit)
        showMenuBarCount = defaults.bool(forKey: Keys.showMenuBarCount)
        openWindowAtLaunch = defaults.bool(forKey: Keys.openWindowAtLaunch)
        launchAtLogin = LaunchAtLogin.isEnabled

        let proxy = ProxyConfig.current(defaults: defaults)
        proxyMode = proxy.mode
        proxyType = proxy.type
        proxyHost = proxy.host
        proxyPort = proxy.port
    }

    private func notifyProxyChanged() {
        NotificationCenter.default.post(name: .ntfyProxyConfigChanged, object: nil)
    }
}
