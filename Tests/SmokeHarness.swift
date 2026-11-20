import Foundation
import Network
import Combine

// The smoke harness does not launch the app or open any windows.
@MainActor
enum MainWindow {
    static func show() {}
}

@main
struct SmokeHarness {
    @MainActor
    static func main() async throws {
        verifyDiagnosticsStore()
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
        precondition(settings.textSizeIncrease == 0)
        precondition(settings.textScale == 1)
        settings.textSizeIncrease = 100
        precondition(settings.textScale == 2)
        precondition(AppTextStyle.body.size(scale: settings.textScale) == AppTextStyle.body.baseSize * 2)
        let reloadedSettings = AppSettings(defaults: defaults)
        precondition(reloadedSettings.textSizeIncrease == 100)
        precondition(reloadedSettings.textScale == 2)
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
        precondition(decoded.settings.textSizeIncrease == 100)

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

        let markdownMessage = try JSONDecoder().decode(
            NtfyMessage.self,
            from: Data(
                #"{"id":"markdown","time":1,"event":"message","topic":"test","content_type":"text/markdown","message":"![Logo](https://example.com/logo.jpg)\n\nHello **bold**.\n\n```\ncode\n```"}"#.utf8
            )
        )
        precondition(markdownMessage.isMarkdown)
        precondition(markdownMessage.markdownBlocks == [
            .image(alt: "Logo", url: URL(string: "https://example.com/logo.jpg")!),
            .text("Hello **bold**."),
            .code("code"),
        ], "Images, paragraphs, and fenced code must be separate render blocks")

        let issue38Sample = MarkdownBlock.parse(
            """
            ![Logo](https://evermeet.cx/wiki/images/d/d4/Logo.jpg)

            I just love Markdown and `inline code`.

            ```
            Line1: This is a multiline
            Line2: code block.
            ```

            [Link to a website](https://evermeet.cx)
            """
        )
        precondition(issue38Sample.count == 4,
                     "Issue #38 sample must produce image, paragraph, code, and link blocks")
        precondition(issue38Sample[0] == .image(
            alt: "Logo",
            url: URL(string: "https://evermeet.cx/wiki/images/d/d4/Logo.jpg")!
        ))
        precondition(issue38Sample[1] == .text("I just love Markdown and `inline code`."))
        precondition(issue38Sample[2] == .code("Line1: This is a multiline\nLine2: code block."))
        precondition(issue38Sample[3] == .text("[Link to a website](https://evermeet.cx)"))

        let codeContainingImage = MarkdownBlock.parse(
            """
            ```markdown
            ![not an image block](https://example.com/in-code.png)

            second line
            ```
            """
        )
        precondition(codeContainingImage == [
            .code("![not an image block](https://example.com/in-code.png)\n\nsecond line")
        ], "Markdown-like text inside a fence must remain code")
        precondition(MarkdownBlock.parse("before\n\n```\nunclosed") == [
            .text("before"), .code("unclosed")
        ], "An unclosed fence must retain its code contents")

        let inline = try AttributedString(
            markdown: issue38Sample[1].source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        precondition(inline.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true },
                     "Inline code styling must be preserved")
        let linked = try AttributedString(
            markdown: issue38Sample[3].source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        precondition(linked.runs.contains { $0.link == URL(string: "https://evermeet.cx")! },
                     "Link destinations must be preserved")

        let copyMessage = try JSONDecoder().decode(
            NtfyMessage.self,
            from: Data(
                #"{"id":"copy","time":1,"event":"message","topic":"test","actions":[{"id":"copy-action","action":"copy","label":"Copy","value":"example"}]}"#.utf8
            )
        )
        precondition(copyMessage.actions?.first?.action == .copy)
        precondition(copyMessage.actions?.first?.value == "example")
        precondition(copyMessage.actions?.first?.symbol == "doc.on.doc")
        precondition(EmojiMap.emoji(for: "new") == "🆕")
        precondition(EmojiMap.emoji(for: "film_strip") == "🎞️")

        await verifyMutedSubscriptionsStayIdle(settings: settings)
        try await verifyDirectResponseStream()

        print("NtfyMac smoke tests passed")
    }

    @MainActor
    private static func verifyMutedSubscriptionsStayIdle(settings: AppSettings) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NtfyMacMuteSmoke.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SubscriptionManager(
            settings: settings,
            store: PersistenceStore(directory: directory),
            monitorSystemEvents: false
        )

        // Use invalid URLs so the real connection loop runs without networking.
        var muted = Subscription()
        muted.baseURL = "https://["
        muted.topic = "mute-smoke"
        var active = Subscription()
        active.baseURL = "https://["
        active.topic = "active-smoke"
        precondition(muted.streamURL() == nil && active.streamURL() == nil)
        defer {
            manager.removeSubscription(muted.id)
            manager.removeSubscription(active.id)
        }
        manager.addSubscription(muted)
        manager.addSubscription(active)
        await waitForConnectionAttempt(manager, subscriptionID: muted.id)
        await waitForConnectionAttempt(manager, subscriptionID: active.id)

        muted.isMuted = true
        manager.updateSubscription(muted)
        precondition(manager.state(for: muted.id) == .idle)

        for _ in 0..<2 {
            // The shared entry point for network recovery and wake.
            manager.reconnectAll()
            precondition(manager.state(for: active.id) == .idle)
            await waitForConnectionAttempt(manager, subscriptionID: active.id)
            try? await Task.sleep(nanoseconds: 100_000_000)
            precondition(manager.state(for: muted.id) == .idle,
                         "Reconnect must not restart a previously connected muted topic")
        }

        muted.isMuted = false
        manager.updateSubscription(muted)
        await waitForConnectionAttempt(manager, subscriptionID: muted.id)
    }

    @MainActor
    private static func waitForConnectionAttempt(
        _ manager: SubscriptionManager, subscriptionID: UUID
    ) async {
        for _ in 0..<200 {
            if manager.state(for: subscriptionID) != .idle { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Active subscription did not attempt to connect")
    }

    @MainActor
    private static func verifyDiagnosticsStore() {
        let store = ConnectionDiagnosticsStore()
        let first = UUID()
        let second = UUID()
        store.reset(subscriptionIDs: [first, second])
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        var details = ConnectionDiagnostics()
        details.state = .connected
        details.remoteAddress = "192.0.2.1"
        for tick in 1...1_000 {
            details.lastKeepaliveAt = Date(timeIntervalSince1970: Double(tick))
            store.update(details, for: first)
        }
        precondition(publications == 1_000, "Live diagnostics must still publish every changed keepalive")
        precondition(store.value(for: first) == details)
        precondition(store.value(for: second) == ConnectionDiagnostics(),
                     "Updates must not overwrite another topic's diagnostics")

        store.update(details, for: first)
        store.remove(UUID())
        precondition(publications == 1_000, "Identical values and absent removals must not invalidate views")
        store.remove(first)
        precondition(store.values[first] == nil)
        precondition(store.value(for: first) == ConnectionDiagnostics())

        store.update(details, for: second)
        store.reset(subscriptionIDs: [first])
        precondition(Set(store.values.keys) == [first], "Import/reset must discard removed topics")
        precondition(store.value(for: first) == ConnectionDiagnostics())
        let beforeReset = publications
        store.reset(subscriptionIDs: [first])
        precondition(publications == beforeReset, "An unchanged reset must not invalidate views")
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

private extension MarkdownBlock {
    var source: String {
        switch self {
        case let .text(source), let .code(source): return source
        case .image: return ""
        }
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
