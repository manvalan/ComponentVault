import Foundation

actor DigiKeyAuthService {
    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    struct CachedToken: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
        }
    }

    private let config: DigiKeyConfig
    private let session: URLSession
    private let cachePath: String

    init(config: DigiKeyConfig, cachePath: String = "/Users/michelebigi/LCSC/digikey_token_cache.json") {
        self.config = config
        self.session = URLSession.shared
        self.cachePath = cachePath
    }

    var isAuthenticated: Bool {
        loadCache() != nil
    }

    var tokenExpiryDescription: String? {
        guard let cached = loadCache() else { return nil }
        let date = Date(timeIntervalSince1970: cached.expiresAt)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func accessToken() async throws -> String {
        if let cached = loadCache(), Date().timeIntervalSince1970 < cached.expiresAt - 60 {
            return cached.accessToken
        }

        if let cached = loadCache(), let refresh = cached.refreshToken {
            let token = try await refreshAccessToken(refresh)
            return token.accessToken
        }

        throw ProviderError.networkFailure(
            "Token DigiKey assente. Autenticati da Impostazioni → DigiKey."
        )
    }

    var authorizationURL: URL {
        var components = URLComponents(string: "\(config.apiBaseURL)/v1/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.callbackURL),
        ]
        return components.url!
    }

    static func parseAuthorizationCode(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return code
        }

        if trimmed.contains("code=") {
            let query = trimmed.contains("?") ? String(trimmed.split(separator: "?", maxSplits: 1).last ?? "") : trimmed
            for part in query.split(separator: "&") {
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2, pair[0] == "code" {
                    return String(pair[1])
                }
            }
        }

        if !trimmed.contains("/") && !trimmed.contains(" ") && trimmed.count >= 4 {
            return trimmed
        }

        return nil
    }

    func authenticate(withRedirectURL urlString: String) async throws {
        guard let code = Self.parseAuthorizationCode(from: urlString) else {
            throw ProviderError.networkFailure(
                "Codice non trovato. Copia l'URL dalla barra indirizzi (es. http://localhost:8000/?code=…)."
            )
        }
        try await exchangeAuthorizationCode(code)
    }

    func exchangeAuthorizationCode(_ code: String) async throws {
        let token = try await tokenRequest(body: [
            "code": code,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "redirect_uri": config.callbackURL,
            "grant_type": "authorization_code",
        ])
        try saveCache(token)
    }

    func forceRefresh() async throws {
        guard let cached = loadCache(), let refresh = cached.refreshToken else {
            throw ProviderError.networkFailure("Nessun refresh token. Ripeti il login DigiKey.")
        }
        _ = try await refreshAccessToken(refresh)
    }

    @discardableResult
    private func refreshAccessToken(_ refreshToken: String) async throws -> TokenResponse {
        let token = try await tokenRequest(body: [
            "refresh_token": refreshToken,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "grant_type": "refresh_token",
        ])
        try saveCache(token)
        return token
    }

    private func tokenRequest(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "\(config.apiBaseURL)/v1/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw ProviderError.networkFailure("DigiKey auth: \(detail)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func loadCache() -> CachedToken? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)) else { return nil }
        return try? JSONDecoder().decode(CachedToken.self, from: data)
    }

    private func saveCache(_ token: TokenResponse) throws {
        let preservedRefresh = token.refreshToken ?? loadCache()?.refreshToken
        let cached = CachedToken(
            accessToken: token.accessToken,
            refreshToken: preservedRefresh,
            expiresAt: Date().timeIntervalSince1970 + Double(token.expiresIn)
        )
        let data = try JSONEncoder().encode(cached)
        let url = URL(fileURLWithPath: cachePath)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProviderError.networkFailure("Impossibile salvare token in \(cachePath): \(error.localizedDescription)")
        }
    }
}
