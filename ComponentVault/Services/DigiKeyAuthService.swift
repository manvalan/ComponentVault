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

    var isConfigured: Bool {
        FileManager.default.fileExists(atPath: cachePath)
    }

    func accessToken() async throws -> String {
        if let cached = loadCache(), Date().timeIntervalSince1970 < cached.expiresAt - 60 {
            return cached.accessToken
        }

        if let cached = loadCache(), let refresh = cached.refreshToken {
            let token = try await refreshToken(refresh)
            return token.accessToken
        }

        throw ProviderError.networkFailure(
            "Token DigiKey assente. Esegui: python3 Tools/digikey_auth.py"
        )
    }

    var authorizationURL: URL {
        var components = URLComponents(string: "https://api.digikey.com/v1/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.callbackURL),
        ]
        return components.url!
    }

    private func refreshToken(_ refreshToken: String) async throws -> TokenResponse {
        let token = try await tokenRequest(body: [
            "refresh_token": refreshToken,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "grant_type": "refresh_token",
        ])
        saveCache(token)
        return token
    }

    private func tokenRequest(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://api.digikey.com/v1/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

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

    private func saveCache(_ token: TokenResponse) {
        let cached = CachedToken(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().timeIntervalSince1970 + Double(token.expiresIn)
        )
        try? JSONEncoder().encode(cached).write(to: URL(fileURLWithPath: cachePath))
    }
}
