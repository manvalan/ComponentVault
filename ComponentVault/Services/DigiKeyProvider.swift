import Foundation

struct DigiKeyProvider: ComponentDataProvider {
    let source: DataSource = .digikey

    private let auth: DigiKeyAuthService
    private let config: DigiKeyConfig
    private let session: URLSession

    init(config: DigiKeyConfig) {
        self.config = config
        self.auth = DigiKeyAuthService(config: config)
        self.session = URLSession.shared
    }

    static func configured() -> DigiKeyProvider? {
        guard let config = DigiKeyConfig.load() else { return nil }
        return DigiKeyProvider(config: config)
    }

    func fetch(lcscCode: String) async throws -> ComponentRecord {
        throw ProviderError.networkFailure("DigiKey cerca per MPN, non per codice LCSC.")
    }

    func fetchByMPN(_ mpn: String, lcscCode: String) async throws -> ComponentRecord {
        let keyword = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { throw ProviderError.invalidCode }

        let token = try await auth.accessToken()

        var request = URLRequest(url: URL(string: "https://api.digikey.com/products/v4/search/keyword")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.clientID, forHTTPHeaderField: "X-DIGIKEY-Client-Id")
        request.setValue(config.language, forHTTPHeaderField: "X-DIGIKEY-Locale-Language")
        request.setValue(config.currency, forHTTPHeaderField: "X-DIGIKEY-Locale-Currency")
        request.setValue(config.market, forHTTPHeaderField: "X-DIGIKEY-Locale-Site")

        let body: [String: Any] = ["Keywords": keyword, "RecordCount": 1]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure("Risposta DigiKey non valida")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ProviderError.networkFailure(detail)
        }

        return try DigiKeyParser.parse(
            data: data,
            mpn: keyword,
            lcscCode: lcscCode,
            currency: config.currency
        )
    }
}
