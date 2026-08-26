import Foundation

enum CatalogSearchService {
    private static let defaultLimit = 25

    /// Ricerca catalogo DigiKey (+ risoluzione LCSC opzionale per codice C).
    static func search(
        query: CatalogSearchQuery,
        inventory: [Component],
        limit: Int = defaultLimit
    ) async throws -> [CatalogMatchCard] {
        let trimmedValue = query.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFootprint = query.footprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty || !trimmedFootprint.isEmpty else {
            throw ProviderError.networkFailure("Imposta almeno valore o footprint.")
        }

        guard let provider = DigiKeyProvider.configured() else {
            throw ProviderError.networkFailure(
                "DigiKey non configurato. Autenticati da Impostazioni → DigiKey."
            )
        }

        let keyword = query.digiKeySearchKeyword()
        let candidates = try await provider.searchCatalog(
            keyword: keyword,
            recordCount: limit
        )

        return try await cards(
            from: candidates,
            query: query,
            inventory: inventory
        )
    }

    /// Ricerca diretta per MPN / part number su DigiKey.
    static func searchMPN(
        _ mpn: String,
        inventory: [Component],
        limit: Int = defaultLimit
    ) async throws -> [CatalogMatchCard] {
        guard let provider = DigiKeyProvider.configured() else {
            throw ProviderError.networkFailure(
                "DigiKey non configurato. Autenticati da Impostazioni → DigiKey."
            )
        }

        let trimmed = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let candidates = try await provider.searchCatalog(
            keyword: trimmed,
            recordCount: limit
        )

        var query = CatalogSearchQuery()
        query.valueAmount = trimmed
        query.type = nil

        return try await cards(
            from: candidates,
            query: query,
            inventory: inventory
        )
    }

    private static func cards(
        from candidates: [DigiKeyCandidate],
        query: CatalogSearchQuery,
        inventory: [Component]
    ) async throws -> [CatalogMatchCard] {
        guard !candidates.isEmpty else { return [] }

        var cards: [CatalogMatchCard] = []
        for candidate in candidates {
            let mpn = candidate.mpn.trimmingCharacters(in: .whitespacesAndNewlines)
            var lcscRecord: ComponentRecord?

            if !mpn.isEmpty {
                let lcscHits = (try? await LCSCCatalogProvider.searchByMPN(mpn, limit: 5)) ?? []
                lcscRecord = pickBestLCSC(lcscHits, query: query, mpn: mpn)
            }

            cards.append(
                makeCard(
                    query: query,
                    digikey: candidate,
                    lcsc: lcscRecord,
                    inventory: inventory
                )
            )
        }

        let filtered = cards.filter {
            CatalogMatchNormalizer.matchesBrand(recordBrand: $0.brand, queryBrand: query.brand)
        }

        return filtered.sorted { lhs, rhs in
            if lhs.hasBothCodes != rhs.hasBothCodes { return lhs.hasBothCodes }
            if lhs.hasDigiKey != rhs.hasDigiKey { return lhs.hasDigiKey }
            return lhs.mpn.localizedStandardCompare(rhs.mpn) == .orderedAscending
        }
    }

    private static func pickBestLCSC(
        _ records: [ComponentRecord],
        query: CatalogSearchQuery,
        mpn: String
    ) -> ComponentRecord? {
        guard !records.isEmpty else { return nil }

        let exact = records.filter {
            CatalogMatchNormalizer.mpn($0.mpn) == CatalogMatchNormalizer.mpn(mpn)
        }
        let pool = exact.isEmpty ? records : exact

        if query.isKeywordQuery {
            return pool.first
        }

        if let footprintMatch = pool.first(where: { record in
            CatalogMatchNormalizer.matches(
                recordType: ComponentType.from(category: record.category),
                recordValue: displayValue(from: record),
                recordFootprint: displayFootprint(from: record),
                query: query,
                record: record
            )
        }) {
            return footprintMatch
        }

        return pool.first
    }

    private static func makeCard(
        query: CatalogSearchQuery,
        digikey: DigiKeyCandidate,
        lcsc: ComponentRecord?,
        inventory: [Component]
    ) -> CatalogMatchCard {
        let resolvedType = lcsc.map { ComponentType.from(category: $0.category) }
            ?? ComponentType.from(category: digikey.record.category)
        let cardType = (query.type == nil) ? resolvedType : query.resolvedType

        let value = query.value.isEmpty
            ? displayValue(from: lcsc ?? digikey.record)
            : query.value
        let footprint = query.footprint.isEmpty
            ? displayFootprint(from: lcsc ?? digikey.record)
            : query.footprint

        let lcscCode = lcsc?.lcscCode
        let inventoryItem = inventory.first {
            if let lcscCode, $0.lcscCode == lcscCode { return true }
            let dk = digikey.digikeyPartNumber
            if !dk.isEmpty, $0.digikeyPartNumber == dk { return true }
            return CatalogMatchNormalizer.mpn($0.mpn) == CatalogMatchNormalizer.mpn(digikey.mpn)
        }

        let cardID = [
            lcscCode ?? "",
            digikey.digikeyPartNumber,
            CatalogMatchNormalizer.mpn(digikey.mpn),
        ].joined(separator: "|")

        return CatalogMatchCard(
            id: cardID.isEmpty ? UUID().uuidString : cardID,
            type: cardType,
            value: value,
            footprint: footprint,
            mpn: digikey.mpn,
            description: lcsc?.description ?? digikey.description,
            brand: lcsc?.brand ?? digikey.manufacturer,
            lcscCode: lcscCode,
            lcscPrice: lcsc?.price,
            lcscCurrency: lcsc?.currency,
            lcscStock: lcsc?.supplierStock,
            lcscURL: lcsc?.supplierProductURL
                ?? lcscCode.map { "https://www.lcsc.com/product-detail/\($0).html" },
            digikeyPartNumber: digikey.digikeyPartNumber,
            digikeyPrice: digikey.unitPrice,
            digikeyCurrency: digikey.currency,
            digikeyStock: digikey.stock,
            digikeyURL: digikey.productURL,
            inInventory: inventoryItem != nil,
            inventoryQuantity: inventoryItem?.quantity,
            digikeyRecord: digikey.record,
            lcscRecord: lcsc,
            lcscSource: lcsc == nil ? nil : .live
        )
    }

    private static func displayValue(from record: ComponentRecord) -> String {
        if !record.value.isEmpty && record.value != "N/A" { return record.value }
        for key in ["Resistance", "Capacitance", "Inductance", "Voltage - Rated"] {
            if let value = record.parameters[key], !value.isEmpty { return value }
        }
        return "—"
    }

    private static func displayFootprint(from record: ComponentRecord) -> String {
        if !record.footprint.isEmpty { return record.footprint }
        return record.parameters["Package"] ?? record.parameters["Package / Case"] ?? "—"
    }
}
