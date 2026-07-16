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
        static let quietHoursEnabled = "quietHoursEnabled"
        static let quietStartMinutes = "quietStartMinutes"
        static let quietEndMinutes = "quietEndMinutes"
        static let notificationsPausedUntil = "notificationsPausedUntil"
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
    @Published var quietHoursEnabled: Bool {
        didSet { defaults.set(quietHoursEnabled, forKey: Keys.quietHoursEnabled) }
    }
    /// Minutes after midnight in the user's current calendar/time zone.
    @Published var quietStartMinutes: Int {
        didSet { defaults.set(quietStartMinutes, forKey: Keys.quietStartMinutes) }
    }
    @Published var quietEndMinutes: Int {
        didSet { defaults.set(quietEndMinutes, forKey: Keys.quietEndMinutes) }
    }
    @Published var notificationsPausedUntil: Date? {
        didSet {
            if let notificationsPausedUntil {
                defaults.set(notificationsPausedUntil, forKey: Keys.notificationsPausedUntil)
            } else {
                defaults.removeObject(forKey: Keys.notificationsPausedUntil)
            }
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
            Keys.quietHoursEnabled: false,
            Keys.quietStartMinutes: 22 * 60,
            Keys.quietEndMinutes: 8 * 60,
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
        quietHoursEnabled = defaults.bool(forKey: Keys.quietHoursEnabled)
        quietStartMinutes = defaults.integer(forKey: Keys.quietStartMinutes)
        quietEndMinutes = defaults.integer(forKey: Keys.quietEndMinutes)
        notificationsPausedUntil = defaults.object(forKey: Keys.notificationsPausedUntil) as? Date

        let proxy = ProxyConfig.current(defaults: defaults)
        proxyMode = proxy.mode
        proxyType = proxy.type
        proxyHost = proxy.host
        proxyPort = proxy.port
    }

    private func notifyProxyChanged() {
        NotificationCenter.default.post(name: .ntfyProxyConfigChanged, object: nil)
    }

    func pauseNotifications(for interval: TimeInterval, from date: Date = Date()) {
        notificationsPausedUntil = date.addingTimeInterval(interval)
    }

    func pauseUntilTomorrowMorning(from date: Date = Date(), calendar: Calendar = .current) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        notificationsPausedUntil = calendar.date(
            bySettingHour: 8,
            minute: 0,
            second: 0,
            of: tomorrow
        ) ?? tomorrow
    }

    func resumeNotifications() {
        notificationsPausedUntil = nil
    }

    func isTemporarilyPaused(at date: Date = Date()) -> Bool {
        guard let until = notificationsPausedUntil else { return false }
        return until > date
    }

    func isInQuietHours(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let current = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let start = max(0, min(1_439, quietStartMinutes))
        let end = max(0, min(1_439, quietEndMinutes))
        guard start != end else { return false }
        if start < end { return current >= start && current < end }
        return current >= start || current < end
    }

    func canDeliverNotification(at date: Date = Date()) -> Bool {
        showNotifications && !isTemporarilyPaused(at: date) && !isInQuietHours(at: date)
    }
}
