import Foundation

enum DigiKeyEnvironment: String, Codable, Sendable {
    case production
    case sandbox

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

    static var defaultPath: String { AppPaths.digiKeyConfigPath }

    /// Default bridge HTTPS per iPad — registrare nel portale DigiKey (non accetta custom scheme).
    static let defaultIOSCallbackURL = "https://cvault.michelebigi.it/oauth/digikey/callback"

    var apiBaseURL: String { environment.apiBaseURL }

    /// Redirect URI HTTPS da registrare nel portale DigiKey per login iPad.
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

    /// Server locale se callback ha porta esplicita (http o https). Solo macOS.
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
        let resolved = path ?? defaultPath
        guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else { return nil }
        return parseYAML(content)
    }

    private static func parseYAML(_ content: String) -> DigiKeyConfig? {
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
