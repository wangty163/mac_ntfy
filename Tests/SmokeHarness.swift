import Foundation
import Network

@main
struct SmokeHarness {
    @MainActor
    static func main() async throws {
        let ordered = HostsMappedHTTPClient.happyEyeballsOrder([
            "2001:db8::1", "2001:db8::2", "192.0.2.1", "192.0.2.2", "192.0.2.1",
        ])
        precondition(
            ordered == ["2001:db8::1", "192.0.2.1", "2001:db8::2", "192.0.2.2"],
            "Happy Eyeballs must alternate families while preserving their order"
        )

        let suiteName = "NtfyMacSmokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.quietHoursEnabled = true
        settings.quietStartMinutes = 22 * 60
        settings.quietEndMinutes = 8 * 60

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let late = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 23))!
        let early = calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 7))!
        let daytime = calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
        precondition(settings.isInQuietHours(at: late, calendar: calendar))
        precondition(settings.isInQuietHours(at: early, calendar: calendar))
        precondition(!settings.isInQuietHours(at: daytime, calendar: calendar))

        var subscription = Subscription()
        subscription.baseURL = "https://example.com"
        subscription.topic = "backup-test"
        subscription.auth = .token("must-not-appear-in-backup")
        subscription.lastMessageID = "cursor-must-not-appear"
        let data = try ConfigurationBackupService.encode(
            subscriptions: [subscription],
            settings: settings
        )
        let text = String(decoding: data, as: UTF8.self)
        precondition(!text.contains("must-not-appear-in-backup"))
        precondition(!text.contains("cursor-must-not-appear"))
        let decoded = try ConfigurationBackupService.decode(data)
        precondition(decoded.subscriptions.count == 1)
        precondition(decoded.subscriptions[0].topic == "backup-test")

        var local = subscription
        local.displayName = "Local name"
        let merged = ConfigurationBackupService.merge(decoded.subscriptions, into: [local])
        precondition(merged.summary.updated == 1 && merged.summary.added == 0)
        precondition(merged.subscriptions[0].auth == local.auth)
        precondition(merged.subscriptions[0].lastMessageID == local.lastMessageID)

        let notification = NativeNotificationFormatter.format(
            topic: "topic",
            title: "标题",
            body: "正文"
        )
        precondition(notification.title == "标题")
        precondition(notification.body == "正文\n#topic")

        let notificationWithoutBody = NativeNotificationFormatter.format(
            topic: "topic",
            title: "标题",
            body: ""
        )
        precondition(notificationWithoutBody.title == "标题")
        precondition(notificationWithoutBody.body == "#topic")

        let notificationWithTrailingNewline = NativeNotificationFormatter.format(
            topic: "topic",
            title: "标题",
            body: "正文\n"
        )
        precondition(notificationWithTrailingNewline.body == "正文\n#topic")

        let message = try JSONDecoder().decode(
            NtfyMessage.self,
            from: Data(
                """
                {
                  "id": "notification-format",
                  "time": 1,
                  "event": "message",
                  "topic": "raw-topic",
                  "title": "标题",
                  "message": "正文",
                  "tags": ["rotating_light", "ops"]
                }
                """.utf8
            )
        )
        var notificationSubscription = Subscription()
        notificationSubscription.topic = "raw-topic"
        notificationSubscription.displayName = "topic"
        let renderedNotification = NativeNotificationFormatter.message(
            message,
            subscription: notificationSubscription
        )
        precondition(renderedNotification.title == "🚨 标题")
        precondition(renderedNotification.body == "正文\n#ops\n#topic")

        try await verifyDirectResponseStream()

        print("NtfyMac smoke tests passed")
    }

    @MainActor
    private static func verifyDirectResponseStream() async throws {
        let first = Data("first line\n".utf8)
        let second = Data("second line\n".utf8)
        let server = try OneShotHTTPServer(
            response: makeChunkedResponse(bodyParts: [first, second])
        )
        let port = try await server.start()

        let endpoint = HostsMappedHTTPClient.Endpoint(
            candidates: [.init(address: "127.0.0.1")],
            port: port,
            originalHost: "127.0.0.1",
            usesTLS: false,
            resolverSource: .literal
        )
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/test/json")!)
        request.timeoutInterval = 5

        let response = try await HostsMappedHTTPClient.openStream(
            request: request,
            endpoint: endpoint
        )
        defer { response.cancel() }

        MainActor.preconditionIsolated()
        precondition(Thread.isMainThread, "Direct response consumption must resume on the main thread")
        precondition(response.head.statusCode == 200)
        precondition(response.connectionInfo.address == "127.0.0.1")

        var body = Data()
        while let part = try await response.nextBodyChunk() {
            MainActor.preconditionIsolated()
            precondition(Thread.isMainThread, "Each direct body chunk must resume on the main thread")
            body.append(part)
        }
        precondition(body == first + second, "Direct response stream must preserve body order")
    }

    private static func makeChunkedResponse(bodyParts: [Data]) -> Data {
        var response = Data(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8
        )
        for part in bodyParts {
            response.append(Data(String(part.count, radix: 16).utf8))
            response.append(Data("\r\n".utf8))
            response.append(part)
            response.append(Data("\r\n".utf8))
        }
        response.append(Data("0\r\n\r\n".utf8))
        return response
    }
}

private final class OneShotHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.ntfymac.smoke-http-server")
    private let response: Data
    private var connection: NWConnection?
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    init(response: Data) throws {
        self.response = response
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue else { return }
                    self.finishStart(with: .success(port))
                case .failed(let error):
                    self.finishStart(with: .failure(error))
                case .cancelled:
                    self.finishStart(with: .failure(CancellationError()))
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.connection = connection
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection else { return }
                    switch state {
                    case .ready:
                        connection.send(content: self.response, completion: .contentProcessed { _ in
                            connection.cancel()
                            self.listener.cancel()
                        })
                    case .failed, .cancelled:
                        self.listener.cancel()
                    case .setup, .preparing, .waiting:
                        break
                    @unknown default:
                        break
                    }
                }
                connection.start(queue: self.queue)
            }

            listener.start(queue: queue)
        }
    }

    private func finishStart(with result: Result<UInt16, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }

    deinit {
        connection?.cancel()
        listener.cancel()
    }
}
