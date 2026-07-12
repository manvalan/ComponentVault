import Foundation

enum DigiKeyEnvironment: String, Codable, Sendable, CaseIterable, Identifiable {
    case production
    case sandbox

    var id: String { rawValue }

    var apiBaseURL: String {
        switch self {
        case .production: "https://api.digikey.com"
        case .sandbox: "https://sandbox-api.digikey.com"
        }
    }

    var label: String {
        switch self {
        case .production: "Production"
        case .sandbox: "Sandbox"
        }
    }
}

struct DigiKeyConfig: Codable, Sendable {
    var clientID: String
    var clientSecret: String
    var callbackURL: String
    var iosCallbackURL: String?
    var environment: DigiKeyEnvironment
    var market: String
    var currency: String
    var language: String

    static var defaultPath: String { AppPaths.appConfigFile.path }

    static let defaultIOSCallbackURL = "https://cvault.michelebigi.it/oauth/digikey/callback"

    var apiBaseURL: String { environment.apiBaseURL }

    var iosOAuthRedirectURI: String {
        let custom = iosCallbackURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty, custom.lowercased().hasPrefix("https://") {
            return custom
        }
        if callbackURL.lowercased().hasPrefix("https://"),
           !callbackURL.lowercased().contains("localhost"),
           !callbackURL.lowercased().contains("127.0.0.1") {
            return callbackURL
        }
        return Self.defaultIOSCallbackURL
    }

    var supportsLocalCallbackServer: Bool {
        #if os(macOS)
        guard let url = URL(string: callbackURL), url.port != nil else { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
        #else
        false
        #endif
    }

    static func load(from path: String? = nil) -> DigiKeyConfig? {
        if path != nil {
            guard let content = try? String(contentsOfFile: path!, encoding: .utf8),
                  let section = DigiKeyConfig.parseYAML(content) else { return nil }
            return section
        }
        let app = AppConfigIO.current()
        guard app.isDigiKeyConfigured else { return nil }
        return app.digikey.toDigiKeyConfig()
    }
}

enum DigiKeyConfigFileError: LocalizedError {
    case missingClientCredentials
    case invalidYAML(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientCredentials:
            "Servono client_id e client_secret."
        case .invalidYAML(let detail):
            detail
        case .writeFailed(let detail):
            "Salvataggio fallito: \(detail)"
        }
    }
}

extension DigiKeyConfig {
    static func defaultTemplate() -> DigiKeyConfig {
        AppConfigIO.defaultTemplate().digikey.toDigiKeyConfig()
    }

    static func loadOrTemplate() -> DigiKeyConfig {
        load() ?? defaultTemplate()
    }

    static func readRawYAML() -> String? {
        AppConfigIO.readRawYAML()
    }

    static func fileExists() -> Bool {
        AppConfigIO.fileExists() && AppConfigIO.current().isDigiKeyConfigured
    }

    @discardableResult
    static func save(_ config: DigiKeyConfig) throws -> URL {
        var app = AppConfigIO.current()
        app.digikey = AppConfig.DigiKey(config)
        return try AppConfigIO.save(app)
    }

    static func saveRawYAML(_ content: String) throws -> DigiKeyConfig {
        let app = try AppConfigIO.saveRawYAML(content)
        guard app.isDigiKeyConfigured else {
            throw DigiKeyConfigFileError.missingClientCredentials
        }
        return app.digikey.toDigiKeyConfig()
    }

    static var digiKeyConfigFile: URL { AppConfigIO.configFile }

    func yamlString() -> String {
        AppConfigIO.yamlString(for: AppConfigIO.current())
    }

    static func parseYAML(_ content: String) -> DigiKeyConfig? {
        var values: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }

        guard let clientID = values["client_id"], !clientID.isEmpty,
              let clientSecret = values["client_secret"], !clientSecret.isEmpty else {
            return nil
        }

        let environment = DigiKeyEnvironment(rawValue: values["environment"]?.lowercased() ?? "production")
            ?? .production

        return DigiKeyConfig(
            clientID: clientID,
            clientSecret: clientSecret,
            callbackURL: values["callback_url"] ?? "http://localhost:8139/digikey_callback",
            iosCallbackURL: values["ios_callback_url"],
            environment: environment,
            market: values["market"] ?? "IT",
            currency: values["currency"] ?? "EUR",
            language: values["language"] ?? "it"
        )
    }
}
