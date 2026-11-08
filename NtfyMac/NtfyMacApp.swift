//
//  NtfyMacApp.swift
//  NtfyMac
//
//  Starts as a menu-bar agent. Management windows promote the application to
//  a regular app for Dock and Stage Manager integration; closing the last
//  window restores menu-bar-only operation.
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
                .appTextScale(settings.textScale)
        } label: {
            MenuBarLabel()
                .environmentObject(manager)
                .environmentObject(settings)
        }
        .menuBarExtraStyle(.window)

        // Full management window. Declared first so it is the app's primary
        // scene and opens at launch.
        Window("Ntfy", id: "main") {
            MainView()
                .environmentObject(manager)
                .environmentObject(settings)
                .appTextScale(settings.textScale)
                // Make sure messages can only be deleted when the
                // main window is active
                .focusedSceneValue(\.deleteSelectedMessages, {
                    NotificationCenter.default.post(
                        name: .deleteSelectedMessages,
                        object: nil
                    )
                })
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Explicit Quit so the App menu always shows "Quit Ntfy" bound to
            // ⌘Q while a window is focused. (A key monitor in AppDelegate also
            // covers the cases where SwiftUI's menu isn't active — e.g. the
            // menu-bar popover, or when no window is focused.)
            CommandGroup(replacing: .appTermination) {
                Button("Quit Ntfy") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            // Let's use the default macOS shortcut to delete messages
            DeleteSelectedMessagesCommands()
        }

        // Dedicated settings window opened from the menu-bar panel. A plain
        // `Window` (rather than the `Settings` scene) is used so the menu-bar
        // path can open it by id and then explicitly focus it.
        Window("Settings", id: "settings") {
            SettingsView(manager: manager)
                .environmentObject(settings)
                .appTextScale(settings.textScale)
        }
        .defaultSize(width: 460, height: 380)

        Settings {
            SettingsView(manager: manager)
                .environmentObject(settings)
                .appTextScale(settings.textScale)
        }
    }
}

/// Renders the menu-bar icon. A fixed bell glyph (no live text) so the status
/// item never animates or shifts; the badged variant signals unread messages.
struct MenuBarLabel: View {
    @EnvironmentObject var manager: SubscriptionManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // A dropped connection takes visual priority over pause/unread state.
        // Do not put a TimelineView in a MenuBarExtra label: on some macOS
        // versions that continuously regenerates the status-bar symbol.
        let offline = manager.hasOfflineSubscriptions
        let paused = settings.isTemporarilyPaused() || settings.isInQuietHours()
        let showBadge = settings.showMenuBarCount && manager.totalUnread > 0
        let symbol = offline
            ? "exclamationmark.triangle.fill"
            : (paused ? "bell.slash.fill" : (showBadge ? "bell.badge.fill" : "bell.fill"))
        Image(systemName: symbol)
            .symbolRenderingMode(offline ? .multicolor : .monochrome)
            .accessibilityLabel(offline
                ? "Ntfy — a subscription is offline"
                : (paused ? "Ntfy — notifications are paused" : "Ntfy"))
            .task {
                // The menu-bar label is the one view guaranteed to exist at
                // launch, so use it to (a) expose `openWindow` to non-SwiftUI
                // code (e.g. notification clicks) and (b) reliably open the main
                // window once at launch.
                MainWindow.open = { openWindow(id: "main") }

                guard settings.openWindowAtLaunch else { return }
                LaunchWindowOpener.runOnce {
                    MainWindow.show()
                }
            }
    }
}

/// Bridges window opening to non-SwiftUI code (notification clicks, the menu
/// bar) so that revealing a message can both surface the window and bring the
/// app forward, regardless of whether it's currently a menu-bar agent.
@MainActor
enum MainWindow {
    /// Registered by a SwiftUI view that owns the `openWindow` environment
    /// action. Calling it opens the "main" window scene (or focuses it if it
    /// already exists).
    static var open: (() -> Void)?

    /// Activates the app and brings the main window to the front, recreating
    /// it if it was previously closed.
    static func show() {
        AppActivation.enterWindowMode()
        if let open {
            open()
        } else if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("main") == true
        }) {
            // Fallback if the SwiftUI action hasn't been registered yet.
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Opens and foregrounds the SwiftUI `Settings` scene when launched from the
/// menu-bar extra. Accessory apps can otherwise create the settings window
/// without making it key, which leaves it looking like it opened in the
/// background.
@MainActor
enum SettingsWindow {
    static func prepareToOpen() {
        AppActivation.enterWindowMode()
        // Let SwiftUI dismiss its menu-bar popover when focus moves. Do not
        // order out arbitrary panels or borderless windows: those can also
        // belong to the persistent status item or another system UI.
    }

    static func showUsingResponderChain() {
        prepareToOpen()
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        focusSoon()
    }

    static func focusSoon(attemptsRemaining: Int = 20) {
        if focusExisting() { return }
        guard attemptsRemaining > 0 else {
            AppActivation.exitWindowModeIfNeeded()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            Task { @MainActor in
                SettingsWindow.focusSoon(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    @discardableResult
    private static func focusExisting() -> Bool {
        let candidates = NSApp.windows.filter { window in
            window.isVisible
                && !(window is NSPanel)
                && window.styleMask.contains(.titled)
                && window.canBecomeMain
        }

        guard let window = candidates.first(where: isSettingsWindow) else {
            return false
        }

        AppActivation.enterWindowMode()
        window.deminiaturize(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        let identifier = window.identifier?.rawValue.lowercased() ?? ""
        let title = window.title.lowercased()
        return identifier.contains("settings")
            || identifier.contains("preferences")
            || title.contains("settings")
            || title.contains("preferences")
    }
}

/// Ensures the launch window is opened at most once.
@MainActor
enum LaunchWindowOpener {
    private static var didRun = false
    static func runOnce(_ action: () -> Void) {
        guard !didRun else { return }
        didRun = true
        action()
    }
}

/// Uses regular application behavior while management windows are open.
enum AppActivation {
    /// Activate the app and bring windows forward.
    static func enterWindowMode() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func isManagementWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel)
            && window.styleMask.contains(.titled)
            && window.canBecomeMain
    }

    static func exitWindowModeIfNeeded() {
        // willClose arrives before the closing window leaves NSApp.windows.
        // Re-evaluate on the next turn so a newly opened window also counts.
        DispatchQueue.main.async {
            let hasOpenWindow = NSApp.windows.contains {
                isManagementWindow($0) && ($0.isVisible || $0.isMiniaturized)
            }
            if !hasOpenWindow && NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// Keeps the app running as a single background instance and tidies up the
/// auto-opened window at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isDuplicateInstance = false
    private var quitMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicateInstance else { return }

        installQuitMonitor()
        NotificationCenter.default.addObserver(
            self, selector: #selector(managementWindowBecameMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(managementWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )

        // Ask for notification permission once the app is fully launched (more
        // reliable than doing it during App.init).
        NotificationService.shared.requestAuthorization()

        let showWindow = (UserDefaults.standard.object(forKey: "openWindowAtLaunch") as? Bool) ?? true

        DispatchQueue.main.async {
            if showWindow {
                // A visible management window participates in Stage Manager.
                AppActivation.enterWindowMode()
                NSApp.windows
                    .first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })?
                    .makeKeyAndOrderFront(nil)
            } else {
                // Start as a menu-bar-only agent: close the auto-opened window.
                // Closing the auto-opened window also reconciles any mode
                // promotion caused by its initial focus event.
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true {
                    window.close()
                }
            }
        }
    }

    @objc private func managementWindowBecameMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              AppActivation.isManagementWindow(window) else { return }
        // Covers system-created windows too, including the Settings scene.
        // Do not reactivate on every focus event.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @objc private func managementWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              AppActivation.isManagementWindow(window) else { return }
        AppActivation.exitWindowModeIfNeeded()
    }

    /// Guarantees ⌘Q quits the app from anywhere the app is active — the main
    /// window, the menu-bar popover, or when no window is focused — where
    /// SwiftUI's menu key-equivalent can be momentarily unavailable.
    /// This makes ⌘Q behave like every other Mac app.
    private func installQuitMonitor() {
        quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isCommandOnly = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask) == .command
            if isCommandOnly, event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }

    /// Reopening the app (e.g. relaunching while already running) should
    /// surface the main window. AppKit's default reopen doesn't recreate a
    /// closed SwiftUI `Window` scene, so when no window is visible we open one
    /// explicitly through the `MainWindow` bridge.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in MainWindow.show() }
        }
        return true
    }

    /// Keep running as a menu-bar agent after the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
