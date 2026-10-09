import Foundation

enum ExportService {
    static func inventoryCSV(components: [Component]) -> String {
        var lines = ["CV;LCSC;MPN;Descrizione;Categoria;Valore;Footprint;Quantità;Soglia;Tag;Note"]
        for c in components.sorted(by: { $0.lcscCode < $1.lcscCode }) {
            lines.append([
                c.inventoryCode,
                c.supplierLCSCCode ?? "",
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
        var lines = ["Designator;CV;LCSC;MPN;Descrizione;Richiesti;Disponibili;Mancanti;Stato;EasyEDA"]
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
            let easyEDA = c?.hasValidLCSCCode == true ? "Pronto" : "Manca C"
            lines.append([
                item.designator,
                c?.inventoryCode ?? "",
                c?.supplierLCSCCode ?? "",
                c?.mpn ?? "",
                c?.componentDescription ?? "",
                "\(item.requiredQuantity)",
                "\(item.availableQuantity)",
                "\(item.shortage)",
                status,
                easyEDA
            ].map(csvEscape).joined(separator: ";"))
        }
        return lines.joined(separator: "\n")
    }

    static func projectBOMEasyEDACSV(project: Project) -> String {
        EasyEDAService.projectBOM(project: project)
    }

    static func projectBOMMissingEasyEDACSV(project: Project) -> String {
        EasyEDAService.projectBOM(project: project, missingOnly: true)
    }

    static func projectBOMMissingLCSCEasyEDACSV(project: Project) -> String {
        EasyEDAService.projectBOMWithoutLCSC(project)
    }

    static func lowStockCSV(components: [Component]) -> String {
        inventoryCSV(components: components.filter(\.isLowStock))
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

// MARK: - KiCad symbol export

/// Genera un simbolo `.kicad_sym` generico da esportare.
enum KiCadExportService {
    static func symbolName(for component: Component) -> String {
        symbolName(mpn: component.mpn, lcscCode: component.supplierLCSCCode ?? component.lcscCode)
    }

    static func symbolName(for record: ComponentRecord) -> String {
        symbolName(mpn: record.mpn, lcscCode: record.lcscCode)
    }

    static func symbolName(mpn: String, lcscCode: String) -> String {
        let base = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        let lcsc = lcscCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = base.isEmpty ? lcsc : "\(base)_\(lcsc)"
        let sanitized = raw
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return String(sanitized.prefix(80))
    }

    static func libraryFileContent(for component: Component) -> String {
        libraryFileContent(symbolEntry(for: component))
    }

    static func libraryFileContent(for record: ComponentRecord) -> String {
        libraryFileContent(symbolEntry(for: record))
    }

    static func libraryFileContent(_ symbolEntry: String) -> String {
        """
        (kicad_symbol_lib (version 20220914) (generator "ComponentVault")
        \(symbolEntry)
        )
        """
    }

    static func symbolEntry(for component: Component) -> String {
        let type = component.componentType
        let lcsc = component.supplierLCSCCode ?? (LCSCCode.isValid(component.lcscCode) ? component.lcscCode : "")
        return symbolEntry(
            name: symbolName(for: component),
            reference: type.kicadReference,
            value: component.displayValue,
            footprint: component.displayFootprint,
            mpn: component.mpn,
            manufacturer: component.brand,
            lcscCode: lcsc,
            datasheetURL: component.datasheetURL
        )
    }

    static func symbolEntry(for record: ComponentRecord) -> String {
        let type = ComponentType.from(category: record.category)
        let value = record.value.isEmpty || record.value == "N/A"
            ? (record.parameters["Resistance"]
                ?? record.parameters["Capacitance"]
                ?? record.parameters["Inductance"]
                ?? "—")
            : record.value
        let footprint = record.footprint.isEmpty
            ? (record.parameters["Package"] ?? record.parameters["Package / Case"] ?? "")
            : record.footprint
        return symbolEntry(
            name: symbolName(for: record),
            reference: type.kicadReference,
            value: value,
            footprint: footprint,
            mpn: record.mpn,
            manufacturer: record.brand,
            lcscCode: record.lcscCode,
            datasheetURL: record.datasheetURL
        )
    }

    private static func symbolEntry(
        name: String,
        reference: String,
        value: String,
        footprint: String,
        mpn: String,
        manufacturer: String,
        lcscCode: String,
        datasheetURL: String?
    ) -> String {
        let safeName = escapeKiCad(name)
        let safeValue = escapeKiCad(value)
        let safeFootprint = escapeKiCad(footprint)
        let safeMPN = escapeKiCad(mpn)
        let safeBrand = escapeKiCad(manufacturer)
        let safeLCSC = escapeKiCad(lcscCode)
        let safeDatasheet = escapeKiCad(datasheetURL ?? "")

        return """
          (symbol "\(safeName)" (pin_numbers hide) (pin_names (offset 0.254)) (in_bom yes) (on_board yes)
            (property "Reference" "\(reference)" (at 0 5.08 0)
              (effects (font (size 1.27 1.27))))
            (property "Value" "\(safeValue)" (at 0 2.54 0)
              (effects (font (size 1.27 1.27))))
            (property "Footprint" "\(safeFootprint)" (at 0 -2.54 0)
              (effects (font (size 1.27 1.27)) hide))
            (property "Datasheet" "\(safeDatasheet)" (at 0 0 0)
              (effects (font (size 1.27 1.27)) hide))
            (property "LCSC" "\(safeLCSC)" (at 0 0 0)
              (effects (font (size 1.27 1.27)) hide))
            (property "MPN" "\(safeMPN)" (at 0 0 0)
              (effects (font (size 1.27 1.27)) hide))
            (property "Manufacturer" "\(safeBrand)" (at 0 0 0)
              (effects (font (size 1.27 1.27)) hide))
            (symbol "\(safeName)_0_1"
              (rectangle (start -2.032 -0.762) (end 2.032 0.762)
                (stroke (width 0.254) (type default))
                (fill (type none)))
              (pin passive line (at -3.81 0 0) (length 2.54)
                (name "~" (effects (font (size 1.27 1.27))))
                (number "1" (effects (font (size 1.27 1.27)))))
              (pin passive line (at 3.81 0 180) (length 2.54)
                (name "~" (effects (font (size 1.27 1.27))))
                (number "2" (effects (font (size 1.27 1.27)))))
            )
          )
        """
    }

    private static func escapeKiCad(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
