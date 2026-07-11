import Foundation

enum CatalogSearchService {
    /// Flusso progettazione: DigiKey (tipo+valore+footprint) → MPN → LCSC per codice C.
    static func search(
        query: CatalogSearchQuery,
        inventory: [Component],
        digiKeyLimit: Int = 8
    ) async throws -> [CatalogMatchCard] {
        guard !query.isEmpty else { return [] }

        guard let provider = DigiKeyProvider.configured() else {
            throw ProviderError.networkFailure(
                "DigiKey non configurato. Autenticati da Impostazioni → DigiKey."
            )
        }

        let digikeyCandidates = try await provider.searchCatalog(
            keyword: query.digiKeyKeyword(),
            recordCount: digiKeyLimit
        )

        guard !digikeyCandidates.isEmpty else { return [] }

        var cards: [CatalogMatchCard] = []
        for candidate in digikeyCandidates {
            let mpn = candidate.mpn.trimmingCharacters(in: .whitespacesAndNewlines)
            var lcscRecord: ComponentRecord?

            if !mpn.isEmpty {
                let lcscHits = try await LCSCCatalogProvider.searchByMPN(mpn, limit: 5)
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

        return cards.sorted { lhs, rhs in
            if lhs.hasBothCodes != rhs.hasBothCodes { return lhs.hasBothCodes }
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

        if let footprintMatch = pool.first(where: { record in
            CatalogMatchNormalizer.matches(
                recordType: ComponentType.from(category: record.category),
                recordValue: displayValue(from: record),
                recordFootprint: displayFootprint(from: record),
                query: query
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
        let value = query.value.isEmpty
            ? displayValue(from: lcsc ?? digikey.record)
            : query.value
        let footprint = query.footprint.isEmpty
            ? displayFootprint(from: lcsc ?? digikey.record)
            : query.footprint

        let lcscCode = lcsc?.lcscCode
        let inventoryItem = lcscCode.flatMap { code in
            inventory.first { $0.lcscCode == code }
        }

        let cardID = [
            lcscCode ?? "",
            digikey.digikeyPartNumber,
            CatalogMatchNormalizer.mpn(digikey.mpn),
        ].joined(separator: "|")

        return CatalogMatchCard(
            id: cardID.isEmpty ? UUID().uuidString : cardID,
            type: query.type,
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
            lcscSource: nil
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
