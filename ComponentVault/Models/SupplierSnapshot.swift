import Foundation

struct SupplierSnapshot: Codable, Hashable, Sendable {
    var price: Double?
    var currency: String?
    var supplierStock: Int?
    var productURL: String?
    var fetchedAt: String?
    var priceBreaks: [PriceBreak]
    var minimumOrderQuantity: Int?
    var leadTimeWeeks: Int?
    var digikeyPartNumber: String?
    var productStatus: String?

    init(
        price: Double? = nil,
        currency: String? = nil,
        supplierStock: Int? = nil,
        productURL: String? = nil,
        fetchedAt: String? = nil,
        priceBreaks: [PriceBreak] = [],
        minimumOrderQuantity: Int? = nil,
        leadTimeWeeks: Int? = nil,
        digikeyPartNumber: String? = nil,
        productStatus: String? = nil
    ) {
        self.price = price
        self.currency = currency
        self.supplierStock = supplierStock
        self.productURL = productURL
        self.fetchedAt = fetchedAt
        self.priceBreaks = priceBreaks
        self.minimumOrderQuantity = minimumOrderQuantity
        self.leadTimeWeeks = leadTimeWeeks
        self.digikeyPartNumber = digikeyPartNumber
        self.productStatus = productStatus
    }

    static func fromLCSC(record: ComponentRecord) -> SupplierSnapshot {
        SupplierSnapshot(
            price: record.price,
            currency: record.currency,
            supplierStock: record.supplierStock,
            productURL: record.supplierProductURL
                ?? "https://www.lcsc.com/product-detail/\(record.lcscCode).html",
            fetchedAt: record.updatedAt ?? ISO8601DateFormatter().string(from: Date()),
            priceBreaks: [],
            minimumOrderQuantity: nil,
            leadTimeWeeks: nil,
            digikeyPartNumber: nil,
            productStatus: nil
        )
    }

    static func fromDigiKey(record: ComponentRecord) -> SupplierSnapshot {
        SupplierSnapshot(
            price: record.price,
            currency: record.currency,
            supplierStock: record.supplierStock,
            productURL: record.supplierProductURL,
            fetchedAt: record.digikeyLastFetched ?? ISO8601DateFormatter().string(from: Date()),
            priceBreaks: record.priceBreaks,
            minimumOrderQuantity: record.minimumOrderQuantity,
            leadTimeWeeks: record.leadTimeWeeks,
            digikeyPartNumber: record.digikeyPartNumber,
            productStatus: record.digikeyProductStatus
        )
    }

    func unitPrice(for quantity: Int) -> Double? {
        if !priceBreaks.isEmpty {
            return PriceBreakCodec.unitPrice(for: quantity, in: priceBreaks)
        }
        return price
    }

    var fetchedDate: Date? {
        guard let fetchedAt else { return nil }
        return ISO8601DateFormatter().date(from: fetchedAt)
    }
}

enum SupplierSnapshotCodec {
    static func encode(_ snapshot: SupplierSnapshot?) -> String {
        guard let snapshot else { return "" }
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    static func decode(_ json: String) -> SupplierSnapshot? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(SupplierSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }
}

enum SupplierChoice: String, Sendable {
    case lcsc
    case digikey
}

struct SupplierComparison: Sendable {
    let quantity: Int
    let lcscUnitPrice: Double?
    let digikeyUnitPrice: Double?
    let lcscCurrency: String?
    let digikeyCurrency: String?
    let cheaper: SupplierChoice?
    let savingsPercent: Double?
    let summary: String
}

enum SupplierComparisonBuilder {
    static func compare(
        quantity: Int,
        lcsc: SupplierSnapshot?,
        digikey: SupplierSnapshot?
    ) -> SupplierComparison? {
        guard let lcsc, let digikey else { return nil }

        let qty = max(quantity, 1)
        let lcscPrice = lcsc.unitPrice(for: qty)
        let digikeyPrice = digikey.unitPrice(for: qty)

        guard lcscPrice != nil || digikeyPrice != nil else { return nil }

        var cheaper: SupplierChoice?
        var savings: Double?

        if let lcscPrice, let digikeyPrice, lcscPrice > 0 {
            if lcscPrice < digikeyPrice {
                cheaper = .lcsc
                savings = ((digikeyPrice - lcscPrice) / digikeyPrice) * 100
            } else if digikeyPrice < lcscPrice {
                cheaper = .digikey
                savings = ((lcscPrice - digikeyPrice) / lcscPrice) * 100
            }
        }

        let summary: String
        switch cheaper {
        case .lcsc:
            summary = String(format: "LCSC conviene del %.0f%% a qty %d", savings ?? 0, qty)
        case .digikey:
            summary = String(format: "DigiKey conviene del %.0f%% a qty %d", savings ?? 0, qty)
        case nil:
            if lcscPrice == nil {
                summary = "Solo DigiKey ha prezzo"
            } else if digikeyPrice == nil {
                summary = "Solo LCSC ha prezzo"
            } else {
                summary = "Prezzi equivalenti a qty \(qty)"
            }
        }

        return SupplierComparison(
            quantity: qty,
            lcscUnitPrice: lcscPrice,
            digikeyUnitPrice: digikeyPrice,
            lcscCurrency: lcsc.currency,
            digikeyCurrency: digikey.currency,
            cheaper: cheaper,
            savingsPercent: savings,
            summary: summary
        )
    }
}
