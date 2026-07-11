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

    static func lowStockCSV(components: [Component]) -> String {
        inventoryCSV(components: components.filter(\.isLowStock))
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(";") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
