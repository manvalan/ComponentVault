import Foundation

enum SyncSettings {
    static var autoSyncOnLaunch: Bool {
        AppConfigIO.current().sync.autoOnLaunch
    }

    static var autoSyncIntervalMinutes: Int {
        AppConfigIO.current().sync.intervalMinutes
    }

    static var isConfigured: Bool {
        AppConfigIO.current().isServerConfigured
    }

    static func remoteConfig() throws -> RemoteAPIConfig {
        let server = AppConfigIO.current().server
        return try RemoteAPIConfig.from(
            baseURLString: server.apiBaseURL,
            apiKey: server.apiKey
        )
    }

    static func markSyncSuccess(remoteCount: Int, message: String) {
        var config = AppConfigIO.current()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        config.sync.lastSyncAt = formatter.string(from: Date())
        config.sync.lastRemoteCount = remoteCount
        try? AppConfigIO.save(config)
    }
}

struct SyncBidirectionalResult: Sendable {
    let pushed: Int
    let pulled: Int
    let unchanged: Int

    var summary: String {
        "Sync: ↑\(pushed) ↓\(pulled) =\(unchanged)"
    }
}

enum SyncDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String?) -> Date {
        guard let value, !value.isEmpty else { return .distantPast }
        return fractional.date(from: value)
            ?? standard.date(from: value)
            ?? .distantPast
    }
}
