import Foundation

/// DTO condiviso tra provider esterni, import CSV e API future (michelebigi.it).
struct ComponentRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String { lcscCode }

    let lcscCode: String
    var mpn: String
    var name: String
    var description: String
    var footprint: String
    var quantity: Int
    var category: String
    var value: String
    var brand: String
    var datasheetURL: String?
    var imageURLs: [String]
    var price: Double?
    var currency: String?
    var supplierStock: Int?
    var dataSource: DataSource
    var parameters: [String: String]
    var notes: String
    var minQuantity: Int
    var tags: [String]
    var updatedAt: String?
    var digikeyPartNumber: String?
    var supplierProductURL: String?
    var priceBreaks: [PriceBreak]
    var lcscSupplierCode: String?
    var minimumOrderQuantity: Int?
    var leadTimeWeeks: Int?
    var digikeyProductStatus: String?
    var digikeyLastFetched: String?
    var lcscSnapshot: SupplierSnapshot?
    var digikeySnapshot: SupplierSnapshot?

    enum CodingKeys: String, CodingKey {
        case lcscCode, mpn, name, description, footprint, quantity
        case category, value, brand, datasheetURL, imageURLs
        case price, currency, supplierStock, dataSource, parameters
        case notes, minQuantity, tags, updatedAt
        case digikeyPartNumber, supplierProductURL, lcscSupplierCode
        case priceBreaks, minimumOrderQuantity, leadTimeWeeks
        case digikeyProductStatus, digikeyLastFetched
        case lcscSnapshot, digikeySnapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lcscCode = try container.decode(String.self, forKey: .lcscCode)
        mpn = try container.decodeIfPresent(String.self, forKey: .mpn) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        footprint = try container.decodeIfPresent(String.self, forKey: .footprint) ?? ""
        quantity = try Self.decodeInt(from: container, forKey: .quantity) ?? 0
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        brand = try container.decodeIfPresent(String.self, forKey: .brand) ?? ""
        datasheetURL = try container.decodeIfPresent(String.self, forKey: .datasheetURL)
        imageURLs = try container.decodeIfPresent([String].self, forKey: .imageURLs) ?? []
        price = try Self.decodeDouble(from: container, forKey: .price)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        supplierStock = try Self.decodeInt(from: container, forKey: .supplierStock)
        dataSource = try container.decodeIfPresent(DataSource.self, forKey: .dataSource) ?? .manual
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        minQuantity = try Self.decodeInt(from: container, forKey: .minQuantity) ?? 0
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        digikeyPartNumber = try container.decodeIfPresent(String.self, forKey: .digikeyPartNumber)
        supplierProductURL = try container.decodeIfPresent(String.self, forKey: .supplierProductURL)
        priceBreaks = try container.decodeIfPresent([PriceBreak].self, forKey: .priceBreaks) ?? []
        lcscSupplierCode = try container.decodeIfPresent(String.self, forKey: .lcscSupplierCode)
        minimumOrderQuantity = try Self.decodeInt(from: container, forKey: .minimumOrderQuantity)
        leadTimeWeeks = try Self.decodeInt(from: container, forKey: .leadTimeWeeks)
        digikeyProductStatus = try container.decodeIfPresent(String.self, forKey: .digikeyProductStatus)
        digikeyLastFetched = try container.decodeIfPresent(String.self, forKey: .digikeyLastFetched)
        lcscSnapshot = try container.decodeIfPresent(SupplierSnapshot.self, forKey: .lcscSnapshot)
        digikeySnapshot = try container.decodeIfPresent(SupplierSnapshot.self, forKey: .digikeySnapshot)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lcscCode, forKey: .lcscCode)
        try container.encode(mpn, forKey: .mpn)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(footprint, forKey: .footprint)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(category, forKey: .category)
        try container.encode(value, forKey: .value)
        try container.encode(brand, forKey: .brand)
        try container.encodeIfPresent(datasheetURL, forKey: .datasheetURL)
        try container.encode(imageURLs, forKey: .imageURLs)
        try container.encodeIfPresent(price, forKey: .price)
        try container.encodeIfPresent(currency, forKey: .currency)
        try container.encodeIfPresent(supplierStock, forKey: .supplierStock)
        try container.encode(dataSource, forKey: .dataSource)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(notes, forKey: .notes)
        try container.encode(minQuantity, forKey: .minQuantity)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(digikeyPartNumber, forKey: .digikeyPartNumber)
        try container.encodeIfPresent(supplierProductURL, forKey: .supplierProductURL)
        try container.encode(priceBreaks, forKey: .priceBreaks)
        try container.encodeIfPresent(lcscSupplierCode, forKey: .lcscSupplierCode)
        try container.encodeIfPresent(minimumOrderQuantity, forKey: .minimumOrderQuantity)
        try container.encodeIfPresent(leadTimeWeeks, forKey: .leadTimeWeeks)
        try container.encodeIfPresent(digikeyProductStatus, forKey: .digikeyProductStatus)
        try container.encodeIfPresent(digikeyLastFetched, forKey: .digikeyLastFetched)
        try container.encodeIfPresent(lcscSnapshot, forKey: .lcscSnapshot)
        try container.encodeIfPresent(digikeySnapshot, forKey: .digikeySnapshot)
    }

    private static func decodeDouble<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(text)
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    private static func decodeInt<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(text)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    init(
        lcscCode: String,
        mpn: String = "",
        name: String = "",
        description: String = "",
        footprint: String = "",
        quantity: Int = 0,
        category: String = "",
        value: String = "",
        brand: String = "",
        datasheetURL: String? = nil,
        imageURLs: [String] = [],
        price: Double? = nil,
        currency: String? = nil,
        supplierStock: Int? = nil,
        dataSource: DataSource = .manual,
        parameters: [String: String] = [:],
        notes: String = "",
        minQuantity: Int = 0,
        tags: [String] = [],
        updatedAt: String? = nil,
        digikeyPartNumber: String? = nil,
        supplierProductURL: String? = nil,
        priceBreaks: [PriceBreak] = [],
        lcscSupplierCode: String? = nil,
        minimumOrderQuantity: Int? = nil,
        leadTimeWeeks: Int? = nil,
        digikeyProductStatus: String? = nil,
        digikeyLastFetched: String? = nil,
        lcscSnapshot: SupplierSnapshot? = nil,
        digikeySnapshot: SupplierSnapshot? = nil
    ) {
        self.lcscCode = lcscCode
        self.mpn = mpn
        self.name = name
        self.description = description
        self.footprint = footprint
        self.quantity = quantity
        self.category = category
        self.value = value
        self.brand = brand
        self.datasheetURL = datasheetURL
        self.imageURLs = imageURLs
        self.price = price
        self.currency = currency
        self.supplierStock = supplierStock
        self.dataSource = dataSource
        self.parameters = parameters
        self.notes = notes
        self.minQuantity = minQuantity
        self.tags = tags
        self.updatedAt = updatedAt
        self.digikeyPartNumber = digikeyPartNumber
        self.supplierProductURL = supplierProductURL
        self.priceBreaks = priceBreaks
        self.lcscSupplierCode = lcscSupplierCode
        self.minimumOrderQuantity = minimumOrderQuantity
        self.leadTimeWeeks = leadTimeWeeks
        self.digikeyProductStatus = digikeyProductStatus
        self.digikeyLastFetched = digikeyLastFetched
        self.lcscSnapshot = lcscSnapshot
        self.digikeySnapshot = digikeySnapshot
    }

    func withLCSCCode(_ code: String) -> ComponentRecord {
        with(inventoryCode: code, lcscSupplierCode: lcscSupplierCode)
    }

    func withSupplierLCSC(_ code: String) -> ComponentRecord {
        with(inventoryCode: lcscCode, lcscSupplierCode: code)
    }

    func with(inventoryCode: String? = nil, lcscSupplierCode: String? = nil) -> ComponentRecord {
        ComponentRecord(
            lcscCode: inventoryCode ?? lcscCode,
            mpn: mpn,
            name: name,
            description: description,
            footprint: footprint,
            quantity: quantity,
            category: category,
            value: value,
            brand: brand,
            datasheetURL: datasheetURL,
            imageURLs: imageURLs,
            price: price,
            currency: currency,
            supplierStock: supplierStock,
            dataSource: dataSource,
            parameters: parameters,
            notes: notes,
            minQuantity: minQuantity,
            tags: tags,
            updatedAt: updatedAt,
            digikeyPartNumber: digikeyPartNumber,
            supplierProductURL: supplierProductURL,
            priceBreaks: priceBreaks,
            lcscSupplierCode: lcscSupplierCode ?? self.lcscSupplierCode,
            minimumOrderQuantity: minimumOrderQuantity,
            leadTimeWeeks: leadTimeWeeks,
            digikeyProductStatus: digikeyProductStatus,
            digikeyLastFetched: digikeyLastFetched,
            lcscSnapshot: lcscSnapshot,
            digikeySnapshot: digikeySnapshot
        )
    }

    /// Separa codice inventario CV-* da codice fornitore LCSC Cxxxxx.
    func normalizedForInventory() -> ComponentRecord {
        if InternalComponentCode.isInternal(lcscCode) { return self }
        if let lcscSupplierCode, LCSCCode.isValid(lcscSupplierCode) { return self }
        guard LCSCCode.isValid(lcscCode) else { return self }
        let seed = digikeyPartNumber.flatMap { $0.isEmpty ? nil : $0 }
            ?? (mpn.isEmpty ? lcscCode : mpn)
        return with(
            inventoryCode: InternalComponentCode.make(from: seed),
            lcscSupplierCode: lcscCode
        )
    }
}
