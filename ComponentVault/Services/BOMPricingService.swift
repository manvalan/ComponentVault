import Foundation

struct BOMLineCost: Identifiable, Sendable {
    var id: String { "\(item.persistentModelID)" }

    let item: ProjectItem
    let unitPrice: Double?
    let lineTotal: Double?
    let currency: String?
    let hasDigiKeyData: Bool
    let digikeyURL: String?
    let isObsolete: Bool
}

struct BOMCostSummary: Sendable {
    let lines: [BOMLineCost]
    let total: Double?
    let currency: String?
    let pricedLines: Int
    let missingLines: Int

    var formattedTotal: String {
        guard let total, let currency else { return "—" }
        return String(format: "%.2f %@", total, currency)
    }
}

enum BOMPricingService {
    static func digikeyCostSummary(for project: Project) -> BOMCostSummary {
        let lines = project.items.map { lineCost(for: $0) }
        let priced = lines.filter(\.hasDigiKeyData)
        let currency = priced.compactMap(\.currency).first
        let total = priced.compactMap(\.lineTotal).reduce(0, +)

        return BOMCostSummary(
            lines: lines,
            total: priced.isEmpty ? nil : total,
            currency: currency,
            pricedLines: priced.count,
            missingLines: lines.count - priced.count
        )
    }

    static func lineCost(for item: ProjectItem) -> BOMLineCost {
        guard let component = item.component else {
            return BOMLineCost(
                item: item,
                unitPrice: nil,
                lineTotal: nil,
                currency: nil,
                hasDigiKeyData: false,
                digikeyURL: nil,
                isObsolete: false
            )
        }

        component.migrateLegacySnapshotsIfNeeded()
        let qty = max(item.requiredQuantity, 1)
        let snapshot = component.digikeySnapshot
        let unitPrice = snapshot?.unitPrice(for: qty) ?? component.digikeyUnitPriceForInventory
        let currency = snapshot?.currency ?? component.currency
        let lineTotal = unitPrice.map { $0 * Double(item.requiredQuantity) }
        let status = snapshot?.productStatus ?? component.digikeyProductStatus ?? ""

        return BOMLineCost(
            item: item,
            unitPrice: unitPrice,
            lineTotal: lineTotal,
            currency: currency,
            hasDigiKeyData: unitPrice != nil,
            digikeyURL: snapshot?.productURL ?? component.supplierProductURL,
            isObsolete: isObsoleteStatus(status)
        )
    }

    static func reorderSuggestion(for component: Component) -> String? {
        component.migrateLegacySnapshotsIfNeeded()
        guard component.isLowStock, let snapshot = component.digikeySnapshot else { return nil }
        guard let stock = snapshot.supplierStock, stock > 0 else { return nil }

        let targetQty = max(component.minQuantity, 1)
        let price = snapshot.unitPrice(for: targetQty) ?? snapshot.price
        let priceText: String
        if let price, let currency = snapshot.currency {
            priceText = String(format: "%.3f %@", price, currency)
        } else {
            priceText = "prezzo N/D"
        }

        return "DigiKey: \(stock) pz · \(priceText)"
    }

    static func isObsoleteStatus(_ status: String) -> Bool {
        let lower = status.lowercased()
        return lower.contains("obsolete")
            || lower.contains("nrnd")
            || lower.contains("discontinued")
            || lower.contains("last time buy")
    }
}
