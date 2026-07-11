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

    @Relationship(deleteRule: .cascade, inverse: \ComponentParameter.component)
    var parameters: [ComponentParameter]

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
        parameters: [ComponentParameter] = []
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
        self.parameters = parameters
    }

    var source: DataSource {
        DataSource(rawValue: dataSource) ?? .manual
    }

    var displayTitle: String {
        if !mpn.isEmpty { return mpn }
        if !name.isEmpty { return name }
        return lcscCode
    }

    var primaryImageURL: URL? {
        guard let first = imageURLs.first else { return nil }
        return URL(string: first)
    }

    func apply(_ record: ComponentRecord) {
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
        lastUpdated = Date()

        for parameter in parameters { parameter.component = nil }
        parameters = record.parameters.map { key, value in
            ComponentParameter(name: key, value: value)
        }
    }
}
