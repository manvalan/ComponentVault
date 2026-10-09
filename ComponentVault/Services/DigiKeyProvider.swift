import Foundation

/// Ricerca e prezzi DigiKey con le credenziali inserite a mano (Portachiavi).
/// Disponibile solo se l'utente ha configurato DigiKey sul proprio dispositivo.
struct DigiKeyProvider: ComponentDataProvider {
    let source: DataSource = .digikey

    private let auth: DigiKeyAuthService
    private let credentials: DigiKeyCredentials

    init(credentials: DigiKeyCredentials) {
        self.credentials = credentials
        self.auth = DigiKeyAuthService(credentials: credentials)
    }

    static func configured() -> DigiKeyProvider? {
        guard let credentials = DigiKeyKeychain.load(), credentials.isComplete else { return nil }
        return DigiKeyProvider(credentials: credentials)
    }

    func fetch(lcscCode: String) async throws -> ComponentRecord {
        throw ProviderError.networkFailure(String(localized: "DigiKey cerca per MPN, non per codice LCSC."))
    }

    func searchCandidates(
        mpn: String,
        lcscCode: String,
        recordCount: Int = 5
    ) async throws -> [DigiKeyCandidate] {
        let keyword = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { throw ProviderError.invalidCode }
        let body = try JSONSerialization.data(withJSONObject: [
            "Keywords": keyword,
            "RecordCount": max(1, min(recordCount, 25)),
        ] as [String: Any])
        let data = try await apiRequest(path: "products/v4/search/keyword", method: "POST", body: body)
        return try DigiKeyParser.parseCandidates(
            data: data,
            mpn: keyword,
            lcscCode: lcscCode,
            currency: credentials.currency
        )
    }

    /// Aggiunge scaglioni di prezzo, MOQ, lead time, stato e stock.
    func enrichRecord(_ record: ComponentRecord) async throws -> ComponentRecord {
        guard let partNumber = record.digikeyPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !partNumber.isEmpty else {
            return record
        }

        let pricing = try? DigiKeyCommercialParser.parsePricing(
            data: await apiRequest(path: "products/v4/search/\(encoded(partNumber))/pricing", method: "GET")
        )
        let details = try? DigiKeyCommercialParser.parseDetails(
            data: await apiRequest(path: "products/v4/search/\(encoded(partNumber))/productdetails", method: "GET")
        )

        var commercial = details ?? DigiKeyCommercialData(
            priceBreaks: [],
            minimumOrderQuantity: nil,
            leadTimeWeeks: nil,
            productStatus: nil,
            supplierStock: nil
        )
        if let pricing {
            commercial = DigiKeyCommercialParser.merge(commercial, pricing: pricing)
        }

        var updated = record
        updated.priceBreaks = commercial.priceBreaks
        updated.minimumOrderQuantity = commercial.minimumOrderQuantity
        updated.leadTimeWeeks = commercial.leadTimeWeeks
        updated.digikeyProductStatus = commercial.productStatus
        if let stock = commercial.supplierStock {
            updated.supplierStock = stock
        }
        let qty = max(updated.quantity, 1)
        updated.price = PriceBreakCodec.unitPrice(for: qty, in: commercial.priceBreaks)
            ?? commercial.priceBreaks.first?.unitPrice
            ?? updated.price
        updated.digikeyLastFetched = ISO8601DateFormatter().string(from: Date())
        return updated
    }

    private func apiRequest(path: String, method: String, body: Data? = nil, retried: Bool = false) async throws -> Data {
        let token = try await auth.accessToken()
        var request = URLRequest(url: URL(string: "\(credentials.apiBaseURL)/\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.clientID, forHTTPHeaderField: "X-DIGIKEY-Client-Id")
        request.setValue(credentials.language, forHTTPHeaderField: "X-DIGIKEY-Locale-Language")
        request.setValue(credentials.currency, forHTTPHeaderField: "X-DIGIKEY-Locale-Currency")
        request.setValue(credentials.market, forHTTPHeaderField: "X-DIGIKEY-Locale-Site")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure(String(localized: "Risposta DigiKey non valida"))
        }
        if http.statusCode == 401, !retried {
            try await auth.refresh()
            return try await apiRequest(path: path, method: method, body: body, retried: true)
        }
        guard http.statusCode == 200 else {
            throw ProviderError.networkFailure(String(localized: "DigiKey: errore HTTP \(http.statusCode)"))
        }
        return data
    }

    private func encoded(_ partNumber: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return partNumber.addingPercentEncoding(withAllowedCharacters: allowed) ?? partNumber
    }
}
