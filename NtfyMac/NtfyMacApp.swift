//
//  NtfyMacApp.swift
//  NtfyMac
//
//  App entry point. Runs as a menu-bar (LSUIElement) agent so it stays alive in
//  the background receiving messages, with an optional main window + settings.
//

import SwiftUI

@main
struct NtfyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings: AppSettings
    @StateObject private var manager: SubscriptionManager

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _manager = StateObject(wrappedValue: SubscriptionManager(settings: settings))
        NotificationService.shared.requestAuthorization()
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

/// Keeps the app running without a Dock icon and ensures the window can be
/// reopened from the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no Dock icon, survives the last window closing.
        NSApp.setActivationPolicy(.accessory)

        // SwiftUI auto-opens the `Window` scene at launch; for a background
        // agent we want only the menu-bar item, so close it. It can be
        // reopened on demand via `openWindow(id: "main")`.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true {
                window.close()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
