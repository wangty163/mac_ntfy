//
//  ConnectionState.swift
//  NtfyMac
//

import SwiftUI

/// The live state of a single topic connection.
enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting(nextAttempt: Date?)
    case disconnected(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Offline"
        }
    }

    /// Like `label`, but carries the failure reason so the user can see *why*
    /// a topic is offline (e.g. "Offline · Server returned HTTP 502").
    var detailedLabel: String {
        if case let .disconnected(reason) = self, !reason.isEmpty {
            return "Offline · \(reason)"
        }
        return label
    }

    var symbol: String {
        switch self {
        case .idle: return "pause.circle"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .connected: return "dot.radiowaves.left.and.right"
        case .disconnected: return "wifi.slash"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .red
        case .idle: return .secondary
        }
    }
}
