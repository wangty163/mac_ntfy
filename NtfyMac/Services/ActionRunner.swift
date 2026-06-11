//
//  ActionRunner.swift
//  NtfyMac
//
//  Executes the action buttons attached to ntfy messages. `view` opens a URL;
//  `http` performs a network request; `broadcast` is Android-only and reported
//  as unsupported on macOS.
//

import Foundation
import AppKit

enum ActionResult: Equatable {
    case opened
    case httpSucceeded(Int)
    case httpFailed(String)
    case unsupported(String)
}

@MainActor
enum ActionRunner {
    static func run(_ action: NtfyAction) async -> ActionResult {
        switch action.action {
        case .view:
            guard let urlString = action.url, let url = URL(string: urlString) else {
                return .httpFailed("Invalid URL")
            }
            NSWorkspace.shared.open(url)
            return .opened

        case .http:
            return await runHTTP(action)

        case .broadcast:
            return .unsupported("Broadcast actions are only supported on Android.")

        case .unknown:
            return .unsupported("Unknown action type.")
        }
    }

    private static func runHTTP(_ action: NtfyAction) async -> ActionResult {
        guard let urlString = action.url, let url = URL(string: urlString) else {
            return .httpFailed("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = (action.method ?? "POST").uppercased()
        action.headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body = action.body { request.httpBody = Data(body.utf8) }

        do {
            let session = NtfyURLSessionFactory.makeDataSession()
            defer { session.invalidateAndCancel() }

            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                return .httpSucceeded(code)
            }
            return .httpFailed("HTTP \(code)")
        } catch {
            return .httpFailed(error.localizedDescription)
        }
    }
}
