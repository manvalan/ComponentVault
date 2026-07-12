import Foundation

struct CatalogSearchQuery: Sendable, Equatable {
    var type: ComponentType = .resistor
    var value: String = ""
    var footprint: String = ""

    var isEmpty: Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && footprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func digiKeyKeyword() -> String {
        var parts: [String] = []
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFootprint = footprint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedValue.isEmpty { parts.append(trimmedValue) }
        if !trimmedFootprint.isEmpty { parts.append(trimmedFootprint) }
        parts.append(type.digiKeyKeyword)
        return parts.joined(separator: " ")
    }
}

struct CatalogMatchCard: Identifiable, Sendable {
    let id: String
    let type: ComponentType
    let value: String
    let footprint: String
    let mpn: String
    let description: String
    let brand: String

    let lcscCode: String?
    let lcscPrice: Double?
    let lcscCurrency: String?
    let lcscStock: Int?
    let lcscURL: String?

    let digikeyPartNumber: String?
    let digikeyPrice: Double?
    let digikeyCurrency: String?
    let digikeyStock: Int?
    let digikeyURL: String?

    let inInventory: Bool
    let inventoryQuantity: Int?
    let digikeyRecord: ComponentRecord?
    let lcscRecord: ComponentRecord?
    let lcscSource: LCSCMatchSource?

    var hasLCSC: Bool {
        guard let lcscCode else { return false }
        return LCSCCode.isValid(lcscCode)
    }
    var hasDigiKey: Bool { digikeyPartNumber != nil }
    var hasBothCodes: Bool { hasLCSC && hasDigiKey }

    /// Codice `CV-*` proposto quando LCSC non è disponibile.
    var proposedInternalCode: String? {
        guard !hasLCSC else { return nil }
        let seed: String
        if let digikeyPartNumber, !digikeyPartNumber.isEmpty {
            seed = digikeyPartNumber
        } else if !mpn.isEmpty {
            seed = mpn
        } else {
            return nil
        }
        return InternalComponentCode.make(from: seed)
    }

    var lcscDisplayCode: String {
        if hasLCSC, let lcscCode { return lcscCode }
        return proposedInternalCode ?? "—"
    }

    var usesInternalLCSCPlaceholder: Bool {
        !hasLCSC && proposedInternalCode != nil
    }

    var lcscLink: URL? {
        guard let lcscCode else { return nil }
        return URL(string: "https://www.lcsc.com/product-detail/\(lcscCode).html")
    }

    var digikeyLink: URL? {
        guard let url = digikeyURL, let parsed = URL(string: url) else { return nil }
        return parsed
    }
}

extension ComponentType {
    var digiKeyKeyword: String {
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
}

enum CatalogMatchNormalizer {
    static func mpn(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    static func footprintToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let match = trimmed.range(of: #"\b\d{4}\b"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        let digits = trimmed.prefix(while: { $0.isNumber })
        return digits.isEmpty ? trimmed.uppercased() : String(digits)
    }

    static func valueToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ω", with: "ohm")
            .replacingOccurrences(of: "Ω", with: "ohm")
            .replacingOccurrences(of: " ", with: "")
    }

    static func matches(
        recordType: ComponentType,
        recordValue: String,
        recordFootprint: String,
        query: CatalogSearchQuery
    ) -> Bool {
        guard recordType == query.type else { return false }

        let queryValue = valueToken(query.value)
        let queryFootprint = footprintToken(query.footprint)
        let recordValueNorm = valueToken(recordValue)
        let recordFootprintNorm = footprintToken(recordFootprint)

        let valueOK = queryValue.isEmpty
            || recordValueNorm.contains(queryValue)
            || queryValue.contains(recordValueNorm)
            || electricalClose(queryValue, recordValueNorm)

        let footprintOK = queryFootprint.isEmpty
            || recordFootprintNorm == queryFootprint
            || recordFootprint.uppercased().contains(queryFootprint)

        return valueOK && footprintOK
    }

    private static func electricalClose(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = CatalogValueSortKey.parseElectrical(lhs),
              let right = CatalogValueSortKey.parseElectrical(rhs) else {
            return false
        }
        guard left > 0, right > 0 else { return false }
        let ratio = left / right
        return ratio > 0.98 && ratio < 1.02
    }
}
