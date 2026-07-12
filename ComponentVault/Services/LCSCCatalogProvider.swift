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
        }.prefix(max(1, min(limit, 15))).map { $0 }
    }

    private static func fetchGlobalSearchResult(keyword: String) async throws -> SearchResult {
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
        limit: Int
    ) async throws -> [Product] {
        let payload: [String: Any] = [
            "keyword": "",
            "globalKeyword": globalKeyword,
            "scene": scene,
            "catalogIdList": catalogIdList,
            "brandIdList": [],
            "encapValueList": encapValues,
            "paramNameValueMap": [:] as [String: [String]],
            "isStock": false,
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
            throw ProviderError.networkFailure("Chiave pubblica LCSC non trovata")
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
        let payload = Data(keyword.utf8).base64EncodedString()
        var cipherHex = try SM2.encrypt(payload, publicKey: publicKeyHex)
        if cipherHex.hasPrefix("04") {
            cipherHex = String(cipherHex.dropFirst(2))
        }
        return "{secret}04\(cipherHex)"
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
