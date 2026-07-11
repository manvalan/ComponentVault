import Foundation

struct LCSCProvider: ComponentDataProvider {
    let source: DataSource = .lcsc

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(lcscCode: String) async throws -> ComponentRecord {
        let code = lcscCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.hasPrefix("C"), code.count >= 4 else {
            throw ProviderError.invalidCode
        }

        let url = URL(string: "https://www.lcsc.com/product-detail/\(code).html")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure("Risposta non valida")
        }
        guard http.statusCode == 200 else {
            throw ProviderError.notFound(code)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.parseFailure
        }

        return try LCSCParser.parse(html: html, lcscCode: code)
    }
}

/// Placeholder per integrazione futura DigiKey OAuth2.
struct DigiKeyProvider: ComponentDataProvider {
    let source: DataSource = .digikey

    func fetch(lcscCode: String) async throws -> ComponentRecord {
        throw ProviderError.networkFailure("DigiKey non ancora implementato")
    }
}
