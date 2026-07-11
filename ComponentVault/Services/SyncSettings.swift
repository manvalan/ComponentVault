import Foundation

enum SyncSettings {
    static let apiBaseURLKey = "apiBaseURL"
    static let apiKeyKey = "apiKey"
    static let autoSyncOnLaunchKey = "autoSyncOnLaunch"
    static let autoSyncIntervalMinutesKey = "autoSyncIntervalMinutes"
    static let lastSyncAtKey = "lastSyncAt"
    static let lastRemoteCountKey = "lastRemoteCount"

    static var autoSyncOnLaunch: Bool {
        UserDefaults.standard.bool(forKey: autoSyncOnLaunchKey)
    }

    static var autoSyncIntervalMinutes: Int {
        UserDefaults.standard.integer(forKey: autoSyncIntervalMinutesKey)
    }

    static var isConfigured: Bool {
        let url = UserDefaults.standard.string(forKey: apiBaseURLKey) ?? ""
        let key = UserDefaults.standard.string(forKey: apiKeyKey) ?? ""
        return !url.trimmingCharacters(in: .whitespaces).isEmpty
            && !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func remoteConfig() throws -> RemoteAPIConfig {
        try RemoteAPIConfig.from(
            baseURLString: UserDefaults.standard.string(forKey: apiBaseURLKey) ?? "",
            apiKey: UserDefaults.standard.string(forKey: apiKeyKey) ?? ""
        )
    }

    static func markSyncSuccess(remoteCount: Int, message: String) {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        UserDefaults.standard.set(formatter.string(from: Date()), forKey: lastSyncAtKey)
        UserDefaults.standard.set(remoteCount, forKey: lastRemoteCountKey)
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
