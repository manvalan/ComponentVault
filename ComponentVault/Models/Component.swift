import Foundation
import SwiftData

enum DataSource: String, Codable, CaseIterable, Identifiable {
    case manual
    case lcsc
    case digikey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: "Manuale"
        case .lcsc: "LCSC"
        case .digikey: "DigiKey"
        }
    }
}

@Model
final class Component {
    @Attribute(.unique) var lcscCode: String
    var mpn: String
    var name: String
    var componentDescription: String
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
    var dataSource: String
    var lastUpdated: Date
    var notes: String
    var minQuantity: Int
    var tags: [String]
    var digikeyPartNumber: String?
    var supplierProductURL: String?
    var priceBreaksJSON: String
    var minimumOrderQuantity: Int?
    var leadTimeWeeks: Int?
    var digikeyProductStatus: String?
    var digikeyLastFetched: Date?

    @Relationship(deleteRule: .cascade, inverse: \ComponentParameter.component)
    var parameters: [ComponentParameter]

    @Relationship(deleteRule: .cascade, inverse: \StockMovement.component)
    var stockMovements: [StockMovement]

    @Relationship(inverse: \ProjectItem.component)
    var projectItems: [ProjectItem]

    init(
        lcscCode: String,
        mpn: String = "",
        name: String = "",
        componentDescription: String = "",
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
        notes: String = "",
        minQuantity: Int = 0,
        tags: [String] = [],
        digikeyPartNumber: String? = nil,
        supplierProductURL: String? = nil,
        priceBreaksJSON: String = "[]",
        minimumOrderQuantity: Int? = nil,
        leadTimeWeeks: Int? = nil,
        digikeyProductStatus: String? = nil,
        digikeyLastFetched: Date? = nil,
        parameters: [ComponentParameter] = [],
        stockMovements: [StockMovement] = []
    ) {
        self.lcscCode = lcscCode
        self.mpn = mpn
        self.name = name
        self.componentDescription = componentDescription
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
        self.dataSource = dataSource.rawValue
        self.lastUpdated = Date()
        self.notes = notes
        self.minQuantity = minQuantity
        self.tags = tags
        self.digikeyPartNumber = digikeyPartNumber
        self.supplierProductURL = supplierProductURL
        self.priceBreaksJSON = priceBreaksJSON
        self.minimumOrderQuantity = minimumOrderQuantity
        self.leadTimeWeeks = leadTimeWeeks
        self.digikeyProductStatus = digikeyProductStatus
        self.digikeyLastFetched = digikeyLastFetched
        self.parameters = parameters
        self.stockMovements = stockMovements
        self.projectItems = []
    }

    var source: DataSource {
        DataSource(rawValue: dataSource) ?? .manual
    }

    var displayTitle: String {
        if !mpn.isEmpty { return mpn }
        if !name.isEmpty { return name }
        return lcscCode
    }

    /// Nome leggibile del componente (descrizione CSV/LCSC o categoria).
    var displayCommonName: String {
        let description = componentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { return description }

        if let categoryLeaf = category.split(separator: "/").last.map(String.init),
           !categoryLeaf.isEmpty {
            return categoryLeaf
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            if !brand.isEmpty, trimmedName.hasPrefix(brand) {
                return trimmedName.dropFirst(brand.count).trimmingCharacters(in: .whitespaces)
            }
            return trimmedName
        }

        return ""
    }

    var primaryImageURL: URL? {
        guard let first = imageURLs.first else { return nil }
        return URL(string: first)
    }

    var isLowStock: Bool {
        if minQuantity > 0 {
            return quantity <= minQuantity
        }
        return quantity == 0
    }

    var priceBreaks: [PriceBreak] {
        get { PriceBreakCodec.decode(priceBreaksJSON) }
        set { priceBreaksJSON = PriceBreakCodec.encode(newValue) }
    }

    var digikeyUnitPriceForInventory: Double? {
        PriceBreakCodec.unitPrice(for: max(quantity, 1), in: priceBreaks)
    }

    var categoryRoot: String {
        category.components(separatedBy: "/").first ?? category
    }

    func apply(_ record: ComponentRecord, preserveQuantity: Bool = true) {
        mpn = record.mpn
        name = record.name
        componentDescription = record.description
        footprint = record.footprint.isEmpty ? footprint : record.footprint
        category = record.category
        value = record.value
        brand = record.brand
        datasheetURL = record.datasheetURL
        imageURLs = record.imageURLs
        price = record.price
        currency = record.currency
        supplierStock = record.supplierStock
        dataSource = record.dataSource.rawValue
        notes = record.notes
        minQuantity = record.minQuantity
        tags = record.tags
        digikeyPartNumber = record.digikeyPartNumber
        supplierProductURL = record.supplierProductURL
        priceBreaks = record.priceBreaks
        minimumOrderQuantity = record.minimumOrderQuantity
        leadTimeWeeks = record.leadTimeWeeks
        digikeyProductStatus = record.digikeyProductStatus
        if let fetched = record.digikeyLastFetched {
            digikeyLastFetched = ISO8601DateFormatter().date(from: fetched) ?? Date()
        } else if record.dataSource == .digikey {
            digikeyLastFetched = Date()
        }
        lastUpdated = Date()

        if !preserveQuantity {
            quantity = record.quantity
        }

        for parameter in parameters { parameter.component = nil }
        parameters = record.parameters.map { key, value in
            ComponentParameter(name: key, value: value)
        }
    }

    func toRecord() -> ComponentRecord {
        ComponentRecord(
            lcscCode: lcscCode,
            mpn: mpn,
            name: name,
            description: componentDescription,
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
            dataSource: source,
            parameters: Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.value) }),
            notes: notes,
            minQuantity: minQuantity,
            tags: tags,
            updatedAt: ISO8601DateFormatter().string(from: lastUpdated),
            digikeyPartNumber: digikeyPartNumber,
            supplierProductURL: supplierProductURL,
            priceBreaks: priceBreaks,
            minimumOrderQuantity: minimumOrderQuantity,
            leadTimeWeeks: leadTimeWeeks,
            digikeyProductStatus: digikeyProductStatus,
            digikeyLastFetched: digikeyLastFetched.map { ISO8601DateFormatter().string(from: $0) }
        )
    }
}
