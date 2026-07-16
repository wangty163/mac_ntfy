//
//  SettingsView.swift
//  NtfyMac
//

import SwiftUI
import UserNotifications
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var manager: SubscriptionManager
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var backupStatus: String?
    @State private var backupFailed = false

    private var authIsGranted: Bool {
        authStatus == .authorized || authStatus == .provisional
    }

    private var authStatusText: String {
        switch authStatus {
        case .authorized: return "Notifications allowed"
        case .provisional: return "Notifications allowed (quiet)"
        case .denied: return "Notifications denied"
        case .notDetermined: return "Notification permission not requested yet"
        @unknown default: return "Unknown notification status"
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        if let label = info["NtfyBuildVersionLabel"] as? String, !label.isEmpty {
            return "Version \(label)"
        }

        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else {
            return "Version \(version)"
        }
        return "Version \(version) (build \(build))"
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 520)
        .toggleStyle(.switch)
        .tint(Theme.settingsControlTint)
        .onAppear { SettingsWindow.focusSoon() }
        .onDisappear { AppActivation.exitWindowModeIfNeeded() }
    }

    private var generalTab: some View {
        Form {
            Section {
                TextField("Default server", text: $settings.defaultServer)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Show window at launch", isOn: $settings.openWindowAtLaunch)
                Toggle("Show unread badge in menu bar", isOn: $settings.showMenuBarCount)
            }
            Section("Proxy") {
                Picker("Connection", selection: $settings.proxyMode) {
                    ForEach(ProxyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                if settings.proxyMode == .custom {
                    Picker("Protocol", selection: $settings.proxyType) {
                        ForEach(ProxyType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    TextField("Host", text: $settings.proxyHost)
                    TextField("Port", value: $settings.proxyPort,
                              format: .number.grouping(.never))
                }
                Text(proxyFooter)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Stepper("Keep \(settings.historyLimitPerTopic) messages per topic",
                        value: $settings.historyLimitPerTopic, in: 20...2000, step: 20)
                Button("Clear all message history", role: .destructive) {
                    manager.clearHistory()
                }
            }
            Section("Backup & Migration") {
                HStack {
                    Button("Export Configuration…", systemImage: "square.and.arrow.up") {
                        exportConfiguration()
                    }
                    Button("Import & Merge…", systemImage: "square.and.arrow.down") {
                        importConfiguration()
                    }
                }
                Text("Backups include subscriptions and settings, but never passwords, access tokens, message history, or sync cursors. Existing credentials are preserved when importing a matching subscription.")
                    .font(.caption).foregroundStyle(.secondary)
                if let backupStatus {
                    Label(backupStatus, systemImage: backupFailed ? "xmark.circle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(backupFailed ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var proxyFooter: String {
        switch settings.proxyMode {
        case .direct:
            return "Connects directly, ignoring the macOS system proxy. Recommended when a tool like Clash or Surge manages the system proxy — long-lived notification streams often stall behind it even for DIRECT rules."
        case .system:
            return "Follows the macOS system proxy. Note: system-proxy tools may buffer or drop the long-lived notification stream; if topics show as offline, switch to Direct or a custom proxy."
        case .custom:
            return "Routes all ntfy traffic through this proxy explicitly. Use a proxy port that supports streaming (e.g. Clash's mixed/SOCKS5 port). Changes reconnect automatically."
        }
    }

    private func exportConfiguration() {
        do {
            let data = try manager.exportConfiguration()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "NtfyMac-Configuration-\(Date().formatted(.iso8601.year().month().day()))"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            backupFailed = false
            backupStatus = "Configuration exported without credentials."
        } catch {
            backupFailed = true
            backupStatus = error.localizedDescription
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let summary = try manager.importConfiguration(data)
            backupFailed = false
            backupStatus = summary.description
        } catch {
            backupFailed = true
            backupStatus = error.localizedDescription
        }
    }

    private var notificationsTab: some View {
        Form {
            Section("Permission") {
                HStack {
                    Image(systemName: authIsGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(authIsGranted ? .green : .orange)
                    Text(authStatusText)
                    Spacer()
                    if !authIsGranted {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                if !authIsGranted {
                    Text("macOS won't show notifications until permission is granted. If this app isn't listed in System Settings, the build may be unsigned — install a signed release.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Show macOS notifications", isOn: $settings.showNotifications)
                Toggle("Play sound", isOn: $settings.playSound)
            }
            Section("Minimum priority to alert") {
                Picker("Only notify at or above", selection: $settings.minNotificationPriority) {
                    ForEach(NtfyPriority.allCases, id: \.self) { p in
                        Text("\(p.rawValue) · \(p.label)").tag(p.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("Lower-priority messages are still stored in history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pause notifications") {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack {
                        if settings.isTemporarilyPaused(at: context.date),
                           let until = settings.notificationsPausedUntil {
                            Label("Paused until \(until.formatted(date: .omitted, time: .shortened))",
                                  systemImage: "bell.slash.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Resume") { settings.resumeNotifications() }
                        } else {
                            Menu("Pause temporarily") {
                                Button("For 1 hour") { settings.pauseNotifications(for: 60 * 60) }
                                Button("For 4 hours") { settings.pauseNotifications(for: 4 * 60 * 60) }
                                Button("Until tomorrow at 8:00") {
                                    settings.pauseUntilTomorrowMorning()
                                }
                            }
                        }
                    }
                }
                Text("Messages continue to sync and remain unread; only macOS alerts are paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quiet hours") {
                Toggle("Enable quiet hours", isOn: $settings.quietHoursEnabled)
                if settings.quietHoursEnabled {
                    DatePicker("From", selection: quietTimeBinding(\.quietStartMinutes),
                               displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: quietTimeBinding(\.quietEndMinutes),
                               displayedComponents: .hourAndMinute)
                }
                Text("Overnight ranges are supported. Messages are still stored during quiet hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Open System Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshAuthStatus() }
    }

    private func refreshAuthStatus() {
        NotificationService.shared.currentAuthorizationStatus { authStatus = $0 }
    }

    private func quietTimeBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let start = Calendar.current.startOfDay(for: Date())
                return Calendar.current.date(
                    byAdding: .minute,
                    value: settings[keyPath: keyPath],
                    to: start
                ) ?? start
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var aboutTab: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 80, height: 80)
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 36)).foregroundStyle(.white)
            }
            Text("Ntfy for Mac").font(.title2.bold())
            Text(versionText)
                .font(.caption).foregroundStyle(.secondary)
            Text("A native menu-bar client for ntfy.sh and self-hosted ntfy servers.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            Link("ntfy documentation", destination: URL(string: "https://docs.ntfy.sh")!)
                .font(.callout)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
