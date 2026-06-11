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
    static let settingsControlTint = Color(hex: "#3B82F6")!
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

/// Shared absolute date/time formatting for message timestamps. Keep every
/// visible date that includes calendar and time components in the same
/// `yyyy-MM-dd HH:mm:ss` shape, e.g. `2024-02-01 12:00:00`.
enum AppDateFormat {
    private static let fullTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func fullTimestamp(_ date: Date) -> String {
        fullTimestampFormatter.string(from: date)
    }
}

/// An absolute timestamp label used instead of relative intervals so message
/// rows and quick previews show the actual message time.
struct TimestampText: View {
    let date: Date

    var body: some View {
        Text(AppDateFormat.fullTimestamp(date))
    }
}
