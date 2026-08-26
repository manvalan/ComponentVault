import Foundation

/// Unità per valore elettrico in ricerca catalogo e matching.
enum ComponentValueUnit: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case milliohm
    case ohm
    case kilohm
    case megohm

    case picofarad
    case nanofarad
    case microfarad
    case millifarad

    case nanohenry
    case microhenry
    case millihenry
    case henry

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .milliohm: "mΩ"
        case .ohm: "Ω"
        case .kilohm: "kΩ"
        case .megohm: "MΩ"
        case .picofarad: "pF"
        case .nanofarad: "nF"
        case .microfarad: "µF"
        case .millifarad: "mF"
        case .nanohenry: "nH"
        case .microhenry: "µH"
        case .millihenry: "mH"
        case .henry: "H"
        }
    }

    static func units(for type: ComponentType) -> [ComponentValueUnit] {
        switch type {
        case .resistor: [.milliohm, .ohm, .kilohm, .megohm]
        case .capacitor: [.picofarad, .nanofarad, .microfarad, .millifarad]
        case .inductor: [.nanohenry, .microhenry, .millihenry, .henry]
        default: []
        }
    }

    static func defaultUnit(for type: ComponentType) -> ComponentValueUnit {
        switch type {
        case .resistor: .kilohm
        case .capacitor: .nanofarad
        case .inductor: .microhenry
        default: .ohm
        }
    }
}

enum ComponentValueFormatter {
    /// Valore canonico per LCSC / matching (es. 10 + kΩ → 10kΩ).
    static func formattedValue(amount: String, unit: ComponentValueUnit) -> String {
        let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        switch unit {
        case .milliohm: return "\(trimmed)mΩ"
        case .ohm: return "\(trimmed)Ω"
        case .kilohm: return "\(trimmed)kΩ"
        case .megohm: return "\(trimmed)MΩ"
        case .picofarad: return "\(trimmed)pF"
        case .nanofarad: return "\(trimmed)nF"
        case .microfarad: return "\(trimmed)µF"
        case .millifarad: return "\(trimmed)mF"
        case .nanohenry: return "\(trimmed)nH"
        case .microhenry: return "\(trimmed)µH"
        case .millihenry: return "\(trimmed)mH"
        case .henry: return "\(trimmed)H"
        }
    }

    static func displayLabel(amount: String, unit: ComponentValueUnit) -> String {
        let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        return "\(trimmed) \(unit.shortLabel)"
    }

    /// Interpreta un valore libero legacy (10k, 100nF, 4k7…).
    static func parse(_ raw: String, type: ComponentType) -> (amount: String, unit: ComponentValueUnit) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("", ComponentValueUnit.defaultUnit(for: type))
        }

        let lower = trimmed.lowercased()
            .replacingOccurrences(of: "ω", with: "ohm")
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "μ", with: "u")

        switch type {
        case .resistor:
            if lower.hasSuffix("megohm") {
                return (String(trimmed.dropLast(6)), .megohm)
            }
            if trimmed.hasSuffix("MΩ") || (trimmed.hasSuffix("M") && !trimmed.hasSuffix("mΩ")) {
                return (String(trimmed.dropLast(trimmed.hasSuffix("MΩ") ? 2 : 1)), .megohm)
            }
            if lower.hasSuffix("mohm") {
                return (String(trimmed.dropLast(4)), .milliohm)
            }
            if trimmed.hasSuffix("mΩ") {
                return (String(trimmed.dropLast(2)), .milliohm)
            }
            if lower.hasSuffix("kohm") || trimmed.hasSuffix("kΩ") || lower.hasSuffix("k") {
                let drop = lower.hasSuffix("kohm") ? 4 : (trimmed.hasSuffix("kΩ") ? 2 : 1)
                return (String(trimmed.dropLast(drop)), .kilohm)
            }
            if lower.hasSuffix("ohm") || trimmed.hasSuffix("Ω") {
                let drop = lower.hasSuffix("ohm") ? 3 : 1
                return (String(trimmed.dropLast(drop)), .ohm)
            }
            if let match = lower.range(of: #"^(\d+)k(\d+)$"#, options: .regularExpression) {
                let token = String(lower[match])
                if let regex = try? NSRegularExpression(pattern: #"^(\d+)k(\d+)$"#),
                   let found = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
                   let whole = Range(found.range(at: 1), in: token),
                   let frac = Range(found.range(at: 2), in: token) {
                    return ("\(token[whole]).\(token[frac])", .kilohm)
                }
            }
            return (trimmed, .ohm)

        case .capacitor:
            if lower.hasSuffix("pf") { return (String(trimmed.dropLast(2)), .picofarad) }
            if lower.hasSuffix("nf") { return (String(trimmed.dropLast(2)), .nanofarad) }
            if lower.hasSuffix("uf") || lower.hasSuffix("µf") { return (String(trimmed.dropLast(2)), .microfarad) }
            if lower.hasSuffix("mf") { return (String(trimmed.dropLast(2)), .millifarad) }
            if lower.hasSuffix("u") { return (String(trimmed.dropLast(1)), .microfarad) }
            if lower.hasSuffix("n") { return (String(trimmed.dropLast(1)), .nanofarad) }
            if lower.hasSuffix("p") { return (String(trimmed.dropLast(1)), .picofarad) }
            return (trimmed, .nanofarad)

        case .inductor:
            if lower.hasSuffix("nh") { return (String(trimmed.dropLast(2)), .nanohenry) }
            if lower.hasSuffix("uh") || lower.hasSuffix("µh") { return (String(trimmed.dropLast(2)), .microhenry) }
            if lower.hasSuffix("mh") { return (String(trimmed.dropLast(2)), .millihenry) }
            if lower.hasSuffix("h") { return (String(trimmed.dropLast(1)), .henry) }
            if lower.hasSuffix("u") { return (String(trimmed.dropLast(1)), .microhenry) }
            if lower.hasSuffix("n") { return (String(trimmed.dropLast(1)), .nanohenry) }
            return (trimmed, .microhenry)

        default:
            return (trimmed, ComponentValueUnit.defaultUnit(for: type))
        }
    }
}

extension ComponentType {
    var usesStructuredValue: Bool {
        switch self {
        case .resistor, .capacitor, .inductor: true
        default: false
        }
    }
}
