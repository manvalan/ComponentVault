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
        parameters: [String: String] = [:]
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
    }
}
