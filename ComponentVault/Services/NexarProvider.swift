import Foundation

/// Credenziali Nexar (Octopart) inserite dall'utente: restano nel Portachiavi.
/// L'access token (client credentials) viene richiesto e rinnovato da solo.
struct NexarCredentials: Codable, Sendable, Equatable {
    var clientID = ""
    var clientSecret = ""
    var country = "IT"
    var currency = "EUR"
    var accessToken = ""
    var expiresAt: Date?

    var isComplete: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum NexarKeychain {
    private static let account = "nexar"

    static func load() -> NexarCredentials? {
        SupplierKeychain.load(NexarCredentials.self, account: account)
    }

    static func save(_ credentials: NexarCredentials) throws {
        try SupplierKeychain.save(credentials, account: account)
    }

    static func delete() {
        SupplierKeychain.delete(account: account)
    }

    static var isConfigured: Bool { load()?.isComplete ?? false }
}

/// Nexar Supply API (api.nexar.com, GraphQL): prezzi e stock di molti distributori
/// autorizzati in una sola richiesta.
actor NexarProvider {
    private static let tokenURL = URL(string: "https://identity.nexar.com/connect/token")!
    private static let apiURL = URL(string: "https://api.nexar.com/graphql")!

    private var credentials: NexarCredentials

    static func configured() -> NexarProvider? {
        guard let credentials = NexarKeychain.load(), credentials.isComplete else { return nil }
        return NexarProvider(credentials: credentials)
    }

    init(credentials: NexarCredentials) {
        self.credentials = credentials
    }

    func searchMPN(_ mpn: String, limit: Int = 3) async throws -> [SupplierOffer] {
        try await search(field: "supSearchMpn", query: mpn, limit: limit)
    }

    func searchKeyword(_ keyword: String, limit: Int = 10) async throws -> [SupplierOffer] {
        try await search(field: "supSearch", query: keyword, limit: limit)
    }

    private func search(field: String, query: String, limit: Int) async throws -> [SupplierOffer] {
        let graphQL = """
        query Search($q: String!, $limit: Int!, $country: String!, $currency: String!) {
          \(field)(q: $q, limit: $limit, country: $country, currency: $currency) {
            results {
              part {
                mpn
                manufacturer { name }
                shortDescription
                bestDatasheet { url }
                sellers(authorizedOnly: true) {
                  company { name }
                  offers {
                    sku
                    inventoryLevel
                    moq
                    clickUrl
                    prices { quantity price currency }
                  }
                }
              }
            }
          }
        }
        """
        let body: [String: Any] = [
            "query": graphQL,
            "variables": [
                "q": query,
                "limit": max(1, min(limit, 20)),
                "country": credentials.country,
                "currency": credentials.currency,
            ],
        ]
        let data = try await post(body: try JSONSerialization.data(withJSONObject: body))
        let decoded = try JSONDecoder().decode(NexarResponse.self, from: data)
        if let message = decoded.errors?.compactMap(\.message).first {
            throw ProviderError.networkFailure("Nexar: \(message)")
        }
        let results = decoded.data?.supSearchMpn?.results ?? decoded.data?.supSearch?.results ?? []
        return results.compactMap(\.part).flatMap(\.offers)
    }

    private func post(body: Data, retried: Bool = false) async throws -> Data {
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure(String(localized: "Risposta Nexar non valida"))
        }
        if http.statusCode == 401, !retried {
            credentials.accessToken = ""
            return try await post(body: body, retried: true)
        }
        guard http.statusCode == 200 else {
            throw ProviderError.networkFailure(String(localized: "Nexar: errore HTTP \(http.statusCode)"))
        }
        return data
    }

    private func accessToken() async throws -> String {
        if !credentials.accessToken.isEmpty, let expiresAt = credentials.expiresAt, Date() < expiresAt.addingTimeInterval(-120) {
            return credentials.accessToken
        }
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.networkFailure(String(localized: "Nexar ha rifiutato client ID o secret."))
        }
        struct Token: Decodable {
            let access_token: String  // swiftlint:disable:this identifier_name
            let expires_in: Int?      // swiftlint:disable:this identifier_name
        }
        let token = try JSONDecoder().decode(Token.self, from: data)
        credentials.accessToken = token.access_token
        credentials.expiresAt = Date().addingTimeInterval(Double(token.expires_in ?? 3600))
        try? NexarKeychain.save(credentials)
        return token.access_token
    }
}

// Formato della risposta GraphQL (campi facoltativi).
private struct NexarResponse: Decodable {
    struct ErrorItem: Decodable { let message: String? }
    struct SearchResult: Decodable { let results: [Result]? }
    struct Result: Decodable { let part: Part? }
    struct DataField: Decodable {
        let supSearchMpn: SearchResult?
        let supSearch: SearchResult?
    }

    let data: DataField?
    let errors: [ErrorItem]?
}

private struct Part: Decodable {
    struct Name: Decodable { let name: String? }
    struct Datasheet: Decodable { let url: String? }
    struct Seller: Decodable {
        let company: Name?
        let offers: [Offer]?
    }
    struct Offer: Decodable {
        struct Price: Decodable {
            let quantity: Int?
            let price: Double?
            let currency: String?
        }
        let sku: String?
        let inventoryLevel: Int?
        let moq: Int?
        let clickUrl: String?
        let prices: [Price]?
    }

    let mpn: String?
    let manufacturer: Name?
    let shortDescription: String?
    let bestDatasheet: Datasheet?
    let sellers: [Seller]?

    var offers: [SupplierOffer] {
        (sellers ?? []).flatMap { seller in
            (seller.offers ?? []).map { offer in
                let breaks = (offer.prices ?? []).compactMap { price -> PriceBreak? in
                    guard let qty = price.quantity, let value = price.price else { return nil }
                    return PriceBreak(quantity: qty, unitPrice: value)
                }
                return SupplierOffer(
                    supplier: seller.company?.name ?? "Nexar",
                    supplierPartNumber: offer.sku ?? "",
                    mpn: mpn ?? "",
                    manufacturer: manufacturer?.name ?? "",
                    description: shortDescription ?? "",
                    stock: offer.inventoryLevel.flatMap { $0 >= 0 ? $0 : nil },
                    leadTime: nil,
                    lifecycle: nil,
                    minimumOrder: offer.moq,
                    priceBreaks: breaks,
                    currency: offer.prices?.first?.currency,
                    productURL: offer.clickUrl.flatMap(URL.init(string:)),
                    datasheetURL: bestDatasheet?.url.flatMap(URL.init(string:)),
                    imageURL: nil,
                    source: "Nexar"
                )
            }
        }
    }
}
