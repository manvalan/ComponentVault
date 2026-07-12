import Foundation

/// Export/import BOM per EasyEDA e ordine JLCPCB (colonna LCSC Cxxxxx).
enum EasyEDAService {
    /// Header standard accettato da EasyEDA / JLCPCB assembly.
    static let bomHeader = "Comment,Designator,Footprint,Value,LCSC Part #"

    static func projectBOM(
        project: Project,
        missingOnly: Bool = false,
        requireLCSC: Bool = true
    ) -> String {
        var lines = [bomHeader]
        for item in project.items.sorted(by: { $0.designator < $1.designator }) {
            guard let component = item.component else { continue }
            if missingOnly, item.isAvailable { continue }

            let lcsc = component.supplierLCSCCode ?? ""
            if requireLCSC, lcsc.isEmpty { continue }

            let comment = bomComment(for: item, component: component)
            let footprint = component.footprint.isEmpty ? "—" : component.footprint
            let value = component.value.isEmpty ? (item.notes.isEmpty ? component.mpn : item.notes) : component.value

            lines.append(csvRow(
                comment,
                item.designator,
                footprint,
                value,
                lcsc
            ))
        }
        return lines.joined(separator: "\n")
    }

    /// Righe del progetto ancora senza codice LCSC Cxxxxx (da risolvere prima di EasyEDA).
    static func projectItemsMissingLCSC(_ project: Project) -> [ProjectItem] {
        project.items.filter { item in
            guard let component = item.component else { return true }
            return !component.hasValidLCSCCode
        }
    }

    /// BOM EasyEDA con righe senza Cxxxxx (da completare manualmente o via risoluzione MPN).
    static func projectBOMWithoutLCSC(_ project: Project) -> String {
        var lines = [bomHeader]
        for item in project.items.sorted(by: { $0.designator < $1.designator }) {
            guard let component = item.component, !component.hasValidLCSCCode else { continue }
            let comment = bomComment(for: item, component: component)
            let footprint = component.footprint.isEmpty ? "—" : component.footprint
            let value = component.value.isEmpty ? (item.notes.isEmpty ? component.mpn : item.notes) : component.value
            lines.append(csvRow(comment, item.designator, footprint, value, ""))
        }
        return lines.joined(separator: "\n")
    }

    static func easyEDAReadyCount(for project: Project) -> Int {
        project.items.filter { $0.component?.hasValidLCSCCode == true }.count
    }

    private static func bomComment(for item: ProjectItem, component: Component) -> String {
        if !item.notes.isEmpty { return item.notes }
        if !component.componentDescription.isEmpty { return component.componentDescription }
        if !component.mpn.isEmpty { return component.mpn }
        return component.inventoryCode
    }

    private static func csvRow(_ fields: String...) -> String {
        fields.map(csvEscape).joined(separator: ",")
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
