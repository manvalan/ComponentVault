import Foundation

struct DigiKeyConfig: Codable, Sendable {
    var clientID: String
    var clientSecret: String
    var callbackURL: String
    var market: String
    var currency: String
    var language: String

    static let defaultPath = "/Users/michelebigi/LCSC/digikey_config.yml"

    static func load(from path: String = defaultPath) -> DigiKeyConfig? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parseYAML(content)
    }

    private static func parseYAML(_ content: String) -> DigiKeyConfig? {
        var values: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }

        guard let clientID = values["client_id"], !clientID.isEmpty,
              let clientSecret = values["client_secret"], !clientSecret.isEmpty else {
            return nil
        }

        return DigiKeyConfig(
            clientID: clientID,
            clientSecret: clientSecret,
            callbackURL: values["callback_url"] ?? "http://localhost:8139/digikey_callback",
            market: values["market"] ?? "IT",
            currency: values["currency"] ?? "EUR",
            language: values["language"] ?? "it"
        )
    }
}
