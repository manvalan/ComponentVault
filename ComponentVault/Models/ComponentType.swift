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
        englishLabel
    }

    /// Etichetta categoria in inglese (filtri e catalogo LCSC).
    var englishLabel: String {
        switch self {
        case .resistor: "Resistors"
        case .capacitor: "Capacitors"
        case .inductor: "Inductors"
        case .ic: "Integrated Circuits"
        case .connector: "Connectors"
        case .diode: "Diodes"
        case .led: "LEDs"
        case .switch_: "Switches"
        case .module: "Modules"
        case .regulator: "Power Management"
        case .display: "Displays"
        case .other: "Other"
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

        if root == "resistors" || root == "resistenze" || root == "resistenza" || lower.contains("resistor") { return .resistor }
        if root == "capacitors" || root == "condensatori" || root == "condensatore" || lower.contains("capacitor") || lower.contains("condensator") { return .capacitor }
        if root == "inductors" || root == "induttori" || root == "induttore" || lower.contains("inductor") || lower.contains("indutt") || lower.contains("choke") || lower.contains("coil") { return .inductor }

        if lower.contains("connett") || lower.contains("connector") || lower.contains("header") { return .connector }
        if lower.contains("interrutt") || lower.contains("switch") { return .switch_ }

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

    /// Parametri LCSC usati in `paramNameValueMap` per filtrare per valore.
    func lcscValueParamNames(for value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        switch self {
        case .resistor:
            return ["Resistance"]
        case .capacitor:
            if trimmed.range(of: #"(\d+(\.\d+)?)\s*v"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return ["Capacitance", "Voltage - Rated"]
            }
            return ["Capacitance"]
        case .inductor:
            return ["Inductance"]
        case .diode:
            return ["Forward Voltage (Vf)", "Voltage - Rated", "Reverse Voltage (Vr)"]
        case .led:
            if trimmed.range(of: #"(\d+(\.\d+)?)\s*v"#, options: [.regularExpression, .caseInsensitive]) != nil
                || trimmed.lowercased().contains("vf") {
                return ["Forward Voltage (Vf)"]
            }
            if trimmed.range(of: #"(\d+(\.\d+)?)\s*(ma|a)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return ["Current - Continuous Forward (If)"]
            }
            return ["Color", "Luminous Intensity"]
        case .regulator:
            if trimmed.range(of: #"(\d+(\.\d+)?)\s*v"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return ["Output Voltage", "Voltage - Supply"]
            }
            return ["Output Current"]
        case .display:
            return ["Display Size", "Resolution"]
        case .switch_:
            return ["Contact Rating (Current)", "Voltage - AC"]
        case .connector, .ic, .module, .other:
            return []
        }
    }

    /// Mappa parametri LCSC → valore per la ricerca parametrica.
    func lcscParamMap(for value: String) -> [String: [String]] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let primary = lcscValueParamNames(for: trimmed).first else {
            return [:]
        }
        return [primary: ElectricalValueNormalizer.lcscVariants(raw: trimmed, type: self)]
    }

    /// Radici categoria LCSC accettate quando si filtra per tipo componente.
    var lcscCategoryRoots: [String] {
        switch self {
        case .resistor:
            ["resistors", "resistor", "resistenze", "resistenza"]
        case .capacitor:
            ["capacitors", "capacitor", "condensatori", "condensatore"]
        case .inductor:
            ["inductors", "inductor", "induttori", "induttore", "coil", "choke", "ferrite"]
        case .ic:
            [
                "integrated circuits", "circuiti integrati", "microcontroller", "microcontrollori",
                "mcu", "processor", "processori", "embedded", "memory", "memorie",
                "interface", "interfacce", "amplifier", "amplificatori", "optoisolator", "logic", "fpga", "cpld"
            ]
        case .connector:
            ["connectors", "connector", "connettori", "connettore", "header", "socket", "terminal", "wire-to-board", "ffc", "fpc"]
        case .diode:
            ["diodes", "diode", "diodi", "transistors", "transistor", "transistori", "tvs", "zener", "schottky"]
        case .led:
            ["led", "optoelectronics", "optoelettronica", "lamp"]
        case .switch_:
            ["switch", "switches", "interruttori", "interruttore", "keypad"]
        case .module:
            ["module", "modules", "moduli", "modulo", "iot", "communication", "wireless", "bluetooth", "wifi", "lora", "rf"]
        case .regulator:
            ["power management", "regulator", "regolatori", "ldo", "dc-dc", "buck", "boost", "converter", "alimentazione"]
        case .display:
            ["displays", "display", "lcd", "oled", "tft", "screen", "schermi"]
        case .other:
            []
        }
    }

    /// Verifica se una categoria LCSC appartiene a questo tipo ComponentVault.
    func matchesLCSCCategory(_ category: String) -> Bool {
        if self == .other { return true }
        if ComponentType.from(category: category) == self { return true }
        let lower = category.lowercased()
        return lcscCategoryRoots.contains { lower.contains($0) }
    }

    /// Etichetta campo «valore» nella ricerca catalogo.
    var catalogValueLabel: String {
        switch self {
        case .resistor: "Valore (es. 10kΩ)"
        case .capacitor: "Valore (es. 100nF, 50V)"
        case .inductor: "Valore (es. 10uH)"
        case .ic: "MPN / part number"
        case .connector: "Tipo / passo (es. 2.54mm)"
        case .diode: "Tensione / corrente (es. 40V 1A)"
        case .led: "Colore / Vf (es. rosso, 3.3V)"
        case .switch_: "Rating (es. 50mA 12V)"
        case .module: "Modello / protocollo (es. ESP32)"
        case .regulator: "Output (es. 3.3V 1A)"
        case .display: "Dimensione / risoluzione"
        case .other: "Valore o MPN"
        }
    }

    /// Parametro LCSC per ricerca parametrica (legacy — preferire lcscParamMap(for:)).
    var lcscParamName: String? {
        lcscValueParamNames(for: "1").first
    }

    var lcscSearchKeyword: String {
        switch self {
        case .resistor: "resistor"
        case .capacitor: "capacitor"
        case .inductor: "inductor"
        case .ic: "integrated circuit"
        case .connector: "connector"
        case .diode: "diode"
        case .led: "led"
        case .switch_: "switch"
        case .module: "module"
        case .regulator: "voltage regulator"
        case .display: "display"
        case .other: "electronic component"
        }
    }

    /// Prefisso reference KiCad (R, C, L, …).
    var kicadReference: String {
        switch self {
        case .resistor: "R"
        case .capacitor: "C"
        case .inductor: "L"
        case .diode, .led: "D"
        case .connector: "J"
        case .switch_: "SW"
        case .ic, .regulator, .module: "U"
        case .display: "DS"
        case .other: "U"
        }
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
            let ln = parseElectrical(lhs, for: type)
            let rn = parseElectrical(rhs, for: type)
            if let ln, let rn {
                if ln == rn { return .orderedSame }
                return ln < rn ? .orderedAscending : .orderedDescending
            }
        default:
            break
        }
        return lhs.localizedStandardCompare(rhs)
    }

    static func parseElectrical(_ raw: String, for type: ComponentType = .other) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—", trimmed != "N/A" else { return nil }

        let token = trimmed.split(separator: "~").first.map(String.init) ?? trimmed
        let normalized = token
            .replacingOccurrences(of: "Ω", with: "")
            .replacingOccurrences(of: "ohm", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "μ", with: "u")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        if normalized.hasSuffix("f"), type == .capacitor || type == .other {
            if let parsed = parsePrefixedValue(String(normalized.dropLast()), unitMultiplier: 1) {
                return parsed
            }
        }

        if normalized.hasSuffix("h"), type == .inductor || type == .other {
            if let parsed = parsePrefixedValue(String(normalized.dropLast()), unitMultiplier: 1) {
                return parsed
            }
        }

        if normalized.hasSuffix("v"), type == .other {
            if let parsed = parsePrefixedValue(String(normalized.dropLast()), unitMultiplier: 1) {
                return parsed
            }
        }

        return parsePrefixedValue(normalized, unitMultiplier: 1)
    }

    private static func parsePrefixedValue(_ normalized: String, unitMultiplier: Double) -> Double? {
        let pattern = #"^([\d.]+)\s*([kKmMuUnNpP]?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let numberRange = Range(match.range(at: 1), in: normalized),
              let number = Double(normalized[numberRange]) else {
            return nil
        }

        let prefixRange = Range(match.range(at: 2), in: normalized)
        let prefix = prefixRange.map { String(normalized[$0]).lowercased() } ?? ""

        let prefixMultiplier: Double = switch prefix {
        case "k": 1e3
        case "m": 1e-3
        case "u": 1e-6
        case "n": 1e-9
        case "p": 1e-12
        default: 1
        }

        return number * prefixMultiplier * unitMultiplier
    }
}

/// Unifica radici categoria LCSC in inglese (es. Condensatori → Capacitors).
enum CategoryNormalizer {
    private static let rootAliases: [String: String] = [
        "resistors": "Resistors",
        "resistor": "Resistors",
        "resistenze": "Resistors",
        "resistenza": "Resistors",
        "resistore": "Resistors",
        "capacitors": "Capacitors",
        "capacitor": "Capacitors",
        "condensatori": "Capacitors",
        "condensatore": "Capacitors",
        "inductors": "Inductors",
        "inductor": "Inductors",
        "induttori": "Inductors",
        "induttore": "Inductors",
        "connectors": "Connectors",
        "connector": "Connectors",
        "connettori": "Connectors",
        "connettore": "Connectors",
        "diodes": "Diodes",
        "diode": "Diodes",
        "diodi": "Diodes",
        "transistors": "Transistors",
        "transistor": "Transistors",
        "transistori": "Transistors",
        "optoelectronics": "Optoelectronics",
        "optoelettronica": "Optoelectronics",
        "integrated circuits": "Integrated Circuits",
        "circuiti integrati": "Integrated Circuits",
        "microcontrollers": "Microcontrollers",
        "microcontroller": "Microcontrollers",
        "microcontrollori": "Microcontrollers",
        "microcontrollore": "Microcontrollers",
        "memory": "Memory",
        "memories": "Memory",
        "memorie": "Memory",
        "memoria": "Memory",
        "power management": "Power Management",
        "power management (PMIC)": "Power Management",
        "gestione alimentazione": "Power Management",
        "sensors": "Sensors",
        "sensori": "Sensors",
        "sensore": "Sensors",
        "displays": "Displays",
        "display": "Displays",
        "schermi": "Displays",
        "schermo": "Displays",
        "switches": "Switches",
        "switch": "Switches",
        "interruttori": "Switches",
        "interruttore": "Switches",
        "modules": "Modules",
        "module": "Modules",
        "moduli": "Modules",
        "modulo": "Modules",
        "iot": "IoT / Wireless",
        "wireless": "IoT / Wireless",
        "led": "LEDs",
        "leds": "LEDs",
        "crystals": "Crystals & Oscillators",
        "oscillators": "Crystals & Oscillators",
        "cristalli": "Crystals & Oscillators",
        "oscillatori": "Crystals & Oscillators",
        "relays": "Relays",
        "relè": "Relays",
        "rele": "Relays",
        "fuses": "Fuses",
        "fusibili": "Fuses",
        "fusibile": "Fuses",
        "transformers": "Transformers",
        "transformatori": "Transformers",
        "transformer": "Transformers",
        "transformatore": "Transformers",
    ]

    static func englishRoot(from category: String) -> String {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let rawRoot = trimmed.components(separatedBy: "/").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        let key = rawRoot.lowercased()

        if let canonical = rootAliases[key] {
            return canonical
        }

        let type = ComponentType.from(category: trimmed)
        if type != .other {
            return type.englishLabel
        }

        return titleCase(rawRoot)
    }

    static func matches(filterRoot: String, componentCategory: String) -> Bool {
        guard filterRoot != "Tutte" else { return true }
        return englishRoot(from: componentCategory) == filterRoot
    }

    private static func titleCase(_ value: String) -> String {
        value.prefix(1).uppercased() + value.dropFirst()
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
