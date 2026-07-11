import Foundation
import SwiftUI

enum ComponentType: String, CaseIterable, Identifiable, Sendable {
    case resistor
    case capacitor
    case inductor
    case ic
    case connector
    case diode
    case led
    case switch_
    case module
    case regulator
    case display
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .resistor: "Resistenze"
        case .capacitor: "Condensatori"
        case .inductor: "Induttori"
        case .ic: "Circuiti integrati"
        case .connector: "Connettori"
        case .diode: "Diodi"
        case .led: "LED"
        case .switch_: "Interruttori"
        case .module: "Moduli"
        case .regulator: "Regolatori"
        case .display: "Display"
        case .other: "Altro"
        }
    }

    var icon: String {
        switch self {
        case .resistor: "lines.measurement.horizontal"
        case .capacitor: "capsule.portrait"
        case .inductor: "circle.hexagongrid"
        case .ic: "cpu"
        case .connector: "cable.connector"
        case .diode: "arrow.right.circle"
        case .led: "lightbulb.led"
        case .switch_: "switch.2"
        case .module: "antenna.radiowaves.left.and.right"
        case .regulator: "bolt.circle"
        case .display: "display"
        case .other: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .resistor: .orange
        case .capacitor: .blue
        case .inductor: .purple
        case .ic: .teal
        case .connector: .gray
        case .diode: .yellow
        case .led: .green
        case .switch_: .brown
        case .module: .indigo
        case .regulator: .red
        case .display: .cyan
        case .other: .secondary
        }
    }

    /// Classificazione basata sul percorso categoria LCSC (es. `Resistors/Chip Resistor`).
    static func from(category: String) -> ComponentType {
        let lower = category.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return .other }

        let root = lower.split(separator: "/").first.map(String.init) ?? lower

        // Percorsi specifici prima dei match generici (evita OLED → LED, transistor → diodo, ecc.)
        if lower.hasPrefix("displays/") { return .display }
        if lower.hasPrefix("memory/") { return .ic }
        if lower.hasPrefix("amplifiers/") || lower.hasPrefix("interface/") { return .ic }
        if lower.hasPrefix("optoisolators/") { return .ic }
        if lower.hasPrefix("iot/") || lower.contains("communication modules") { return .module }
        if lower.hasPrefix("power management") || lower.contains("voltage regulator") { return .regulator }

        if root == "resistors" || lower.contains("resistor") { return .resistor }
        if root == "capacitors" || lower.contains("capacitor") { return .capacitor }
        if lower.contains("inductor") || lower.contains("choke") || lower.contains("coil") { return .inductor }

        if lower.contains("connector") || lower.contains("header") { return .connector }
        if lower.contains("switch") { return .switch_ }

        if lower.hasPrefix("optoelectronics/led")
            || lower.contains("led indication")
            || lower.contains("led addressable") {
            return .led
        }

        if lower.hasPrefix("diodes/") || lower.contains("tvs diode") { return .diode }
        if lower.hasPrefix("transistors/") { return .diode }

        if lower.contains("microcontroller") || lower.contains("processor") || lower.contains("embedded") {
            return .ic
        }

        return .other
    }
}

extension Component {
    var componentType: ComponentType {
        ComponentType.from(category: category)
    }

    var displayValue: String {
        if !value.isEmpty && value != "N/A" { return value }
        for key in ["Resistance", "Capacitance", "Inductance", "Voltage - Rated"] {
            if let param = parameters.first(where: { $0.name == key }), !param.value.isEmpty {
                return param.value
            }
        }
        return "—"
    }

    var displayFootprint: String {
        let fp = footprint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fp.isEmpty { return fp }
        for key in ["Package", "Package / Case", "Case"] {
            if let pkg = parameters.first(where: { $0.name == key })?.value, !pkg.isEmpty {
                return pkg
            }
        }
        return "—"
    }
}

struct CatalogGroup: Identifiable {
    let id: String
    let value: String
    let footprint: String
    let totalQuantity: Int
    let componentCount: Int
    let components: [Component]

    var primaryMPN: String {
        components.first?.mpn ?? "—"
    }

    static func build(from components: [Component], type: ComponentType) -> [CatalogGroup] {
        let grouped = Dictionary(grouping: components) { c in
            "\(c.displayValue)|\(c.displayFootprint)"
        }

        return grouped.map { key, items in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return CatalogGroup(
                id: key,
                value: parts.first ?? "—",
                footprint: parts.count > 1 ? parts[1] : "—",
                totalQuantity: items.reduce(0) { $0 + $1.quantity },
                componentCount: items.count,
                components: items.sorted { $0.mpn.localizedStandardCompare($1.mpn) == .orderedAscending }
            )
        }
        .sorted { lhs, rhs in
            let valueOrder = CatalogValueSortKey.compare(lhs.value, rhs.value, for: type)
            if valueOrder != .orderedSame { return valueOrder == .orderedAscending }
            let fpOrder = CatalogFootprintSortKey.compare(lhs.footprint, rhs.footprint)
            if fpOrder != .orderedSame { return fpOrder == .orderedAscending }
            return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
        }
    }
}

struct CatalogIndex {
    let typeCounts: [ComponentType: Int]
    let groupsByType: [ComponentType: [CatalogGroup]]

    var sortedTypes: [ComponentType] {
        typeCounts.keys.sorted { lhs, rhs in
            let lc = typeCounts[lhs, default: 0]
            let rc = typeCounts[rhs, default: 0]
            if lc != rc { return lc > rc }
            return lhs.label < rhs.label
        }
    }

    static func build(from components: [Component]) -> CatalogIndex {
        var typeBuckets: [ComponentType: [Component]] = [:]
        for component in components {
            typeBuckets[component.componentType, default: []].append(component)
        }

        var counts: [ComponentType: Int] = [:]
        var groups: [ComponentType: [CatalogGroup]] = [:]
        for (type, items) in typeBuckets {
            counts[type] = items.count
            groups[type] = CatalogGroup.build(from: items, type: type)
        }

        return CatalogIndex(typeCounts: counts, groupsByType: groups)
    }
}

enum CatalogValueSortKey {
    static func compare(_ lhs: String, _ rhs: String, for type: ComponentType) -> ComparisonResult {
        switch type {
        case .resistor, .capacitor, .inductor:
            let ln = parseElectrical(lhs)
            let rn = parseElectrical(rhs)
            if let ln, let rn {
                if ln == rn { return .orderedSame }
                return ln < rn ? .orderedAscending : .orderedDescending
            }
        default:
            break
        }
        return lhs.localizedStandardCompare(rhs)
    }

    static func parseElectrical(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—", trimmed != "N/A" else { return nil }

        let token = trimmed.split(separator: "~").first.map(String.init) ?? trimmed
        let normalized = token
            .replacingOccurrences(of: "Ω", with: "")
            .replacingOccurrences(of: "ohm", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "μ", with: "u")
            .trimmingCharacters(in: .whitespaces)

        let pattern = #"^([\d.]+)\s*([kKmMuUnNpP]?)([FfHhVv]?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let numberRange = Range(match.range(at: 1), in: normalized),
              let number = Double(normalized[numberRange]) else {
            return nil
        }

        let prefixRange = Range(match.range(at: 2), in: normalized)
        let unitRange = Range(match.range(at: 3), in: normalized)
        let prefix = prefixRange.map { String(normalized[$0]).lowercased() } ?? ""
        let unit = unitRange.map { String(normalized[$0]).lowercased() } ?? ""

        let prefixMultiplier: Double = switch prefix {
        case "k": 1e3
        case "m": 1e-3
        case "u": 1e-6
        case "n": 1e-9
        case "p": 1e-12
        default: 1
        }

        let unitMultiplier: Double = switch unit {
        case "f": 1e-6
        case "h": 1e-6
        default: 1
        }

        return number * prefixMultiplier * unitMultiplier
    }
}

enum CatalogFootprintSortKey {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lk = numericPrefix(lhs)
        let rk = numericPrefix(rhs)
        if let lk, let rk {
            if lk == rk { return .orderedSame }
            return lk < rk ? .orderedAscending : .orderedDescending
        }
        return lhs.localizedStandardCompare(rhs)
    }

    private static func numericPrefix(_ value: String) -> Int? {
        let digits = value.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}
