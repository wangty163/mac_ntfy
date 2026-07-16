import Foundation

@main
struct SmokeHarness {
    @MainActor
    static func main() throws {
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

        print("NtfyMac smoke tests passed")
    }
}
