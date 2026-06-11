//
//  AppSettings.swift
//  NtfyMac
//
//  User preferences, backed by UserDefaults.
//

import Foundation
import Combine

enum NetworkProxyMode: String, CaseIterable, Identifiable {
    case system
    case manualHTTP
    case direct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Use macOS system proxy"
        case .manualHTTP: return "Manual HTTP proxy"
        case .direct: return "Direct connection"
        }
    }

    var helpText: String {
        switch self {
        case .system:
            return "Use the proxy configured in macOS/Clash Verge system settings."
        case .manualHTTP:
            return "Send ntfy HTTP streaming, publish, and test requests through the specified HTTP CONNECT proxy."
        case .direct:
            return "Bypass proxies for ntfy traffic."
        }
    }
}

enum NetworkProxyDefaults {
    static let modeKey = "networkProxyMode"
    static let hostKey = "networkProxyHost"
    static let portKey = "networkProxyPort"
    static let defaultMode = NetworkProxyMode.system
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 7890
}

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
        static let networkProxyMode = NetworkProxyDefaults.modeKey
        static let networkProxyHost = NetworkProxyDefaults.hostKey
        static let networkProxyPort = NetworkProxyDefaults.portKey
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
    @Published var networkProxyMode: NetworkProxyMode {
        didSet { defaults.set(networkProxyMode.rawValue, forKey: Keys.networkProxyMode) }
    }
    @Published var networkProxyHost: String {
        didSet { defaults.set(networkProxyHost, forKey: Keys.networkProxyHost) }
    }
    @Published var networkProxyPort: Int {
        didSet { defaults.set(networkProxyPort, forKey: Keys.networkProxyPort) }
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
            Keys.networkProxyMode: NetworkProxyDefaults.defaultMode.rawValue,
            Keys.networkProxyHost: NetworkProxyDefaults.defaultHost,
            Keys.networkProxyPort: NetworkProxyDefaults.defaultPort,
        ])
        defaultServer = defaults.string(forKey: Keys.defaultServer) ?? "https://ntfy.sh"
        showNotifications = defaults.bool(forKey: Keys.showNotifications)
        playSound = defaults.bool(forKey: Keys.playSound)
        minNotificationPriority = defaults.integer(forKey: Keys.minPriority)
        historyLimitPerTopic = defaults.integer(forKey: Keys.historyLimit)
        showMenuBarCount = defaults.bool(forKey: Keys.showMenuBarCount)
        openWindowAtLaunch = defaults.bool(forKey: Keys.openWindowAtLaunch)
        launchAtLogin = LaunchAtLogin.isEnabled
        let proxyModeRaw = defaults.string(forKey: Keys.networkProxyMode)
            ?? NetworkProxyDefaults.defaultMode.rawValue
        networkProxyMode = NetworkProxyMode(rawValue: proxyModeRaw)
            ?? NetworkProxyDefaults.defaultMode
        networkProxyHost = defaults.string(forKey: Keys.networkProxyHost)
            ?? NetworkProxyDefaults.defaultHost
        let storedProxyPort = defaults.integer(forKey: Keys.networkProxyPort)
        networkProxyPort = storedProxyPort > 0
            ? storedProxyPort
            : NetworkProxyDefaults.defaultPort
    }
}
