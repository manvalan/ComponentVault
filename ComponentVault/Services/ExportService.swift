import Foundation

enum ExportService {
    static func inventoryCSV(components: [Component]) -> String {
        var lines = ["LCSC;MPN;Descrizione;Categoria;Valore;Footprint;Quantità;Soglia;Tag;Note"]
        for c in components.sorted(by: { $0.lcscCode < $1.lcscCode }) {
            lines.append([
                c.lcscCode,
                c.mpn,
                c.componentDescription,
                c.category,
                c.value,
                c.footprint,
                "\(c.quantity)",
                "\(c.minQuantity)",
                c.tags.joined(separator: "|"),
                c.notes
            ].map(csvEscape).joined(separator: ";"))
        }
        return lines.joined(separator: "\n")
    }

    static func projectBOMCSV(project: Project) -> String {
        var lines = ["Designator;LCSC;MPN;Descrizione;Richiesti;Disponibili;Mancanti;Stato"]
        for item in project.items.sorted(by: { $0.designator < $1.designator }) {
            let c = item.component
            let status: String
            if item.isAvailable {
                status = "OK"
            } else if item.isLowStock {
                status = "Scorta bassa"
            } else {
                status = "Mancante"
            }
            lines.append([
                item.designator,
                c?.lcscCode ?? "",
                c?.mpn ?? "",
                c?.componentDescription ?? "",
                "\(item.requiredQuantity)",
                "\(item.availableQuantity)",
                "\(item.shortage)",
                status
            ].map(csvEscape).joined(separator: ";"))
        }
        return lines.joined(separator: "\n")
    }

    static func projectBOMDigiKeyCSV(project: Project) -> String {
        let summary = BOMPricingService.digikeyCostSummary(for: project)
        var lines = [
            "Designator;LCSC;MPN;DigiKey PN;Richiesti;Prezzo unit. DigiKey;Totale riga;Valuta;Link ordine;Stato;Obsoleto"
        ]

        for line in summary.lines.sorted(by: { $0.item.designator < $1.item.designator }) {
            let item = line.item
            let component = item.component
            let status: String
            if item.isAvailable {
                status = "OK"
            } else if item.isLowStock {
                status = "Scorta bassa"
            } else {
                status = "Mancante"
            }

            let unit = line.unitPrice.map { String(format: "%.4f", $0) } ?? ""
            let total = line.lineTotal.map { String(format: "%.2f", $0) } ?? ""
            let digikeyPN = component?.digikeyPartNumber
                ?? component?.digikeySnapshot?.digikeyPartNumber
                ?? ""

            lines.append(csvRow(
                item.designator,
                component?.lcscCode ?? "",
                component?.mpn ?? "",
                digikeyPN,
                "\(item.requiredQuantity)",
                unit,
                total,
                line.currency ?? "",
                line.digikeyURL ?? "",
                status,
                line.isObsolete ? "Sì" : "No"
            ))
        }

        if let total = summary.total, let currency = summary.currency {
            lines.append("")
            lines.append("TOTALE DigiKey;;;;\(String(format: "%.2f", total));\(currency);;;")
        }

        return lines.joined(separator: "\n")
    }

    static func lowStockCSV(components: [Component]) -> String {
        inventoryCSV(components: components.filter(\.isLowStock))
    }

    static func lowStockDigiKeyCSV(components: [Component]) -> String {
        var lines = ["LCSC;MPN;Qty;Soglia;DigiKey PN;Stock DigiKey;Prezzo DigiKey;Valuta;Suggerimento riordino"]
        for component in components.filter(\.isLowStock).sorted(by: { $0.lcscCode < $1.lcscCode }) {
            component.migrateLegacySnapshotsIfNeeded()
            let snapshot = component.digikeySnapshot
            let price = snapshot?.unitPrice(for: max(component.minQuantity, 1)) ?? snapshot?.price
            let priceText = price.map { String(format: "%.4f", $0) } ?? ""
            let stockText = snapshot?.supplierStock.map(String.init) ?? ""
            let digikeyPN = snapshot?.digikeyPartNumber ?? component.digikeyPartNumber ?? ""
            let currency = snapshot?.currency ?? component.currency ?? ""
            let suggestion = BOMPricingService.reorderSuggestion(for: component) ?? ""

            lines.append(csvRow(
                component.lcscCode,
                component.mpn,
                "\(component.quantity)",
                "\(component.minQuantity)",
                digikeyPN,
                stockText,
                priceText,
                currency,
                suggestion
            ))
        }
        return lines.joined(separator: "\n")
    }

    private static func csvRow(_ fields: String...) -> String {
        fields.map(csvEscape).joined(separator: ";")
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(";") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
