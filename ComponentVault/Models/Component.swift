import Foundation
import SwiftData

enum DataSource: String, Codable, CaseIterable, Identifiable {
    case manual
    case lcsc
    case digikey
    case dual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: "Manuale"
        case .lcsc: "LCSC"
        case .digikey: "DigiKey"
        case .dual: "LCSC + DigiKey"
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
    var lcscSupplierCode: String?
    var supplierProductURL: String?
    var priceBreaksJSON: String
    var minimumOrderQuantity: Int?
    var leadTimeWeeks: Int?
    var digikeyProductStatus: String?
    var digikeyLastFetched: Date?
    var lcscSnapshotJSON: String
    var digikeySnapshotJSON: String

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
        lcscSupplierCode: String? = nil,
        supplierProductURL: String? = nil,
        priceBreaksJSON: String = "[]",
        minimumOrderQuantity: Int? = nil,
        leadTimeWeeks: Int? = nil,
        digikeyProductStatus: String? = nil,
        digikeyLastFetched: Date? = nil,
        lcscSnapshotJSON: String = "",
        digikeySnapshotJSON: String = "",
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
        self.lcscSupplierCode = lcscSupplierCode
        self.supplierProductURL = supplierProductURL
        self.priceBreaksJSON = priceBreaksJSON
        self.minimumOrderQuantity = minimumOrderQuantity
        self.leadTimeWeeks = leadTimeWeeks
        self.digikeyProductStatus = digikeyProductStatus
        self.digikeyLastFetched = digikeyLastFetched
        self.lcscSnapshotJSON = lcscSnapshotJSON
        self.digikeySnapshotJSON = digikeySnapshotJSON
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
        if isToOrder { return false }
        if minQuantity > 0 {
            return quantity <= minQuantity
        }
        return quantity == 0
    }

    static let toOrderTag = "da ordinare"

    var isToOrder: Bool {
        tags.contains { $0.compare(Self.toOrderTag, options: .caseInsensitive) == .orderedSame }
    }

    var priceBreaks: [PriceBreak] {
        get { PriceBreakCodec.decode(priceBreaksJSON) }
        set { priceBreaksJSON = PriceBreakCodec.encode(newValue) }
    }

    var digikeyUnitPriceForInventory: Double? {
        digikeySnapshot?.unitPrice(for: max(quantity, 1))
            ?? PriceBreakCodec.unitPrice(for: max(quantity, 1), in: priceBreaks)
    }

    var lcscSnapshot: SupplierSnapshot? {
        get { SupplierSnapshotCodec.decode(lcscSnapshotJSON) }
        set { lcscSnapshotJSON = SupplierSnapshotCodec.encode(newValue) }
    }

    var digikeySnapshot: SupplierSnapshot? {
        get { SupplierSnapshotCodec.decode(digikeySnapshotJSON) }
        set { digikeySnapshotJSON = SupplierSnapshotCodec.encode(newValue) }
    }

    var hasLCSCSnapshot: Bool { !lcscSnapshotJSON.isEmpty }
    var hasDigiKeySnapshot: Bool { !digikeySnapshotJSON.isEmpty }

    var hasDigiKeyEnrichment: Bool {
        hasDigiKeySnapshot
            || digikeyPartNumber != nil
            || digikeyLastFetched != nil
            || (!priceBreaksJSON.isEmpty && priceBreaksJSON != "[]")
    }

    var supplierComparison: SupplierComparison? {
        guard hasLCSCSnapshot, hasDigiKeySnapshot else { return nil }
        return SupplierComparisonBuilder.compare(
            quantity: quantity,
            lcsc: lcscSnapshot,
            digikey: digikeySnapshot
        )
    }

    var categoryRoot: String {
        category.components(separatedBy: "/").first ?? category
    }

    /// Codice inventario ComponentVault (`CV-*` o legacy `Cxxxxx` non ancora migrato).
    var inventoryCode: String { lcscCode }

    /// Codice LCSC `Cxxxxx` del fornitore (EasyEDA, link LCSC).
    var supplierLCSCCode: String? {
        if let lcscSupplierCode, LCSCCode.isValid(lcscSupplierCode) {
            return lcscSupplierCode.uppercased()
        }
        if LCSCCode.isValid(lcscCode), !InternalComponentCode.isInternal(lcscCode) {
            return lcscCode.uppercased()
        }
        return LCSCCode.extract(from: lcscSnapshot?.productURL)
    }

    /// Codice LCSC `Cxxxxx` valido — necessario per EasyEDA e link fornitore.
    var hasValidLCSCCode: Bool {
        supplierLCSCCode != nil
    }

    /// Manca ancora un Cxxxxx LCSC.
    var needsLCSCCodeResolution: Bool {
        !hasValidLCSCCode
    }

    /// Codice inventario `CV-*`.
    var isInternalComponentCode: Bool {
        InternalComponentCode.isInternal(lcscCode)
    }

    /// Mostra il banner «cerca LCSC per EasyEDA».
    var needsLCSCForEasyEDA: Bool {
        !hasValidLCSCCode && !mpn.isEmpty
    }

    /// Codice LCSC per EasyEDA / copia; altrimenti codice inventario.
    var resolvedLCSCCode: String {
        supplierLCSCCode ?? lcscCode
    }

    func apply(_ record: ComponentRecord, preserveQuantity: Bool = true) {
        switch record.dataSource {
        case .lcsc:
            applyLCSC(record, preserveQuantity: preserveQuantity)
        case .digikey:
            applyDigiKey(record, preserveQuantity: preserveQuantity)
        case .dual, .manual:
            applyLCSC(record, preserveQuantity: preserveQuantity)
            if record.digikeyPartNumber != nil || !record.priceBreaks.isEmpty {
                applyDigiKey(record, preserveQuantity: preserveQuantity)
            }
        }
    }

    func applyLCSC(_ record: ComponentRecord, preserveQuantity: Bool = true) {
        applySupplierLCSC(from: record)

        mpn = record.mpn
        name = record.name
        componentDescription = record.description
        footprint = record.footprint.isEmpty ? footprint : record.footprint
        category = record.category
        value = record.value
        brand = record.brand
        datasheetURL = record.datasheetURL
        imageURLs = record.imageURLs
        notes = record.notes
        minQuantity = record.minQuantity
        tags = record.tags

        lcscSnapshot = SupplierSnapshot.fromLCSC(record: record)
        syncDigiKeyFieldsFromSnapshot()
        refreshDisplayFields()

        lastUpdated = Date()
        if !preserveQuantity {
            quantity = record.quantity
        }

        for parameter in parameters { parameter.component = nil }
        parameters = record.parameters.map { key, value in
            ComponentParameter(name: key, value: value)
        }
    }

    func applyDigiKey(_ record: ComponentRecord, preserveQuantity: Bool = true) {
        if mpn.isEmpty, !record.mpn.isEmpty { mpn = record.mpn }
        if name.isEmpty, !record.name.isEmpty { name = record.name }
        if componentDescription.isEmpty, !record.description.isEmpty {
            componentDescription = record.description
        }
        if footprint.isEmpty, !record.footprint.isEmpty { footprint = record.footprint }
        if category.isEmpty, !record.category.isEmpty { category = record.category }
        if value.isEmpty || value == "N/A", !record.value.isEmpty, record.value != "N/A" {
            value = record.value
        }
        if brand.isEmpty, !record.brand.isEmpty { brand = record.brand }
        if datasheetURL == nil { datasheetURL = record.datasheetURL }
        if imageURLs.isEmpty { imageURLs = record.imageURLs }

        digikeySnapshot = SupplierSnapshot.fromDigiKey(record: record)
        syncDigiKeyFieldsFromSnapshot()
        refreshDisplayFields()

        notes = record.notes.isEmpty ? notes : record.notes
        minQuantity = record.minQuantity
        tags = record.tags.isEmpty ? tags : record.tags
        lastUpdated = Date()

        if !preserveQuantity {
            quantity = record.quantity
        }

        if parameters.isEmpty, !record.parameters.isEmpty {
            parameters = record.parameters.map { key, value in
                ComponentParameter(name: key, value: value)
            }
        }
    }

    private func syncDigiKeyFieldsFromSnapshot() {
        guard let snapshot = digikeySnapshot else { return }
        digikeyPartNumber = snapshot.digikeyPartNumber
        supplierProductURL = snapshot.productURL
        priceBreaks = snapshot.priceBreaks
        minimumOrderQuantity = snapshot.minimumOrderQuantity
        leadTimeWeeks = snapshot.leadTimeWeeks
        digikeyProductStatus = snapshot.productStatus
        digikeyLastFetched = snapshot.fetchedDate
    }

    private func refreshDisplayFields() {
        if hasLCSCSnapshot && hasDigiKeySnapshot {
            dataSource = DataSource.dual.rawValue
        } else if hasDigiKeySnapshot {
            dataSource = DataSource.digikey.rawValue
        } else if hasLCSCSnapshot {
            dataSource = DataSource.lcsc.rawValue
        }

        if let comparison = supplierComparison {
            switch comparison.cheaper {
            case .lcsc:
                price = comparison.lcscUnitPrice
                currency = comparison.lcscCurrency
                supplierStock = lcscSnapshot?.supplierStock
            case .digikey:
                price = comparison.digikeyUnitPrice
                currency = comparison.digikeyCurrency
                supplierStock = digikeySnapshot?.supplierStock
            case nil:
                price = comparison.lcscUnitPrice ?? comparison.digikeyUnitPrice
                currency = comparison.lcscCurrency ?? comparison.digikeyCurrency
                supplierStock = lcscSnapshot?.supplierStock ?? digikeySnapshot?.supplierStock
            }
        } else if let lcsc = lcscSnapshot {
            price = lcsc.unitPrice(for: max(quantity, 1)) ?? lcsc.price
            currency = lcsc.currency
            supplierStock = lcsc.supplierStock
        } else if let digikey = digikeySnapshot {
            price = digikey.unitPrice(for: max(quantity, 1)) ?? digikey.price
            currency = digikey.currency
            supplierStock = digikey.supplierStock
        }
    }

    func migrateLegacySnapshotsIfNeeded() {
        var changed = false

        if lcscSnapshotJSON.isEmpty,
           (source == .lcsc || source == .manual),
           price != nil || supplierStock != nil {
            lcscSnapshot = SupplierSnapshot(
                price: price,
                currency: currency,
                supplierStock: supplierStock,
                productURL: "https://www.lcsc.com/product-detail/\(lcscCode).html",
                fetchedAt: ISO8601DateFormatter().string(from: lastUpdated),
                priceBreaks: [],
                minimumOrderQuantity: nil,
                leadTimeWeeks: nil,
                digikeyPartNumber: nil,
                productStatus: nil
            )
            changed = true
        }

        if digikeySnapshotJSON.isEmpty,
           digikeyPartNumber != nil || digikeyLastFetched != nil
            || (!priceBreaksJSON.isEmpty && priceBreaksJSON != "[]") {
            digikeySnapshot = SupplierSnapshot(
                price: price,
                currency: currency,
                supplierStock: supplierStock,
                productURL: supplierProductURL,
                fetchedAt: digikeyLastFetched.map { ISO8601DateFormatter().string(from: $0) },
                priceBreaks: priceBreaks,
                minimumOrderQuantity: minimumOrderQuantity,
                leadTimeWeeks: leadTimeWeeks,
                digikeyPartNumber: digikeyPartNumber,
                productStatus: digikeyProductStatus
            )
            changed = true
        }

        if changed {
            refreshDisplayFields()
        }
    }

    private func applySupplierLCSC(from record: ComponentRecord) {
        if let supplier = record.lcscSupplierCode, LCSCCode.isValid(supplier) {
            lcscSupplierCode = supplier.uppercased()
        } else if LCSCCode.isValid(record.lcscCode),
                  InternalComponentCode.isInternal(lcscCode) || lcscSupplierCode == nil {
            lcscSupplierCode = record.lcscCode.uppercased()
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
            lcscSupplierCode: lcscSupplierCode,
            minimumOrderQuantity: minimumOrderQuantity,
            leadTimeWeeks: leadTimeWeeks,
            digikeyProductStatus: digikeyProductStatus,
            digikeyLastFetched: digikeyLastFetched.map { ISO8601DateFormatter().string(from: $0) },
            lcscSnapshot: lcscSnapshot,
            digikeySnapshot: digikeySnapshot
        )
    }
}
