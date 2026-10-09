import Foundation

struct BOMLineCost: Identifiable {
    var id: String { "\(item.persistentModelID)" }

    let item: ProjectItem
    let unitPrice: Double?
    let lineTotal: Double?
    let currency: String?
    let isObsolete: Bool
}

struct BOMCostSummary {
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

/// Costo della BOM con i prezzi LCSC (scaglione in base alla quantità richiesta).
enum BOMPricingService {
    static func costSummary(for project: Project) -> BOMCostSummary {
        let lines = project.items.map { lineCost(for: $0) }
        let priced = lines.filter { $0.unitPrice != nil }
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
            return BOMLineCost(item: item, unitPrice: nil, lineTotal: nil, currency: nil, isObsolete: false)
        }

        component.migrateLegacySnapshotsIfNeeded()
        let qty = max(item.requiredQuantity, 1)
        let snapshot = component.lcscSnapshot
        let unitPrice = snapshot?.unitPrice(for: qty) ?? component.price
        let currency = snapshot?.currency ?? component.currency
        let status = snapshot?.productStatus ?? ""

        return BOMLineCost(
            item: item,
            unitPrice: unitPrice,
            lineTotal: unitPrice.map { $0 * Double(item.requiredQuantity) },
            currency: currency,
            isObsolete: isObsoleteStatus(status)
        )
    }

    static func isObsoleteStatus(_ status: String) -> Bool {
        let lower = status.lowercased()
        return lower.contains("obsolete")
            || lower.contains("nrnd")
            || lower.contains("discontinued")
            || lower.contains("last time buy")
    }
}
