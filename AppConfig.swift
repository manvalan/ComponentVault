import Foundation

/// Configurazione unificata ComponentVault — un solo file YAML per server, sync, percorsi, LCSC e DigiKey.
struct AppConfig: Codable, Sendable, Equatable {
    struct Server: Codable, Sendable, Equatable {
        var apiBaseURL: String = "https://cvault.michelebigi.it"
        var apiKey: String = ""
    }

    struct Sync: Codable, Sendable, Equatable {
        var autoOnLaunch: Bool = false
        var intervalMinutes: Int = 0
        var lastSyncAt: String = ""
        var lastRemoteCount: Int = -1
    }

    struct Paths: Codable, Sendable, Equatable {
        var csv: String = ""
    }

    struct LCSC: Codable, Sendable, Equatable {
        var requestDelayMs: Int = 800
    }

    struct DigiKey: Codable, Sendable, Equatable {
        var clientID: String = ""
        var clientSecret: String = ""
        var environment: DigiKeyEnvironment = .production
        var callbackURL: String = ""
        var iosCallbackURL: String = DigiKeyConfig.defaultIOSCallbackURL
        var market: String = "IT"
        var currency: String = "EUR"
        var language: String = "it"
        var requestDelayMs: Int = 800
    }

    var server: Server = Server()
    var sync: Sync = Sync()
    var paths: Paths = Paths()
    var lcsc: LCSC = LCSC()
    var digikey: DigiKey = DigiKey()

    static let fileName = "componentvault_config.yml"

    var isServerConfigured: Bool {
        !server.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !server.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isDigiKeyConfigured: Bool {
        !digikey.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !digikey.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum AppConfigError: LocalizedError {
    case invalidYAML(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidYAML(let detail): detail
        case .writeFailed(let detail): "Salvataggio fallito: \(detail)"
        }
    }
}

enum AppConfigIO {
    private static var cached: AppConfig?
    private static let legacyDigiKeyFileName = "digikey_config.yml"

    static var configFile: URL { AppPaths.appConfigFile }

    static func current() -> AppConfig {
        if let cached { return cached }
        let loaded = loadOrMigrate()
        cached = loaded
        return loaded
    }

    static func reload() -> AppConfig {
        cached = nil
        return current()
    }

    @discardableResult
    static func save(_ config: AppConfig) throws -> URL {
        try AppPaths.ensureLCSCDirectory()
        let yaml = yamlString(for: config)
        do {
            try yaml.write(to: configFile, atomically: true, encoding: .utf8)
            cached = config
            return configFile
        } catch {
            throw AppConfigError.writeFailed(error.localizedDescription)
        }
    }

    static func saveRawYAML(_ content: String) throws -> AppConfig {
        guard let config = parseYAML(content) else {
            throw AppConfigError.invalidYAML("YAML non valido.")
        }
        try AppPaths.ensureLCSCDirectory()
        try content.write(to: configFile, atomically: true, encoding: .utf8)
        cached = config
        return config
    }

    static func readRawYAML() -> String? {
        try? String(contentsOf: configFile, encoding: .utf8)
    }

    static func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: configFile.path)
    }

    static func defaultTemplate() -> AppConfig {
        var config = AppConfig()
        config.paths.csv = AppPaths.defaultCSV.path
        config.digikey = defaultDigiKeySection()
        return config
    }

    private static func defaultDigiKeySection() -> AppConfig.DigiKey {
        #if os(macOS)
        let callback = "https://localhost:8443/digikey/callback"
        #else
        let callback = "http://localhost:8139/digikey_callback"
        #endif
        return AppConfig.DigiKey(
            callbackURL: callback,
            iosCallbackURL: DigiKeyConfig.defaultIOSCallbackURL
        )
    }

    private static func loadOrMigrate() -> AppConfig {
        if let content = try? String(contentsOf: configFile, encoding: .utf8),
           let parsed = parseYAML(content) {
            return parsed
        }

        var config = defaultTemplate()
        if let legacy = loadLegacyDigiKeyYAML() {
            config.digikey = legacy
        }
        migrateUserDefaults(into: &config)
        try? save(config)
        removeLegacyDigiKeyConfig()
        return config
    }

    private static func migrateUserDefaults(into config: inout AppConfig) {
        let defaults = UserDefaults.standard
        if let url = defaults.string(forKey: "apiBaseURL"), !url.isEmpty {
            config.server.apiBaseURL = url
        }
        if let key = defaults.string(forKey: "apiKey"), !key.isEmpty {
            config.server.apiKey = key
        }
        if let csv = defaults.string(forKey: "defaultCSVPath"), !csv.isEmpty {
            config.paths.csv = csv
        }
        if defaults.object(forKey: "autoSyncOnLaunch") != nil {
            config.sync.autoOnLaunch = defaults.bool(forKey: "autoSyncOnLaunch")
        }
        if defaults.object(forKey: "autoSyncIntervalMinutes") != nil {
            config.sync.intervalMinutes = defaults.integer(forKey: "autoSyncIntervalMinutes")
        }
        if let last = defaults.string(forKey: "lastSyncAt") {
            config.sync.lastSyncAt = last
        }
        if defaults.object(forKey: "lastRemoteCount") != nil {
            config.sync.lastRemoteCount = defaults.integer(forKey: "lastRemoteCount")
        }
        if defaults.object(forKey: "lcscRequestDelayMs") != nil {
            config.lcsc.requestDelayMs = Int(defaults.double(forKey: "lcscRequestDelayMs"))
        }
        if defaults.object(forKey: "digikeyRequestDelayMs") != nil {
            config.digikey.requestDelayMs = Int(defaults.double(forKey: "digikeyRequestDelayMs"))
        }
    }

    private static func loadLegacyDigiKeyYAML() -> AppConfig.DigiKey? {
        let legacyURL = AppPaths.lcscDataRoot.appendingPathComponent(legacyDigiKeyFileName)
        guard let content = try? String(contentsOf: legacyURL, encoding: .utf8),
              let dk = DigiKeyConfig.parseYAML(content) else { return nil }
        return AppConfig.DigiKey(dk)
    }

    private static func removeLegacyDigiKeyConfig() {
        let legacyURL = AppPaths.lcscDataRoot.appendingPathComponent(legacyDigiKeyFileName)
        try? FileManager.default.removeItem(at: legacyURL)
    }

    static func yamlString(for config: AppConfig) -> String {
        let csv = config.paths.csv.isEmpty ? AppPaths.defaultCSV.path : config.paths.csv
        var lines = [
            "# ComponentVault — configurazione unificata",
            "server:",
            "  api_base_url: \(yamlQuote(config.server.apiBaseURL))",
            "  api_key: \(yamlQuote(config.server.apiKey))",
            "sync:",
            "  auto_on_launch: \(config.sync.autoOnLaunch)",
            "  interval_minutes: \(config.sync.intervalMinutes)",
            "  last_sync_at: \(yamlQuote(config.sync.lastSyncAt))",
            "  last_remote_count: \(config.sync.lastRemoteCount)",
            "paths:",
            "  csv: \(yamlQuote(csv))",
            "lcsc:",
            "  request_delay_ms: \(config.lcsc.requestDelayMs)",
            "digikey:",
            "  client_id: \(yamlQuote(config.digikey.clientID))",
            "  client_secret: \(yamlQuote(config.digikey.clientSecret))",
            "  environment: \(config.digikey.environment.rawValue)",
            "  callback_url: \(yamlQuote(config.digikey.callbackURL))",
            "  ios_callback_url: \(yamlQuote(config.digikey.iosCallbackURL))",
            "  market: \(config.digikey.market)",
            "  currency: \(config.digikey.currency)",
            "  language: \(config.digikey.language)",
            "  request_delay_ms: \(config.digikey.requestDelayMs)",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func yamlQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    static func parseYAML(_ content: String) -> AppConfig? {
        var root: [String: [String: String]] = [:]
        var section = ""

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if !line.hasPrefix(" ") && !line.hasPrefix("\t"), trimmed.hasSuffix(":"),
               trimmed.split(separator: ":").count == 1 || trimmed.dropLast().allSatisfy({ !$0.isWhitespace && $0 != ":" }) {
                section = String(trimmed.dropLast())
                root[section] = root[section] ?? [:]
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            value = unquoteYAML(value)

            if section.isEmpty {
                root[key] = [:]
            } else {
                root[section, default: [:]][key] = value
            }
        }

        func value(_ section: String, _ key: String) -> String? {
            root[section]?[key]
        }

        func intValue(_ section: String, _ key: String, default defaultValue: Int) -> Int {
            guard let raw = value(section, key), let parsed = Int(raw) else { return defaultValue }
            return parsed
        }

        func boolValue(_ section: String, _ key: String, default defaultValue: Bool) -> Bool {
            guard let raw = value(section, key)?.lowercased() else { return defaultValue }
            return raw == "true" || raw == "1" || raw == "yes"
        }

        var config = AppConfig()
        config.server.apiBaseURL = value("server", "api_base_url") ?? config.server.apiBaseURL
        config.server.apiKey = value("server", "api_key") ?? ""
        config.sync.autoOnLaunch = boolValue("sync", "auto_on_launch", default: false)
        config.sync.intervalMinutes = intValue("sync", "interval_minutes", default: 0)
        config.sync.lastSyncAt = value("sync", "last_sync_at") ?? ""
        config.sync.lastRemoteCount = intValue("sync", "last_remote_count", default: -1)
        config.paths.csv = value("paths", "csv") ?? AppPaths.defaultCSV.path
        config.lcsc.requestDelayMs = intValue("lcsc", "request_delay_ms", default: 800)

        let dk = config.digikey
        config.digikey.clientID = value("digikey", "client_id") ?? ""
        config.digikey.clientSecret = value("digikey", "client_secret") ?? ""
        if let env = value("digikey", "environment") {
            config.digikey.environment = DigiKeyEnvironment(rawValue: env.lowercased()) ?? dk.environment
        }
        config.digikey.callbackURL = value("digikey", "callback_url") ?? dk.callbackURL
        config.digikey.iosCallbackURL = value("digikey", "ios_callback_url") ?? DigiKeyConfig.defaultIOSCallbackURL
        config.digikey.market = value("digikey", "market") ?? dk.market
        config.digikey.currency = value("digikey", "currency") ?? dk.currency
        config.digikey.language = value("digikey", "language") ?? dk.language
        config.digikey.requestDelayMs = intValue("digikey", "request_delay_ms", default: 800)

        if config.digikey.callbackURL.isEmpty {
            config.digikey.callbackURL = defaultDigiKeySection().callbackURL
        }

        return config
    }

    private static func unquoteYAML(_ value: String) -> String {
        if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

extension AppConfig.DigiKey {
    init(_ config: DigiKeyConfig) {
        clientID = config.clientID
        clientSecret = config.clientSecret
        environment = config.environment
        callbackURL = config.callbackURL
        iosCallbackURL = config.iosCallbackURL ?? DigiKeyConfig.defaultIOSCallbackURL
        market = config.market
        currency = config.currency
        language = config.language
    }

    func toDigiKeyConfig() -> DigiKeyConfig {
        DigiKeyConfig(
            clientID: clientID,
            clientSecret: clientSecret,
            callbackURL: callbackURL,
            iosCallbackURL: iosCallbackURL.nilIfEmpty,
            environment: environment,
            market: market,
            currency: currency,
            language: language
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
