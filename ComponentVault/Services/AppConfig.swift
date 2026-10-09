import Foundation

/// Configurazione ComponentVault: un solo file YAML, nella cartella dell'app
/// (quella condivisa tra i dispositivi, se scelta) o altrimenti sul dispositivo.
struct AppConfig: Codable, Sendable, Equatable {
    /// Scambio dati con gli altri dispositivi tramite la cartella.
    struct Sync: Codable, Sendable, Equatable {
        var autoOnLaunch: Bool = false
        var intervalMinutes: Int = 0
        var lastSyncAt: String = ""
    }

    struct Paths: Codable, Sendable, Equatable {
        var csv: String = ""
    }

    struct LCSC: Codable, Sendable, Equatable {
        var requestDelayMs: Int = 800
    }

    struct Catalog: Codable, Sendable, Equatable {
        var searchProvider: CatalogSearchProvider = .lcsc
    }

    /// Libreria KiCad dell'utente. Si imposta dal Mac che ha KiCad; gli altri
    /// dispositivi la leggono dal file di configurazione nella cartella.
    struct KiCad: Codable, Sendable, Equatable {
        var libraryPath: String = ""

        /// Nome della libreria: l'ultima parte del percorso.
        var libraryName: String {
            let trimmed = libraryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : (trimmed as NSString).lastPathComponent
        }
    }

    var sync: Sync = Sync()
    var paths: Paths = Paths()
    var lcsc: LCSC = LCSC()
    var catalog: Catalog = Catalog()
    var kicad: KiCad = KiCad()

    static let fileName = "componentvault_config.yml"
}

enum AppConfigError: LocalizedError {
    case invalidYAML(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidYAML(let detail): detail
        case .writeFailed(let detail): String(localized: "Salvataggio fallito: \(detail)")
        }
    }
}

enum AppConfigIO {
    nonisolated(unsafe) private static var cached: AppConfig?

    static var configFile: URL { AppPaths.appConfigFile }

    static func current() -> AppConfig {
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    static func reload() -> AppConfig {
        cached = nil
        return current()
    }

    @discardableResult
    static func save(_ config: AppConfig) throws -> URL {
        try AppPaths.ensureLocalDirectory()
        do {
            try CoordinatedFile.write(Data(yamlString(for: config).utf8), to: configFile)
            cached = config
            return configFile
        } catch {
            throw AppConfigError.writeFailed(error.localizedDescription)
        }
    }

    static func fileExists() -> Bool {
        CoordinatedFile.exists(configFile)
    }

    /// Dopo aver scelto (o scollegato) la cartella: se lì c'è già una
    /// configurazione la si usa, altrimenti vi si copia quella attuale.
    @discardableResult
    static func adoptFolder(carrying previous: AppConfig) throws -> Bool {
        cached = nil
        if let existing = read(configFile) {
            cached = existing
            return true
        }
        try save(previous)
        return false
    }

    /// Le versioni precedenti tenevano client secret e token DigiKey in chiaro nel
    /// file di configurazione e in `digikey_token_cache.json`. Ora le credenziali
    /// stanno solo nel Portachiavi: i vecchi file vengono ripuliti all'avvio.
    static func removeLegacySecrets() {
        try? FileManager.default.removeItem(at: AppPaths.localRoot.appendingPathComponent("digikey_token_cache.json"))
        for url in [AppPaths.localConfigFile, AppPaths.appConfigFile] {
            guard let data = try? CoordinatedFile.read(url),
                  let content = String(data: data, encoding: .utf8),
                  content.contains("client_secret") || content.contains("api_key"),
                  let parsed = parseYAML(content) else { continue }
            try? CoordinatedFile.write(Data(yamlString(for: parsed).utf8), to: url)
        }
    }

    private static func load() -> AppConfig {
        if let parsed = read(configFile) { return parsed }
        var config = AppConfig()
        config.paths.csv = AppPaths.defaultCSV.path
        return config
    }

    private static func read(_ url: URL) -> AppConfig? {
        guard CoordinatedFile.exists(url),
              let data = try? CoordinatedFile.read(url),
              let content = String(data: data, encoding: .utf8) else { return nil }
        return parseYAML(content)
    }

    static func yamlString(for config: AppConfig) -> String {
        let csv = config.paths.csv.isEmpty ? AppPaths.defaultCSV.path : config.paths.csv
        let lines = [
            "# ComponentVault — configurazione",
            "kicad:",
            "  library_path: \(yamlQuote(config.kicad.libraryPath))",
            "sync:",
            "  auto_on_launch: \(config.sync.autoOnLaunch)",
            "  interval_minutes: \(config.sync.intervalMinutes)",
            "  last_sync_at: \(yamlQuote(config.sync.lastSyncAt))",
            "paths:",
            "  csv: \(yamlQuote(csv))",
            "lcsc:",
            "  request_delay_ms: \(config.lcsc.requestDelayMs)",
            "catalog:",
            "  search_provider: \(config.catalog.searchProvider.rawValue)",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func yamlQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func parseYAML(_ content: String) -> AppConfig? {
        var root: [String: [String: String]] = [:]
        var section = ""

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if !line.hasPrefix(" ") && !line.hasPrefix("\t"), trimmed.hasSuffix(":") {
                section = String(trimmed.dropLast())
                root[section] = root[section] ?? [:]
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !value.hasPrefix("'"), !value.hasPrefix("\""), let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            root[section, default: [:]][key] = unquoteYAML(value)
        }

        func value(_ section: String, _ key: String) -> String? {
            root[section]?[key]
        }

        func intValue(_ section: String, _ key: String, default defaultValue: Int) -> Int {
            value(section, key).flatMap(Int.init) ?? defaultValue
        }

        func boolValue(_ section: String, _ key: String) -> Bool {
            guard let raw = value(section, key)?.lowercased() else { return false }
            return raw == "true" || raw == "1" || raw == "yes"
        }

        var config = AppConfig()
        config.kicad.libraryPath = value("kicad", "library_path") ?? ""
        config.sync.autoOnLaunch = boolValue("sync", "auto_on_launch")
        config.sync.intervalMinutes = intValue("sync", "interval_minutes", default: 0)
        config.sync.lastSyncAt = value("sync", "last_sync_at") ?? ""
        config.paths.csv = value("paths", "csv") ?? AppPaths.defaultCSV.path
        config.lcsc.requestDelayMs = intValue("lcsc", "request_delay_ms", default: 800)
        if let raw = value("catalog", "search_provider"),
           let provider = CatalogSearchProvider(rawValue: raw.lowercased()) {
            config.catalog.searchProvider = provider
        }
        return config
    }

    private static func unquoteYAML(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
