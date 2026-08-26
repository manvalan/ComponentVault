import Foundation

struct CatalogSearchQuery: Sendable, Equatable {
    var type: ComponentType? = .resistor
    var valueAmount: String = ""
    var valueUnit: ComponentValueUnit = .kilohm
    var footprint: String = ""
    var brand: String = ""

    var resolvedType: ComponentType { type ?? .other }

    var typeSelectionLabel: String { type?.label ?? "Tutti" }

    /// Valore normalizzato per API e matching (es. 10kΩ, 100nF) oppure MPN/keyword.
    var value: String {
        if resolvedType.usesStructuredValue {
            return ComponentValueFormatter.formattedValue(amount: valueAmount, unit: valueUnit)
        }
        return valueAmount.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var valueDisplayLabel: String {
        if resolvedType.usesStructuredValue {
            return ComponentValueFormatter.displayLabel(amount: valueAmount, unit: valueUnit)
        }
        let trimmed = valueAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    var hasValue: Bool {
        !valueAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEmpty: Bool {
        false
    }

    var hasValueAndFootprint: Bool {
        hasValue && !footprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Ricerca testuale (ESP32, STM32…) anziché parametrica R/C/L.
    var isKeywordQuery: Bool {
        guard hasValue else { return false }
        if !resolvedType.usesStructuredValue { return true }
        return CatalogValueSortKey.parseElectrical(value, for: resolvedType) == nil
            && value.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
    }

    /// Keyword grezzo per LCSC (senza forzare tipo/passive).
    func lcscSearchKeywordText() -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFootprint = footprint.trimmingCharacters(in: .whitespacesAndNewlines)
        if isKeywordQuery {
            var parts: [String] = []
            if !trimmedValue.isEmpty { parts.append(trimmedValue) }
            if !trimmedFootprint.isEmpty { parts.append(trimmedFootprint) }
            return parts.joined(separator: " ")
        }
        return lcscKeyword()
    }

    func digiKeyKeyword() -> String {
        var parts: [String] = []
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFootprint = footprint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedValue.isEmpty {
            parts.append(ElectricalValueNormalizer.lcscVariants(raw: trimmedValue, type: resolvedType).first ?? trimmedValue)
        }
        if !trimmedFootprint.isEmpty { parts.append(trimmedFootprint) }
        parts.append(resolvedType.digiKeyKeyword)
        return parts.joined(separator: " ")
    }

    /// Keyword DigiKey: moduli/IC usano testo libero; passives restano parametrici.
    func digiKeySearchKeyword() -> String {
        if isKeywordQuery {
            return lcscSearchKeywordText()
        }
        return digiKeyKeyword()
    }

    /// Keyword per ricerca catalogo LCSC live (tipo + valore + package).
    func lcscKeyword() -> String {
        let trimmedValue = value
        let trimmedFootprint = footprint.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueForSearch = trimmedValue.isEmpty
            ? ""
            : (ElectricalValueNormalizer.lcscVariants(raw: trimmedValue, type: resolvedType).first ?? trimmedValue)

        switch resolvedType {
        case .ic, .module:
            var parts: [String] = []
            if !valueForSearch.isEmpty { parts.append(valueForSearch) }
            if !trimmedFootprint.isEmpty { parts.append(trimmedFootprint) }
            if parts.isEmpty { parts.append(resolvedType.lcscSearchKeyword) }
            return parts.joined(separator: " ")

        case .connector:
            var parts: [String] = [resolvedType.lcscSearchKeyword]
            if !valueForSearch.isEmpty { parts.append(valueForSearch) }
            if !trimmedFootprint.isEmpty { parts.append(trimmedFootprint) }
            return parts.joined(separator: " ")

        default:
            var parts: [String] = []
            if !valueForSearch.isEmpty { parts.append(valueForSearch) }
            if !trimmedFootprint.isEmpty { parts.append(trimmedFootprint) }
            if type != nil { parts.append(resolvedType.lcscSearchKeyword) }
            return parts.joined(separator: " ")
        }
    }

    /// Mappa parametri LCSC per filtro parametrico (tutte le categorie supportate).
    func lcscParamMap() -> [String: [String]] {
        resolvedType.lcscParamMap(for: value)
    }

    mutating func applyDefaultUnitForType() {
        valueUnit = ComponentValueUnit.defaultUnit(for: resolvedType)
    }

    mutating func clearValue() {
        valueAmount = ""
        valueUnit = ComponentValueUnit.defaultUnit(for: resolvedType)
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
        ElectricalValueNormalizer.normalizedToken(raw)
    }

    static func matches(
        recordType: ComponentType,
        recordValue: String,
        recordFootprint: String,
        query: CatalogSearchQuery,
        record: ComponentRecord? = nil
    ) -> Bool {
        if query.isKeywordQuery {
            return matchesKeyword(
                recordType: recordType,
                recordFootprint: recordFootprint,
                record: record,
                query: query
            )
        }

        guard recordType == query.resolvedType || query.type == nil else { return false }

        let queryValue = valueToken(query.value)
        let queryFootprint = footprintToken(query.footprint)
        let recordValueNorm = valueToken(recordValue)
        let recordFootprintNorm = footprintToken(recordFootprint)

        let valueOK = queryValue.isEmpty
            || recordValueNorm.contains(queryValue)
            || queryValue.contains(recordValueNorm)
            || electricalClose(queryValue, recordValueNorm, type: query.resolvedType)
            || electricalVariantsMatch(query.value, recordValue, type: query.resolvedType)

        let footprintOK = queryFootprint.isEmpty
            || recordFootprintNorm == queryFootprint
            || recordFootprint.uppercased().contains(queryFootprint)

        return valueOK && footprintOK
    }

    static func matchesKeyword(
        recordType: ComponentType,
        recordFootprint: String,
        record: ComponentRecord?,
        query: CatalogSearchQuery
    ) -> Bool {
        if query.type != nil {
            if query.resolvedType == .module, recordType != .module && recordType != .ic { return false }
            else if query.resolvedType == .ic, recordType != .ic && recordType != .module { return false }
            else if query.resolvedType != .module && query.resolvedType != .ic && recordType != query.resolvedType {
                return false
            }
        }

        if let record, !recordMatchesKeyword(record, keyword: query.value) {
            return false
        }

        let queryFootprint = footprintToken(query.footprint)
        guard !queryFootprint.isEmpty else { return true }
        let recordFootprintNorm = footprintToken(recordFootprint)
        return recordFootprintNorm == queryFootprint
            || recordFootprint.uppercased().contains(queryFootprint)
    }

    static func textContainsKeyword(_ haystack: String, keyword: String) -> Bool {
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return haystack.localizedCaseInsensitiveContains(needle)
    }

    static func recordMatchesKeyword(_ record: ComponentRecord, keyword: String) -> Bool {
        let fields = [
            record.mpn,
            record.name,
            record.description,
            record.brand,
            record.category,
            record.lcscCode,
            record.value,
        ]
        return fields.contains { textContainsKeyword($0, keyword: keyword) }
    }

    private static func electricalVariantsMatch(
        _ queryRaw: String,
        _ recordRaw: String,
        type: ComponentType
    ) -> Bool {
        let queryVariants = Set(
            ElectricalValueNormalizer.lcscVariants(raw: queryRaw, type: type)
                .map { valueToken($0) }
        )
        let recordVariants = Set(
            ElectricalValueNormalizer.lcscVariants(raw: recordRaw, type: type)
                .map { valueToken($0) }
        )
        return !queryVariants.isDisjoint(with: recordVariants)
    }

    static func matchesBrand(recordBrand: String, queryBrand: String) -> Bool {
        let query = queryBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let brand = recordBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brand.isEmpty else { return false }
        return brand.localizedCaseInsensitiveCompare(query) == .orderedSame
            || brand.localizedCaseInsensitiveContains(query)
            || query.localizedCaseInsensitiveContains(brand)
    }

    private static func electricalClose(_ lhs: String, _ rhs: String, type: ComponentType) -> Bool {
        guard let left = CatalogValueSortKey.parseElectrical(lhs, for: type),
              let right = CatalogValueSortKey.parseElectrical(rhs, for: type) else {
            return false
        }
        guard left > 0, right > 0 else { return false }
        let ratio = left / right
        return ratio > 0.98 && ratio < 1.02
    }
}

enum CatalogFilterOptions {
    /// Footprint presenti in inventario per il tipo selezionato (`nil` / `.other` = tutti).
    static func footprints(in inventory: [Component], for type: ComponentType) -> [String] {
        let values = inventory
            .filter { type == .other || $0.componentType == type }
            .map(\.displayFootprint)
            .filter { !$0.isEmpty && $0 != "—" && $0 != "N/A" }
        return uniqueSortedFootprints(values)
    }

    /// Produttori in inventario quando tipo, valore e footprint sono impostati.
    static func brands(
        in inventory: [Component],
        type: ComponentType,
        value: String,
        footprint: String
    ) -> [String] {
        let parsed = ComponentValueFormatter.parse(value, type: type)
        let probe = CatalogSearchQuery(
            type: type,
            valueAmount: parsed.amount,
            valueUnit: parsed.unit,
            footprint: footprint
        )
        guard probe.hasValueAndFootprint else { return [] }

        let values = inventory
            .filter { component in
                (type == .other || component.componentType == type)
                    && CatalogMatchNormalizer.matches(
                        recordType: component.componentType,
                        recordValue: component.displayValue,
                        recordFootprint: component.displayFootprint,
                        query: probe
                    )
            }
            .map(\.brand)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return Array(Set(values)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func uniqueSortedFootprints(_ values: [String]) -> [String] {
        Array(Set(values)).sorted { lhs, rhs in
            CatalogFootprintSortKey.compare(lhs, rhs) == .orderedAscending
        }
    }
}

enum CatalogSearchDefaults {
    static let typeKey = "catalogSearch.lastType"
    static let typeClearedKey = "catalogSearch.typeCleared"
    static let valueAmountKey = "catalogSearch.valueAmount"
    static let valueUnitKey = "catalogSearch.valueUnit"
    static let legacyValueKey = "catalogSearch.lastValue"
    static let footprintKey = "catalogSearch.lastFootprint"
    static let brandKey = "catalogSearch.lastBrand"
}

/// Normalizza shorthand elettrici (10u → 10uF, 10k → 10kΩ) per LCSC e matching locale.
enum ElectricalValueNormalizer {
    static func lcscVariants(raw: String, type: ComponentType) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var variants = Set<String>()
        variants.insert(trimmed)

        let unified = trimmed
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "μ", with: "u")
            .replacingOccurrences(of: "Ω", with: "Ω")
            .trimmingCharacters(in: .whitespaces)

        variants.insert(unified)

        switch type {
        case .capacitor:
            for value in expandCapacitance(unified) { variants.insert(value) }
        case .resistor:
            for value in expandResistance(unified) { variants.insert(value) }
        case .inductor:
            for value in expandInductance(unified) { variants.insert(value) }
        default:
            break
        }

        return variants.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    static func normalizedToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ω", with: "ohm")
            .replacingOccurrences(of: "Ω", with: "ohm")
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "μ", with: "u")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func expandCapacitance(_ raw: String) -> [String] {
        var out: [String] = []
        let lower = raw.lowercased()

        if lower.range(of: #"^\d+(\.\d+)?u$"#, options: .regularExpression) != nil {
            out.append(raw + "F")
            out.append(raw + "f")
        }
        if lower.range(of: #"^\d+(\.\d+)?n$"#, options: .regularExpression) != nil {
            out.append(raw + "F")
            out.append(raw + "f")
        }
        if lower.range(of: #"^\d+(\.\d+)?p$"#, options: .regularExpression) != nil {
            out.append(raw + "F")
            out.append(raw + "f")
        }
        if lower.range(of: #"^\d+(\.\d+)?m$"#, options: .regularExpression) != nil {
            out.append(raw + "F")
            out.append(raw + "f")
        }
        if lower.range(of: #"^\d+(\.\d+)?u[fF]?$"#, options: .regularExpression) != nil,
           !lower.hasSuffix("f") {
            out.append(raw + "F")
        }

        return out
    }

    private static func expandResistance(_ raw: String) -> [String] {
        var out: [String] = []
        let lower = raw.lowercased()

        if lower.range(of: #"^\d+k$"#, options: .regularExpression) != nil {
            out.append(raw + "Ω")
            out.append(raw + " Ohm")
        }
        if lower.range(of: #"^\d+m$"#, options: .regularExpression) != nil {
            out.append(raw + "Ω")
        }
        if lower.range(of: #"^\d+$"#, options: .regularExpression) != nil,
           let value = Double(raw), value >= 1000, value.truncatingRemainder(dividingBy: 1000) == 0 {
            out.append("\(Int(value / 1000))kΩ")
        }
        if let match = lower.range(of: #"^\d+k\d+$"#, options: .regularExpression) {
            let token = String(lower[match])
            if let regex = try? NSRegularExpression(pattern: #"^(\d+)k(\d+)$"#),
               let found = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
               let whole = Range(found.range(at: 1), in: token),
               let frac = Range(found.range(at: 2), in: token) {
                out.append("\(token[whole]).\(token[frac])kΩ")
            }
        }

        return out
    }

    private static func expandInductance(_ raw: String) -> [String] {
        var out: [String] = []
        let lower = raw.lowercased()

        if lower.range(of: #"^\d+(\.\d+)?u$"#, options: .regularExpression) != nil {
            out.append(raw + "H")
            out.append(raw + "h")
        }
        if lower.range(of: #"^\d+(\.\d+)?n$"#, options: .regularExpression) != nil {
            out.append(raw + "H")
        }
        if lower.range(of: #"^\d+(\.\d+)?m$"#, options: .regularExpression) != nil {
            out.append(raw + "H")
        }

        return out
    }
}
