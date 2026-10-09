import Foundation

/// Offerta di un distributore autorizzato (API ufficiale con chiave dell'utente):
/// prezzi a scaglioni e disponibilità al momento della richiesta. Non viene salvata.
struct SupplierOffer: Identifiable, Sendable {
    let id = UUID()
    let supplier: String
    let supplierPartNumber: String
    let mpn: String
    let manufacturer: String
    let description: String
    let stock: Int?
    let leadTime: String?
    let lifecycle: String?
    let minimumOrder: Int?
    let priceBreaks: [PriceBreak]
    let currency: String?
    let productURL: URL?
    let datasheetURL: URL?
    let imageURL: URL?
    /// Aggregatore da cui arriva l'offerta (es. "Nexar"), nil se dal distributore.
    var source: String? = nil

    func unitPrice(for quantity: Int) -> Double? {
        PriceBreakCodec.unitPrice(for: max(quantity, 1), in: priceBreaks)
    }
}

// MARK: - Mouser

/// Chiave Search API di Mouser, inserita dall'utente e tenuta nel Portachiavi.
enum MouserKeychain {
    private static let account = "mouser"

    static var apiKey: String? {
        SupplierKeychain.load(String.self, account: account)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    static var isConfigured: Bool { apiKey != nil }

    static func save(_ key: String) throws {
        try SupplierKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
    }

    static func delete() {
        SupplierKeychain.delete(account: account)
    }
}

/// Mouser Search API (api.mouser.com), documentata e gratuita con chiave personale.
struct MouserProvider: Sendable {
    private let apiKey: String
    private static let baseURL = "https://api.mouser.com/api/v1/search"

    static func configured() -> MouserProvider? {
        MouserKeychain.apiKey.map(MouserProvider.init(apiKey:))
    }

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func searchPartNumber(_ mpn: String) async throws -> [SupplierOffer] {
        let body: [String: Any] = [
            "SearchByPartRequest": ["mouserPartNumber": mpn, "partSearchOptions": "Exact"],
        ]
        return try await request(path: "partnumber", body: body)
    }

    func searchKeyword(_ keyword: String, records: Int = 20) async throws -> [SupplierOffer] {
        let body: [String: Any] = [
            "SearchByKeywordRequest": [
                "keyword": keyword,
                "records": max(1, min(records, 50)),
                "startingRecord": 0,
                "searchOptions": "",
                "searchWithYourSignUpLanguage": "",
            ],
        ]
        return try await request(path: "keyword", body: body)
    }

    private func request(path: String, body: [String: Any]) async throws -> [SupplierOffer] {
        var components = URLComponents(string: "\(Self.baseURL)/\(path)")!
        components.queryItems = [URLQueryItem(name: "apiKey", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure(String(localized: "Risposta Mouser non valida"))
        }
        guard http.statusCode == 200 else {
            throw ProviderError.networkFailure(String(localized: "Mouser: errore HTTP \(http.statusCode)"))
        }
        let decoded = try JSONDecoder().decode(MouserResponse.self, from: data)
        if let message = decoded.Errors?.compactMap(\.Message).first, !message.isEmpty {
            throw ProviderError.networkFailure("Mouser: \(message)")
        }
        return (decoded.SearchResults?.Parts ?? []).map(\.offer)
    }
}

// Formato della risposta Mouser (campi tutti facoltativi).
// swiftlint:disable identifier_name
private struct MouserResponse: Decodable {
    struct ErrorItem: Decodable { let Message: String? }
    struct Results: Decodable { let Parts: [MouserPart]? }
    let Errors: [ErrorItem]?
    let SearchResults: Results?
}

private struct MouserPart: Decodable {
    struct Price: Decodable {
        let Quantity: Int?
        let Price: String?
        let Currency: String?
    }

    let MouserPartNumber: String?
    let ManufacturerPartNumber: String?
    let Manufacturer: String?
    let Description: String?
    let Availability: String?
    let AvailabilityInStock: String?
    let LeadTime: String?
    let LifecycleStatus: String?
    let Min: String?
    let PriceBreaks: [Price]?
    let ProductDetailUrl: String?
    let DataSheetUrl: String?
    let ImagePath: String?

    var offer: SupplierOffer {
        let breaks = (PriceBreaks ?? []).compactMap { item -> PriceBreak? in
            guard let qty = item.Quantity, let price = MouserPrice.parse(item.Price) else { return nil }
            return PriceBreak(quantity: qty, unitPrice: price)
        }
        let stock = AvailabilityInStock.flatMap { Int($0) }
            ?? Availability.flatMap { Int($0.prefix { $0.isNumber }) }
        return SupplierOffer(
            supplier: "Mouser",
            supplierPartNumber: MouserPartNumber ?? "",
            mpn: ManufacturerPartNumber ?? "",
            manufacturer: Manufacturer ?? "",
            description: Description ?? "",
            stock: stock,
            leadTime: LeadTime.flatMap { $0.isEmpty ? nil : $0 },
            lifecycle: LifecycleStatus.flatMap { $0.isEmpty ? nil : $0 },
            minimumOrder: Min.flatMap { Int($0) },
            priceBreaks: breaks,
            currency: PriceBreaks?.first?.Currency,
            productURL: ProductDetailUrl.flatMap(URL.init(string:)),
            datasheetURL: DataSheetUrl.flatMap(URL.init(string:)),
            imageURL: ImagePath.flatMap(URL.init(string:))
        )
    }
}
// swiftlint:enable identifier_name

/// Prezzi Mouser localizzati ("0,123 €", "$1,234.50") → Double.
enum MouserPrice {
    static func parse(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        var digits = raw.filter { $0.isNumber || $0 == "," || $0 == "." }
        guard !digits.isEmpty else { return nil }
        let lastComma = digits.lastIndex(of: ",")
        let lastDot = digits.lastIndex(of: ".")
        // Il separatore che compare per ultimo è quello dei decimali.
        if let lastComma, lastDot == nil || lastComma > lastDot! {
            digits = digits.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else {
            digits = digits.replacingOccurrences(of: ",", with: "")
        }
        return Double(digits)
    }
}

// MARK: - Fornitori configurati

/// Interroga i distributori per cui l'utente ha inserito le credenziali.
enum SupplierOfferService {
    struct Outcome: Sendable {
        var offers: [SupplierOffer] = []
        var errors: [String] = []
    }

    static var configuredSuppliers: [String] {
        var names: [String] = []
        if MouserKeychain.isConfigured { names.append("Mouser") }
        if DigiKeyKeychain.isConfigured { names.append("DigiKey") }
        if NexarKeychain.isConfigured { names.append("Nexar") }
        return names
    }

    static var isAnyConfigured: Bool { !configuredSuppliers.isEmpty }

    /// Offerte per un MPN esatto da tutti i fornitori configurati.
    static func offers(forMPN mpn: String, only: String? = nil) async -> Outcome {
        await collect(
            only: only,
            mouser: { try await $0.searchPartNumber(mpn) },
            digikey: { try await $0.searchCandidates(mpn: mpn, lcscCode: InternalComponentCode.catalogSearchPlaceholder) },
            nexar: { try await $0.searchMPN(mpn) }
        )
    }

    /// Ricerca per parola chiave (catalogo) sui fornitori configurati (o solo su `only`).
    static func search(keyword: String, only: String? = nil) async -> Outcome {
        await collect(
            only: only,
            mouser: { try await $0.searchKeyword(keyword) },
            digikey: { try await $0.searchCandidates(mpn: keyword, lcscCode: InternalComponentCode.catalogSearchPlaceholder, recordCount: 20) },
            nexar: { try await $0.searchKeyword(keyword) }
        )
    }

    private static func collect(
        only: String? = nil,
        mouser mouserSearch: @escaping @Sendable (MouserProvider) async throws -> [SupplierOffer],
        digikey digikeySearch: @escaping @Sendable (DigiKeyProvider) async throws -> [DigiKeyCandidate],
        nexar nexarSearch: @escaping @Sendable (NexarProvider) async throws -> [SupplierOffer]
    ) async -> Outcome {
        @Sendable func wanted(_ name: String) -> Bool { only == nil || only == name }

        async let mouserResult: Result<[SupplierOffer], Error>? = {
            guard wanted("Mouser"), let provider = MouserProvider.configured() else { return nil }
            do { return .success(try await mouserSearch(provider)) } catch { return .failure(error) }
        }()
        async let digikeyResult: Result<[SupplierOffer], Error>? = {
            guard wanted("DigiKey"), let provider = DigiKeyProvider.configured() else { return nil }
            do { return .success(try await digikeySearch(provider).map(\.offer)) } catch { return .failure(error) }
        }()
        async let nexarResult: Result<[SupplierOffer], Error>? = {
            guard wanted("Nexar"), let provider = NexarProvider.configured() else { return nil }
            do { return .success(try await nexarSearch(provider)) } catch { return .failure(error) }
        }()

        var outcome = Outcome()
        let results = [("Mouser", await mouserResult), ("DigiKey", await digikeyResult), ("Nexar", await nexarResult)]
        for (name, result) in results {
            switch result {
            case .success(let offers): outcome.offers += offers
            case .failure(let error): outcome.errors.append("\(name): \(error.localizedDescription)")
            case nil: break
            }
        }
        return outcome
    }
}

extension DigiKeyCandidate {
    var offer: SupplierOffer {
        SupplierOffer(
            supplier: "DigiKey",
            supplierPartNumber: digikeyPartNumber,
            mpn: mpn,
            manufacturer: manufacturer,
            description: description,
            stock: stock,
            leadTime: record.leadTimeWeeks.map { String(localized: "\($0) settimane") },
            lifecycle: record.digikeyProductStatus,
            minimumOrder: record.minimumOrderQuantity,
            priceBreaks: record.priceBreaks.isEmpty
                ? unitPrice.map { [PriceBreak(quantity: 1, unitPrice: $0)] } ?? []
                : record.priceBreaks,
            currency: currency,
            productURL: productURL.flatMap(URL.init(string:)),
            datasheetURL: record.datasheetURL.flatMap(URL.init(string:)),
            imageURL: record.imageURLs.first.flatMap(URL.init(string:))
        )
    }
}
