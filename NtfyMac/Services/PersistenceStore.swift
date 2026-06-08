//
//  PersistenceStore.swift
//  NtfyMac
//
//  Lightweight JSON persistence for subscriptions and message history under
//  ~/Library/Application Support/NtfyMac/.
//

import Foundation

final class PersistenceStore {
    static let shared = PersistenceStore()

    private let directory: URL
    private let subscriptionsURL: URL
    private let messagesURL: URL
    private let queue = DispatchQueue(label: "com.ntfymac.persistence", qos: .utility)

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("NtfyMac", isDirectory: true)
        subscriptionsURL = directory.appendingPathComponent("subscriptions.json")
        messagesURL = directory.appendingPathComponent("messages.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Subscriptions

    func loadSubscriptions() -> [Subscription] {
        guard let data = try? Data(contentsOf: subscriptionsURL) else { return [] }
        return (try? decoder.decode([Subscription].self, from: data)) ?? []
    }

    func saveSubscriptions(_ subs: [Subscription]) {
        write(subs, to: subscriptionsURL)
    }

    // MARK: Messages

    func loadMessages() -> [StoredMessage] {
        guard let data = try? Data(contentsOf: messagesURL) else { return [] }
        return (try? decoder.decode([StoredMessage].self, from: data)) ?? []
    }

    func saveMessages(_ messages: [StoredMessage]) {
        write(messages, to: messagesURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        queue.async { [encoder] in
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
