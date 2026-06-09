//
//  DesignSystem.swift
//  NtfyMac
//
//  Shared colors, gradients and reusable view modifiers that give the app its
//  polished, consistent look.
//

import SwiftUI

extension Color {
    /// Parses `#RRGGBB` / `#RRGGBBAA` (and the 3-digit shorthand) hex strings.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((value & 0xFF000000) >> 24) / 255
            g = Double((value & 0x00FF0000) >> 16) / 255
            b = Double((value & 0x0000FF00) >> 8) / 255
            a = Double(value & 0x000000FF) / 255
        default:
            return nil
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

enum Theme {
    static let cornerRadius: CGFloat = 12
    static let accentPalette: [String] = [
        "#3B82F6", "#8B5CF6", "#EC4899", "#F97316",
        "#10B981", "#14B8A6", "#EF4444", "#F59E0B",
        "#6366F1", "#06B6D4",
    ]

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "#6366F1")!, Color(hex: "#8B5CF6")!, Color(hex: "#EC4899")!],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// A soft, rounded "card" background used throughout the message list.
struct CardBackground: ViewModifier {
    var highlighted: Bool = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(highlighted ? 0.12 : 0.05),
                            radius: highlighted ? 8 : 3, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func cardBackground(highlighted: Bool = false) -> some View {
        modifier(CardBackground(highlighted: highlighted))
    }
}

/// A small rounded "chip" for tags, priorities and counts.
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(
            Capsule().fill(tint.opacity(0.14))
        )
    }
}

/// Colored dot used to indicate a subscription / connection. Static (no
/// animation): a perpetual `repeatForever` animation here caused the menu panel
/// to continuously re-animate its layout.
struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .strokeBorder(color.opacity(pulsing ? 0.35 : 0), lineWidth: 3)
                    .frame(width: 14, height: 14)
            )
    }
}

/// A shared ticking clock that periodically publishes the current time so that
/// relative-time labels across the UI can refresh in lockstep.
///
/// A single timer drives every label, which is cheaper than one timer per row
/// and—unlike `TimelineView(.periodic(from:by:))`, which can quietly stop
/// firing on macOS when a window is occluded or App Nap kicks in—reliably keeps
/// updating as long as the app's run loop is alive. The timer temporarily moves
/// to a 1s cadence only while visible labels are still in the "seconds ago"
/// window, then returns to a cheaper 30s cadence.
@MainActor
final class RelativeClock: ObservableObject {
    static let shared = RelativeClock()

    @Published private(set) var now = Date()

    private let freshMessageWindow: TimeInterval = 60
    private let freshInterval: TimeInterval = 1
    private let settledInterval: TimeInterval = 30

    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var activeDates: [UUID: Date] = [:]

    private init() {
        scheduleTimerIfNeeded()
    }

    func register(date: Date, id: UUID) {
        activeDates[id] = date
        scheduleTimerIfNeeded()
    }

    func unregister(id: UUID) {
        activeDates[id] = nil
        scheduleTimerIfNeeded()
    }

    private var desiredInterval: TimeInterval {
        let hasFreshMessage = activeDates.values.contains { date in
            now.timeIntervalSince(date) < freshMessageWindow
        }
        return hasFreshMessage ? freshInterval : settledInterval
    }

    private func scheduleTimerIfNeeded() {
        let interval = desiredInterval
        guard timerInterval != interval else { return }

        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        // Keep ticking while the user interacts with menus/scrolls.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = interval
    }

    private func tick() {
        now = Date()
        scheduleTimerIfNeeded()
    }
}

/// A relative timestamp ("2 minutes ago") that refreshes itself over time.
///
/// Note we render a plain `String`, not `Text(date, format: .relative(...))`.
/// A format-style `Text` keeps the same `date`/format identity on every render,
/// so SwiftUI diffs it as unchanged and caches the formatted output — the label
/// would freeze even though `body` re-runs. Computing the string ourselves
/// against the shared `RelativeClock`'s ticking `now` yields a value that
/// actually changes over time, so the view updates.
struct RelativeTimeText: View {
    let date: Date
    @ObservedObject private var clock = RelativeClock.shared
    @State private var clockRegistrationID = UUID()

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    var body: some View {
        Text(Self.formatter.localizedString(for: date, relativeTo: clock.now))
            .onAppear { clock.register(date: date, id: clockRegistrationID) }
            .onChange(of: date) { newDate in
                clock.register(date: newDate, id: clockRegistrationID)
            }
            .onDisappear { clock.unregister(id: clockRegistrationID) }
    }
}
