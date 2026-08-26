import Foundation

enum LCSCCatalogProvider {
    private static let mainURL = URL(string: "https://www.lcsc.com/")!
    private static let searchURL = URL(string: "https://wmsc.lcsc.com/ftps/wm/search/v3/global")!
    private static let productListURL = URL(string: "https://wmsc.lcsc.com/ftps/wm/product/query/list")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config)
    }()

    struct CatalogHit: Decodable {
        let lcscCode: String
        let mpn: String
        let name: String?
        let description: String?
        let footprint: String?
        let brand: String?
        let category: String?
        let price: Double?
        let currency: String?
        let supplierStock: Int?
        let productURL: String?
    }

    private struct SearchResponse: Decodable {
        let code: Int?
        let msg: String?
        let result: SearchResult?
    }

    private struct SearchResult: Decodable {
        let productSearchResultVO: ProductSearchBlock?
        let exactMatchResult: [Product]?
        let tipProductDetailUrlVO: TipProduct?
        let topResults: [TopResult]?
        let searchEngineProcess: SearchEngineProcess?
        let scene: String?
        let totalCount: Int?

        var products: [Product] {
            if let exact = exactMatchResult, !exact.isEmpty {
                return exact
            }
            if let tip = tipProductDetailUrlVO?.asProduct() {
                return [tip]
            }
            if let list = productSearchResultVO?.productList, !list.isEmpty {
                return list
            }
            return []
        }

        var isNoResult: Bool {
            scene == "NO_RESULT" || (totalCount == 0 && products.isEmpty)
        }

        var topCatalogId: Int? {
            topResults?.first?.catalogId
        }

        var normalizedGlobalKeyword: String? {
            let fromEngine = searchEngineProcess?.searchValidWord
                ?? searchEngineProcess?.preprocessedContent
            let trimmed = fromEngine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private struct TopResult: Decodable {
        let catalogId: Int?
    }

    private struct SearchEngineProcess: Decodable {
        let preprocessedContent: String?
        let searchValidWord: String?
    }

    private struct ProductListResponse: Decodable {
        let code: Int?
        let msg: String?
        let result: ProductListResult?
    }

    private struct ProductListResult: Decodable {
        let dataList: [Product]?
    }

    private struct ProductSearchBlock: Decodable {
        let productList: [Product]?
    }

    private struct TipProduct: Decodable {
        let productCode: String?
        let productModel: String?
        let brandNameEn: String?
        let catalogName: String?

        func asProduct() -> Product? {
            guard let productCode, LCSCCode.isValid(productCode) else { return nil }
            return Product(
                productCode: productCode,
                productModel: productModel,
                productNameEn: productModel,
                productIntroEn: nil,
                productDescEn: nil,
                encapStandard: nil,
                brandNameEn: brandNameEn,
                catalogName: catalogName,
                parentCatalogName: nil,
                stockNumber: nil,
                productPriceList: nil,
                productLadderPrice: nil
            )
        }
    }

    private struct Product: Decodable {
        let productCode: String?
        let productModel: String?
        let productNameEn: String?
        let productIntroEn: String?
        let productDescEn: String?
        let encapStandard: String?
        let brandNameEn: String?
        let catalogName: String?
        let parentCatalogName: String?
        let stockNumber: Int?
        let productPriceList: [PriceEntry]?
        let productLadderPrice: String?
    }

    private struct PriceEntry: Decodable {
        let usdPrice: Double?
        let currencyPrice: Double?
        let productPrice: String?

        var resolvedPrice: Double? {
            if let usdPrice { return usdPrice }
            if let currencyPrice { return currencyPrice }
            if let productPrice { return Double(productPrice) }
            return nil
        }
    }

    static func searchByMPN(_ mpn: String, limit: Int = 3) async throws -> [ComponentRecord] {
        let keyword = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return try await searchCatalog(keyword: keyword, limit: limit)
    }

    /// Cerca equivalenti LCSC per specifiche (footprint, valore, dielettrico, tensione…).
    static func searchEquivalents(
        keyword: String,
        encap: String? = nil,
        limit: Int = 12
    ) async throws -> [ComponentRecord] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let result = try await fetchGlobalSearchResult(keyword: trimmed)
        if result.isNoResult {
            return []
        }

        if !result.products.isEmpty {
            return mapProductsToRecords(result.products, limit: limit)
        }

        guard result.scene == "FULL_MATCH" || result.scene == "PARTIAL_MATCH",
              let catalogId = result.topCatalogId else {
            return []
        }

        let encapValues = encap.map { [$0] } ?? []
        let products = try await fetchProductList(
            globalKeyword: result.normalizedGlobalKeyword ?? trimmed,
            scene: result.scene ?? "FULL_MATCH",
            catalogIdList: [catalogId],
            encapValues: encapValues,
            paramNameValueMap: [:],
            inStockOnly: false,
            limit: limit
        )
        return mapProductsToRecords(products, limit: limit)
    }

    static func searchCatalog(keyword: String, limit: Int = 5) async throws -> [ComponentRecord] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let hits = try await fetchCatalogHits(keyword: trimmed, limit: limit)
        return hits.map { mapHitToRecord($0) }
    }

    /// Ricerca parametrica LCSC: tipo + valore + package → lista parti ordinate per codice C.
    static func searchParametric(
        query: CatalogSearchQuery,
        limit: Int = 25
    ) async throws -> [ComponentRecord] {
        let keyword = query.lcscKeyword()
        guard !keyword.isEmpty else { return [] }

        let result = try await fetchGlobalSearchResult(keyword: keyword)

        var products = result.products
        if products.count < limit,
           result.scene == "FULL_MATCH" || result.scene == "PARTIAL_MATCH",
           let catalogId = result.topCatalogId {
            let encap = CatalogMatchNormalizer.footprintToken(query.footprint)
            let encapValues = encap.isEmpty ? [] : [encap]
            let listed = try await fetchProductList(
                globalKeyword: result.normalizedGlobalKeyword ?? keyword,
                scene: result.scene ?? "FULL_MATCH",
                catalogIdList: [catalogId],
                encapValues: encapValues,
                paramNameValueMap: query.lcscParamMap(),
                inStockOnly: false,
                limit: limit
            )
            if !listed.isEmpty {
                products = listed
            }
        }

        var records = mapProductsToRecords(products, limit: limit)

        if records.isEmpty {
            records = try await searchCatalog(keyword: keyword, limit: limit)
        }

        if records.isEmpty {
            records = try await searchEquivalents(
                keyword: keyword,
                encap: query.footprint.isEmpty ? nil : query.footprint,
                limit: limit
            )
        }

        if query.resolvedType != .other, query.type != nil, !query.isKeywordQuery {
            let typed = records.filter { query.resolvedType.matchesLCSCCategory($0.category) }
            if !typed.isEmpty {
                records = typed
            }
        }

        records.sort { $0.lcscCode.localizedStandardCompare($1.lcscCode) == .orderedAscending }
        return Array(records.prefix(limit))
    }

    private static func fetchCatalogHits(keyword: String, limit: Int) async throws -> [CatalogHit] {
        let result = try await fetchGlobalSearchResult(keyword: keyword)
        if result.isNoResult {
            return []
        }

        return result.products.compactMap { product in
            guard let code = product.productCode, LCSCCode.isValid(code) else { return nil }
            return CatalogHit(
                lcscCode: code,
                mpn: product.productModel ?? "",
                name: product.productNameEn ?? product.productModel,
                description: product.productIntroEn ?? product.productDescEn,
                footprint: product.encapStandard,
                brand: product.brandNameEn,
                category: product.catalogName ?? product.parentCatalogName,
                price: firstPrice(product),
                currency: "USD",
                supplierStock: product.stockNumber,
                productURL: "https://www.lcsc.com/product-detail/\(code).html"
            )
        }.prefix(max(1, min(limit, 25))).map { $0 }
    }

    private static func fetchGlobalSearchResult(keyword: String) async throws -> SearchResult {
        do {
            return try await performGlobalSearch(keyword: keyword)
        } catch {
            try await Task.sleep(for: .milliseconds(600))
            return try await performGlobalSearch(keyword: keyword)
        }
    }

    private static func performGlobalSearch(keyword: String) async throws -> SearchResult {
        let publicKey = try await fetchEncryptPublicKey()
        let encryptedKeyword = try encryptKeyword(keyword, publicKeyHex: publicKey)

        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyBrowserHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(["keyword": encryptedKeyword])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure("Risposta LCSC non valida")
        }
        guard http.statusCode == 200 else {
            throw ProviderError.networkFailure("LCSC search HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        if decoded.code != 200 {
            throw ProviderError.networkFailure(decoded.msg ?? "LCSC search fallita")
        }

        return decoded.result ?? SearchResult(
            productSearchResultVO: nil,
            exactMatchResult: nil,
            tipProductDetailUrlVO: nil,
            topResults: nil,
            searchEngineProcess: nil,
            scene: "NO_RESULT",
            totalCount: 0
        )
    }

    private static func fetchProductList(
        globalKeyword: String,
        scene: String,
        catalogIdList: [Int],
        encapValues: [String],
        paramNameValueMap: [String: [String]] = [:],
        inStockOnly: Bool = false,
        limit: Int
    ) async throws -> [Product] {
        let payload: [String: Any] = [
            "keyword": "",
            "globalKeyword": globalKeyword,
            "scene": scene,
            "catalogIdList": catalogIdList,
            "brandIdList": [],
            "encapValueList": encapValues,
            "paramNameValueMap": paramNameValueMap,
            "isStock": inStockOnly,
            "currentPage": 1,
            "pageSize": max(1, min(limit, 25)),
        ]

        var request = URLRequest(url: productListURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyBrowserHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure("Risposta LCSC non valida")
        }
        guard http.statusCode == 200 else {
            throw ProviderError.networkFailure("LCSC product list HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(ProductListResponse.self, from: data)
        if decoded.code != 200 {
            throw ProviderError.networkFailure(decoded.msg ?? "LCSC product list fallita")
        }

        return decoded.result?.dataList ?? []
    }

    private static func mapProductsToRecords(_ products: [Product], limit: Int) -> [ComponentRecord] {
        products.compactMap { product in
            guard let code = product.productCode, LCSCCode.isValid(code) else { return nil }
            return ComponentRecord(
                lcscCode: code,
                mpn: product.productModel ?? "",
                name: product.productNameEn ?? product.productModel ?? code,
                description: product.productIntroEn ?? product.productDescEn ?? "",
                footprint: product.encapStandard ?? "",
                category: product.catalogName ?? product.parentCatalogName ?? "",
                brand: product.brandNameEn ?? "",
                price: firstPrice(product),
                currency: "USD",
                supplierStock: product.stockNumber,
                dataSource: .lcsc,
                supplierProductURL: "https://www.lcsc.com/product-detail/\(code).html"
            )
        }.prefix(max(1, min(limit, 25))).map { $0 }
    }

    private static func mapHitToRecord(_ hit: CatalogHit) -> ComponentRecord {
        ComponentRecord(
            lcscCode: hit.lcscCode,
            mpn: hit.mpn,
            name: hit.name ?? hit.mpn,
            description: hit.description ?? "",
            footprint: hit.footprint ?? "",
            category: hit.category ?? "",
            brand: hit.brand ?? "",
            price: hit.price,
            currency: hit.currency,
            supplierStock: hit.supplierStock,
            dataSource: .lcsc,
            supplierProductURL: hit.productURL
        )
    }

    private static func applyBrowserHeaders(to request: inout URLRequest) {
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("it-IT,it;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    }

    private static func fetchEncryptPublicKey() async throws -> String {
        var request = URLRequest(url: mainURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("it-IT,it;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.networkFailure("Impossibile caricare homepage LCSC")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.parseFailure
        }

        guard let key = parseEncryptPublicKey(from: html) else {
            throw ProviderError.networkFailure("Chiave pubblica LCSC non trovata — il sito potrebbe essere cambiato")
        }
        return key
    }

    private static func parseEncryptPublicKey(from html: String) -> String? {
        let marker = "encryptPublicHexKey:\""
        guard let start = html.range(of: marker)?.upperBound else { return nil }
        guard let end = html[start...].firstIndex(of: "\"") else { return nil }

        let raw = String(html[start..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isHexDigit }

        switch raw.count {
        case 130 where raw.hasPrefix("04"):
            return raw
        case 128:
            return "04" + raw
        default:
            return nil
        }
    }

    private static func encryptKeyword(_ keyword: String, publicKeyHex: String) throws -> String {
        let key = publicKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count == 130 || key.count == 128 else {
            throw ProviderError.parseFailure
        }

        let payload = Data(keyword.utf8).base64EncodedString()
        do {
            var cipherHex = try SM2.encrypt(payload, publicKey: key)
            if cipherHex.hasPrefix("04") {
                cipherHex = String(cipherHex.dropFirst(2))
            }
            return "{secret}04\(cipherHex)"
        } catch {
            throw ProviderError.parseFailure
        }
    }

    private static func firstPrice(_ product: Product) -> Double? {
        if let value = product.productPriceList?.first?.resolvedPrice {
            return value
        }
        guard let ladder = product.productLadderPrice, !ladder.isEmpty else { return nil }
        let first = ladder.split(separator: ",").first.map(String.init) ?? ""
        let parts = first.split(separator: "~")
        guard parts.count >= 3 else { return nil }
        return Double(parts[2])
    }
}

// MARK: - Ricerca parametrica catalogo

/// Ricerca parametrica LCSC: tipo + valore + package → MPN, footprint, produttore, stock.
enum LCSCCatalogSearchService {
    static func search(
        query: CatalogSearchQuery,
        inventory: [Component],
        limit: Int = 25
    ) async throws -> [CatalogMatchCard] {
        try await collectCards(
            query: query,
            inventory: inventory,
            limit: limit
        ) { try await LCSCCatalogProvider.searchParametric(query: query, limit: limit) }
    }

    static func searchByKeyword(
        query: CatalogSearchQuery,
        inventory: [Component],
        limit: Int = 25
    ) async throws -> [CatalogMatchCard] {
        try await collectCards(
            query: query,
            inventory: inventory,
            limit: limit
        ) {
            let keyword = query.lcscSearchKeywordText()
            var records = try await LCSCCatalogProvider.searchCatalog(keyword: keyword, limit: limit)
            if records.isEmpty {
                records = try await LCSCCatalogProvider.searchEquivalents(
                    keyword: keyword,
                    encap: query.footprint.isEmpty ? nil : query.footprint,
                    limit: limit
                )
            }
            return records
        }
    }

    private static func collectCards(
        query: CatalogSearchQuery,
        inventory: [Component],
        limit: Int,
        liveSearch: () async throws -> [ComponentRecord]
    ) async throws -> [CatalogMatchCard] {
        var entries: [(ComponentRecord, LCSCMatchSource)] = []
        var seen = Set<String>()

        func append(_ record: ComponentRecord, source: LCSCMatchSource) {
            guard LCSCCode.isValid(record.lcscCode), seen.insert(record.lcscCode).inserted else { return }
            entries.append((record, source))
        }

        for record in LCSCArchiveSearcher.search(query: query, inventory: inventory, limit: limit) {
            let source: LCSCMatchSource = inventory.contains(where: { $0.lcscCode == record.lcscCode })
                ? .inventory
                : .archive
            append(record, source: source)
        }

        for record in try await liveSearch() {
            append(record, source: .live)
        }

        entries.sort { $0.0.lcscCode.localizedStandardCompare($1.0.lcscCode) == .orderedAscending }

        let filtered = entries.filter {
            CatalogMatchNormalizer.matchesBrand(recordBrand: $0.0.brand, queryBrand: query.brand)
        }

        return filtered.prefix(limit).map { item in
            makeCard(record: item.0, query: query, source: item.1, inventory: inventory)
        }
    }

    private static func makeCard(
        record: ComponentRecord,
        query: CatalogSearchQuery,
        source: LCSCMatchSource,
        inventory: [Component]
    ) -> CatalogMatchCard {
        let type = ComponentType.from(category: record.category)
        let value = displayValue(from: record, fallback: query.value)
        let footprint = displayFootprint(from: record, fallback: query.footprint)
        let inventoryItem = inventory.first {
            $0.lcscCode == record.lcscCode
                || $0.lcscSupplierCode?.uppercased() == record.lcscCode.uppercased()
        }

        let cardID = [record.lcscCode, CatalogMatchNormalizer.mpn(record.mpn), source.rawValue]
            .joined(separator: "|")

        return CatalogMatchCard(
            id: cardID,
            type: type,
            value: value,
            footprint: footprint,
            mpn: record.mpn,
            description: record.description,
            brand: record.brand,
            lcscCode: record.lcscCode,
            lcscPrice: record.price,
            lcscCurrency: record.currency,
            lcscStock: record.supplierStock,
            lcscURL: record.supplierProductURL
                ?? "https://www.lcsc.com/product-detail/\(record.lcscCode).html",
            digikeyPartNumber: nil,
            digikeyPrice: nil,
            digikeyCurrency: nil,
            digikeyStock: nil,
            digikeyURL: nil,
            inInventory: inventoryItem != nil,
            inventoryQuantity: inventoryItem?.quantity,
            digikeyRecord: nil,
            lcscRecord: record,
            lcscSource: source
        )
    }

    private static func displayValue(from record: ComponentRecord, fallback: String) -> String {
        if !record.value.isEmpty && record.value != "N/A" { return record.value }
        for key in ["Resistance", "Capacitance", "Inductance", "Voltage - Rated"] {
            if let value = record.parameters[key], !value.isEmpty { return value }
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private static func displayFootprint(from record: ComponentRecord, fallback: String) -> String {
        if !record.footprint.isEmpty { return record.footprint }
        if let pkg = record.parameters["Package"] ?? record.parameters["Package / Case"], !pkg.isEmpty {
            return pkg
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}
