import Foundation

/// Fornitore usato nella sezione Ricerca catalogo (Impostazioni).
enum CatalogSearchProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case lcsc
    case easyeda
    case mouser
    case digikey
    case nexar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lcsc: "LCSC"
        case .easyeda: "EasyEDA / JLC"
        case .mouser: "Mouser"
        case .digikey: "DigiKey"
        case .nexar: "Nexar"
        }
    }

    var detail: String {
        switch self {
        case .lcsc:
            String(localized: "Ricerca nel tuo inventario e nell'archivio LCSC locale.")
        case .easyeda:
            String(localized: "Stesso catalogo LCSC — ottimizzato per codici Cxxxxx in EasyEDA.")
        case .mouser:
            String(localized: "Ricerca, prezzi e disponibilità da Mouser (API ufficiale con la tua chiave).")
        case .digikey:
            String(localized: "Ricerca, prezzi e disponibilità da DigiKey (API ufficiale con le tue credenziali).")
        case .nexar:
            String(localized: "Prezzi e disponibilità di molti distributori autorizzati tramite Nexar (Octopart), con le tue credenziali.")
        }
    }

    var searchButtonTitle: String {
        switch self {
        case .lcsc: String(localized: "Cerca LCSC")
        case .easyeda: String(localized: "Cerca EasyEDA")
        case .mouser: String(localized: "Cerca su Mouser")
        case .digikey: String(localized: "Cerca su DigiKey")
        case .nexar: String(localized: "Cerca su Nexar")
        }
    }

    /// Fornitori utilizzabili ora: l'archivio sempre, Mouser e DigiKey solo con credenziali.
    static var available: [CatalogSearchProvider] {
        allCases.filter { provider in
            switch provider {
            case .lcsc, .easyeda: true
            case .mouser: MouserKeychain.isConfigured
            case .digikey: DigiKeyKeychain.isConfigured
            case .nexar: NexarKeychain.isConfigured
            }
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

        if provider == .mouser || provider == .digikey || provider == .nexar {
            return try await searchSupplier(provider, query: query, inventory: inventory)
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

        case .mouser, .digikey, .nexar:
            return try await searchSupplier(provider, query: query, inventory: inventory)
        }
    }

    private static func searchSupplier(
        _ provider: CatalogSearchProvider,
        query: CatalogSearchQuery,
        inventory: [Component]
    ) async throws -> SearchOutcome {
        let keyword = query.lcscSearchKeywordText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            throw ProviderError.networkFailure(String(localized: "Imposta almeno valore o footprint, oppure un MPN nel campo Valore."))
        }
        let outcome = await SupplierOfferService.search(keyword: keyword, only: provider.label)
        if outcome.offers.isEmpty, let error = outcome.errors.first {
            throw ProviderError.networkFailure(error)
        }
        let cards = offerCards(outcome.offers, query: query, inventory: inventory)
        let inStock = cards.filter { ($0.offer?.stock ?? 0) > 0 }.count
        return SearchOutcome(
            cards: cards,
            statusMessage: String(localized: "\(cards.count) parti \(provider.label) · \(inStock) con stock")
        )
    }

    /// Un MPN si cerca ovunque: archivio LCSC locale e tutti i distributori configurati.
    private static func searchByMPN(
        _ mpn: String,
        inventory: [Component],
        provider: CatalogSearchProvider
    ) async throws -> SearchOutcome {
        async let supplierOutcome = SupplierOfferService.offers(forMPN: mpn)
        let (archiveCards, _) = try await MPNLookupService.search(mpn: mpn, inventory: inventory)
        let suppliers = await supplierOutcome

        let query = CatalogSearchQuery(type: nil, valueAmount: mpn)
        let cards = archiveCards + offerCards(suppliers.offers, query: query, inventory: inventory)

        var parts: [String] = []
        if !archiveCards.isEmpty {
            parts.append(String(localized: "\(archiveCards.count) dall'archivio LCSC"))
        }
        for name in SupplierOfferService.configuredSuppliers {
            let count = suppliers.offers.filter { ($0.source ?? $0.supplier) == name }.count
            if count > 0 { parts.append("\(count) \(name)") }
        }
        parts += suppliers.errors
        if cards.isEmpty, SupplierOfferService.configuredSuppliers.isEmpty {
            parts.append(String(localized: "Non è nell'archivio LCSC locale. Per cercare online inserisci le chiavi Mouser, DigiKey o Nexar in Impostazioni → Fornitori."))
        } else if cards.isEmpty {
            parts.append(String(localized: "Nessun risultato per \(mpn)."))
        }
        return SearchOutcome(cards: cards, statusMessage: parts.joined(separator: " · "))
    }

    private static func offerCards(
        _ offers: [SupplierOffer],
        query: CatalogSearchQuery,
        inventory: [Component]
    ) -> [CatalogMatchCard] {
        offers.map { offer in
            let inventoryItem = inventory.first {
                !offer.mpn.isEmpty && CatalogMatchNormalizer.mpn($0.mpn) == CatalogMatchNormalizer.mpn(offer.mpn)
            }
            return CatalogMatchCard(
                id: "\(offer.supplier)|\(offer.supplierPartNumber)|\(offer.mpn)",
                type: query.type ?? .other,
                value: query.valueDisplayLabel,
                footprint: query.footprint.isEmpty ? "—" : query.footprint,
                mpn: offer.mpn,
                description: offer.description,
                brand: offer.manufacturer,
                lcscCode: nil,
                lcscPrice: nil,
                lcscCurrency: nil,
                lcscStock: nil,
                lcscURL: nil,
                inInventory: inventoryItem != nil,
                inventoryQuantity: inventoryItem?.quantity,
                lcscRecord: nil,
                lcscSource: nil,
                offer: offer
            )
        }
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
