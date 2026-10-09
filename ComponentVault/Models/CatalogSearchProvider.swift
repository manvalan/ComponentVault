import Foundation

/// Fornitore usato nella sezione Ricerca catalogo (Impostazioni).
enum CatalogSearchProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case lcsc
    case easyeda

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lcsc: "LCSC"
        case .easyeda: "EasyEDA / JLC"
        }
    }

    var detail: String {
        switch self {
        case .lcsc:
            String(localized: "Ricerca parametrica sul catalogo LCSC (archivio locale + live).")
        case .easyeda:
            String(localized: "Stesso catalogo LCSC — ottimizzato per codici Cxxxxx in EasyEDA.")
        }
    }

    var searchButtonTitle: String {
        switch self {
        case .lcsc: String(localized: "Cerca LCSC")
        case .easyeda: String(localized: "Cerca EasyEDA")
        }
    }

    /// EasyEDA usa i codici LCSC — stesso backend parametrico.
    var usesLCSCParametricSearch: Bool {
        self == .lcsc || self == .easyeda
    }
}

enum SupplierCatalogSearchService {
    struct SearchOutcome: Sendable {
        let cards: [CatalogMatchCard]
        let statusMessage: String?
    }

    static func search(
        query: CatalogSearchQuery,
        inventory: [Component],
        provider: CatalogSearchProvider = AppConfigIO.current().catalog.searchProvider
    ) async throws -> SearchOutcome {
        let trimmedValue = query.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFootprint = query.footprint.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedFootprint.isEmpty, CatalogSearchQuery.looksLikeMPN(trimmedValue) {
            return try await searchByMPN(trimmedValue, inventory: inventory, provider: provider)
        }

        guard !trimmedValue.isEmpty || !trimmedFootprint.isEmpty else {
            throw ProviderError.networkFailure(String(localized: "Imposta almeno valore o footprint, oppure un MPN nel campo Valore."))
        }

        switch provider {
        case .lcsc, .easyeda:
            let cards: [CatalogMatchCard]
            if query.isKeywordQuery {
                cards = try await LCSCCatalogSearchService.searchByKeyword(
                    query: query,
                    inventory: inventory
                )
            } else {
                cards = try await LCSCCatalogSearchService.search(query: query, inventory: inventory)
            }
            let inStock = cards.filter { ($0.lcscStock ?? 0) > 0 }.count
            let prefix = provider == .easyeda ? "EasyEDA / LCSC" : "LCSC"
            let message = String(localized: "\(cards.count) parti \(prefix) · \(inStock) con stock")
            return SearchOutcome(cards: cards, statusMessage: message)

        }
    }

    private static func searchByMPN(
        _ mpn: String,
        inventory: [Component],
        provider: CatalogSearchProvider
    ) async throws -> SearchOutcome {
        let (cards, stats) = try await MPNLookupService.search(mpn: mpn, inventory: inventory)

        let withLCSC = cards.filter(\.hasLCSC).count
        var parts = [String(localized: "\(withLCSC) con codice LCSC")]
        if stats.archiveCount > 0 { parts.append("\(stats.archiveCount) da archivio") }
        if stats.liveCount > 0 { parts.append(String(localized: "\(stats.liveCount) da LCSC live")) }
        let prefix = provider.label
        return SearchOutcome(
            cards: cards,
            statusMessage: "\(prefix): " + parts.joined(separator: " · ")
        )
    }
}

extension CatalogSearchQuery {
    /// MPN tipico (es. INA219AIDR) — esclude valori elettrici tipo 10k, 100n, 4k7.
    static func looksLikeMPN(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 6 else { return false }

        if CatalogValueSortKey.parseElectrical(value, for: .other) != nil {
            return false
        }

        let lower = value.lowercased()
        let unitMarkers = ["ohm", "ω", "kω", "mω", "µf", "uf", "nf", "pf", "mh", "uh", "nh"]
        if unitMarkers.contains(where: { lower.contains($0) }) { return false }
        if lower.range(of: #"^\d+(\.\d+)?[kKmMuUnNpP]$"#, options: .regularExpression) != nil {
            return false
        }
        if lower.range(of: #"^\d+k\d+$"#, options: .regularExpression) != nil {
            return false
        }

        let hasLetter = value.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
        let hasDigit = value.range(of: #"\d"#, options: .regularExpression) != nil
        guard hasLetter && hasDigit else { return false }

        if value.contains("-") || value.contains("/") { return true }
        return value.count >= 8
    }
}
