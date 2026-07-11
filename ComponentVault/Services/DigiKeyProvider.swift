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

    func searchCandidates(
        mpn: String,
        lcscCode: String,
        recordCount: Int = 5
    ) async throws -> [DigiKeyCandidate] {
        let data = try await searchRequest(mpn: mpn, recordCount: recordCount)
        return try DigiKeyParser.parseCandidates(
            data: data,
            mpn: mpn,
            lcscCode: lcscCode,
            currency: config.currency
        )
    }

    func fetchByMPN(_ mpn: String, lcscCode: String) async throws -> ComponentRecord {
        let candidates = try await searchCandidates(mpn: mpn, lcscCode: lcscCode, recordCount: 1)
        return candidates[0].record
    }

    func enrichRecord(_ record: ComponentRecord) async throws -> ComponentRecord {
        guard let partNumber = record.digikeyPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !partNumber.isEmpty else {
            return record
        }

        let pricingResult = try? await fetchPricing(partNumber: partNumber)
        let detailsResult = try? await fetchDetails(partNumber: partNumber)

        var updated = record
        var commercial = detailsResult ?? DigiKeyCommercialData(
            priceBreaks: [],
            minimumOrderQuantity: nil,
            leadTimeWeeks: nil,
            productStatus: nil,
            supplierStock: nil
        )

        if let pricing = pricingResult {
            commercial = DigiKeyCommercialParser.merge(commercial, pricing: pricing)
        }

        updated.priceBreaks = commercial.priceBreaks
        updated.minimumOrderQuantity = commercial.minimumOrderQuantity
        updated.leadTimeWeeks = commercial.leadTimeWeeks
        updated.digikeyProductStatus = commercial.productStatus
        if let stock = commercial.supplierStock {
            updated.supplierStock = stock
        }

        let qty = max(updated.quantity, 1)
        if let tiered = PriceBreakCodec.unitPrice(for: qty, in: commercial.priceBreaks) {
            updated.price = tiered
        } else if let first = commercial.priceBreaks.first?.unitPrice {
            updated.price = first
        }

        updated.digikeyLastFetched = ISO8601DateFormatter().string(from: Date())
        return updated
    }

    private func fetchPricing(partNumber: String) async throws -> [PriceBreak] {
        let data = try await apiRequest(
            path: "products/v4/search/\(encodedPartNumber(partNumber))/pricing",
            method: "GET"
        )
        return try DigiKeyCommercialParser.parsePricing(data: data)
    }

    private func fetchDetails(partNumber: String) async throws -> DigiKeyCommercialData {
        let data = try await apiRequest(
            path: "products/v4/search/\(encodedPartNumber(partNumber))/productdetails",
            method: "GET"
        )
        return try DigiKeyCommercialParser.parseDetails(data: data)
    }

    private func searchRequest(mpn: String, recordCount: Int) async throws -> Data {
        let keyword = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { throw ProviderError.invalidCode }

        let body: [String: Any] = [
            "Keywords": keyword,
            "RecordCount": max(1, min(recordCount, 10)),
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        return try await apiRequest(
            path: "products/v4/search/keyword",
            method: "POST",
            body: bodyData
        )
    }

    private func apiRequest(path: String, method: String, body: Data? = nil) async throws -> Data {
        let token = try await auth.accessToken()
        let url = URL(string: "\(config.apiBaseURL)/\(path)")!

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.clientID, forHTTPHeaderField: "X-DIGIKEY-Client-Id")
        request.setValue(config.language, forHTTPHeaderField: "X-DIGIKEY-Locale-Language")
        request.setValue(config.currency, forHTTPHeaderField: "X-DIGIKEY-Locale-Currency")
        request.setValue(config.market, forHTTPHeaderField: "X-DIGIKEY-Locale-Site")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure("Risposta DigiKey non valida")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ProviderError.networkFailure(detail)
        }
        return data
    }

    private func encodedPartNumber(_ partNumber: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return partNumber.addingPercentEncoding(withAllowedCharacters: allowed) ?? partNumber
    }
}
