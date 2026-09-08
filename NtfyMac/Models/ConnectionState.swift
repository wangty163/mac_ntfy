//
//  ConnectionState.swift
//  NtfyMac
//

import SwiftUI
import Foundation
import Combine

/// Connection telemetry changes on every keepalive. Publish it separately from
/// subscriptions/messages so hidden windows do not rebuild for diagnostic ticks.
@MainActor
final class ConnectionDiagnosticsStore: ObservableObject {
    @Published private(set) var values: [UUID: ConnectionDiagnostics] = [:]

    func value(for id: UUID) -> ConnectionDiagnostics {
        values[id] ?? ConnectionDiagnostics()
    }

    func update(_ details: ConnectionDiagnostics, for id: UUID) {
        guard values[id] != details else { return }
        values[id] = details
    }

    func remove(_ id: UUID) {
        guard values[id] != nil else { return }
        values[id] = nil
    }

    func reset(subscriptionIDs: [UUID]) {
        let next = Dictionary(uniqueKeysWithValues: subscriptionIDs.map {
            ($0, ConnectionDiagnostics())
        })
        guard values != next else { return }
        values = next
    }
}

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

/// Runtime-only connection details surfaced by the tiny status indicator in the
/// subscriptions sidebar. Nothing here contains credentials or message bodies.
struct ConnectionDiagnostics: Equatable {
    var state: ConnectionState = .idle
    var route = "Not connected"
    var resolverSource = "—"
    var resolvedAddresses: [String] = []
    var remoteAddress: String?
    var addressFamily: String?
    var tlsServerName: String?
    var connectionLatencyMilliseconds: Int?
    var connectedAt: Date?
    var lastEventAt: Date?
    var lastKeepaliveAt: Date?
    var lastMessageAt: Date?
    var lastError: String?
    var retryCount = 0
    var nextRetryAt: Date?

    func report(subscription: Subscription) -> String {
        let formatter = ISO8601DateFormatter()
        func timestamp(_ value: Date?) -> String {
            value.map(formatter.string(from:)) ?? "—"
        }

        return [
            "NtfyMac connection diagnostics",
            "Subscription: \(subscription.name)",
            "Server: \(subscription.normalizedBaseURL)",
            "Topic: \(subscription.topic)",
            "State: \(state.label)",
            "Route: \(route)",
            "Resolver: \(resolverSource)",
            "Candidates: \(resolvedAddresses.isEmpty ? "—" : resolvedAddresses.joined(separator: ", "))",
            "Remote: \(remoteAddress ?? "—")",
            "Address family: \(addressFamily ?? "—")",
            "TLS SNI: \(tlsServerName ?? "—")",
            "Connect latency: \(connectionLatencyMilliseconds.map { "\($0) ms" } ?? "—")",
            "Connected at: \(timestamp(connectedAt))",
            "Last event: \(timestamp(lastEventAt))",
            "Last keepalive: \(timestamp(lastKeepaliveAt))",
            "Last message: \(timestamp(lastMessageAt))",
            "Retries: \(retryCount)",
            "Next retry: \(timestamp(nextRetryAt))",
            "Last error: \(lastError ?? "—")",
        ].joined(separator: "\n")
    }
}
