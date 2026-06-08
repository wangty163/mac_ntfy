//
//  SettingsView.swift
//  NtfyMac
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var manager: SubscriptionManager
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

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

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 380)
        .onAppear { AppActivation.enterWindowMode() }
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
            Section("History") {
                Stepper("Keep \(settings.historyLimitPerTopic) messages per topic",
                        value: $settings.historyLimitPerTopic, in: 20...2000, step: 20)
                Button("Clear all message history", role: .destructive) {
                    manager.clearHistory()
                }
            }
        }
        .formStyle(.grouped)
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
            Text("Version 1.0")
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
