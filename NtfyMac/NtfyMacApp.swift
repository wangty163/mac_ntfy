//
//  NtfyMacApp.swift
//  NtfyMac
//
//  App entry point. Runs as a menu-bar (LSUIElement) agent so it stays alive in
//  the background receiving messages, with an optional main window + settings.
//

import SwiftUI
import AppKit

@main
struct NtfyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings: AppSettings
    @StateObject private var manager: SubscriptionManager

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _manager = StateObject(wrappedValue: SubscriptionManager(settings: settings))
        // Notification authorization is requested in AppDelegate once the app
        // has fully launched.
    }

    var body: some Scene {
        // Menu-bar entry — the always-available control surface.
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(manager)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
                .environmentObject(manager)
                .environmentObject(settings)
        }
        .menuBarExtraStyle(.window)

        // Full management window, opened on demand.
        Window("Ntfy", id: "main") {
            MainView()
                .environmentObject(manager)
                .environmentObject(settings)
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(manager)
                .environmentObject(settings)
        }
    }
}

/// Renders the menu-bar icon, optionally badged with the unread count.
struct MenuBarLabel: View {
    @EnvironmentObject var manager: SubscriptionManager
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if settings.showMenuBarCount && manager.totalUnread > 0 {
            let count = manager.totalUnread
            Label("\(count)", systemImage: "bell.badge.fill")
        } else {
            Image(systemName: "bell.fill")
        }
    }
}

/// Controls how the app appears to the system. It normally runs as a menu-bar
/// `.accessory` (no Dock icon), but switches to a regular app while a real
/// window is open so the window behaves like any other — including getting its
/// own stage under Stage Manager and appearing in Mission Control.
enum AppActivation {
    /// Promote to a regular, front-facing app (call before opening a window).
    static func enterWindowMode() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Demote back to a menu-bar agent once no normal windows remain open.
    static func exitWindowModeIfNeeded() {
        DispatchQueue.main.async {
            let hasNormalWindow = NSApp.windows.contains { window in
                window.isVisible
                    && !(window is NSPanel)
                    && window.styleMask.contains(.titled)
                    && window.canBecomeMain
            }
            if !hasNormalWindow && NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// Keeps the app running as a single background instance and tidies up the
/// auto-opened window at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isDuplicateInstance = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicateInstance else { return }

        // Ask for notification permission once the app is fully launched (more
        // reliable than doing it during App.init).
        NotificationService.shared.requestAuthorization()

        let showWindow = (UserDefaults.standard.object(forKey: "openWindowAtLaunch") as? Bool) ?? true

        DispatchQueue.main.async {
            if showWindow {
                // Open straight into the main window as a normal, standalone
                // window (own Stage Manager stage + Dock icon).
                AppActivation.enterWindowMode()
                NSApp.windows
                    .first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })?
                    .makeKeyAndOrderFront(nil)
            } else {
                // Start as a menu-bar-only agent; close the auto-opened window.
                NSApp.setActivationPolicy(.accessory)
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true {
                    window.close()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    /// If another copy of this app is already running, hand off to it and quit,
    /// so launching the app repeatedly never spawns duplicate instances.
    private func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }

        if let existing = others.first {
            isDuplicateInstance = true
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }
    }
}
