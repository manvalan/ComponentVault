import Foundation

/// Ricerca nel catalogo LCSC locale (inventario + archivio json_full_data): tipo, valore, package.
/// Nessuna ricerca live: l'API web di LCSC non è pubblica e richiede cifratura SM2.
enum LCSCCatalogSearchService {
    static func search(
        query: CatalogSearchQuery,
        inventory: [Component],
        limit: Int = 25
    ) async throws -> [CatalogMatchCard] {
        collectCards(query: query, inventory: inventory, limit: limit)
    }

    static func searchByKeyword(
        query: CatalogSearchQuery,
        inventory: [Component],
        limit: Int = 25
    ) async throws -> [CatalogMatchCard] {
        collectCards(query: query, inventory: inventory, limit: limit)
    }

    private static func collectCards(
        query: CatalogSearchQuery,
        inventory: [Component],
        limit: Int
    ) -> [CatalogMatchCard] {
        var entries: [(ComponentRecord, LCSCMatchSource)] = []
        var seen = Set<String>()

        func append(_ record: ComponentRecord, source: LCSCMatchSource) {
            guard LCSCCode.isValid(record.lcscCode), seen.insert(record.lcscCode).inserted else { return }
            entries.append((record, source))
        }

        for record in LCSCArchiveSearcher.search(query: query, inventory: inventory, limit: limit) {
            let source: LCSCMatchSource = inventory.contains(where: { $0.lcscCode == record.lcscCode })
                ? .inventory
                : .archive
            append(record, source: source)
        }

        entries.sort { $0.0.lcscCode.localizedStandardCompare($1.0.lcscCode) == .orderedAscending }

        let filtered = entries.filter {
            CatalogMatchNormalizer.matchesBrand(recordBrand: $0.0.brand, queryBrand: query.brand)
        }

        return filtered.prefix(limit).map { item in
            makeCard(record: item.0, query: query, source: item.1, inventory: inventory)
        }
    }

    private static func makeCard(
        record: ComponentRecord,
        query: CatalogSearchQuery,
        source: LCSCMatchSource,
        inventory: [Component]
    ) -> CatalogMatchCard {
        let type = ComponentType.from(category: record.category)
        let value = displayValue(from: record, fallback: query.value)
        let footprint = displayFootprint(from: record, fallback: query.footprint)
        let inventoryItem = inventory.first {
            $0.lcscCode == record.lcscCode
                || $0.lcscSupplierCode?.uppercased() == record.lcscCode.uppercased()
        }

        let cardID = [record.lcscCode, CatalogMatchNormalizer.mpn(record.mpn), source.rawValue]
            .joined(separator: "|")

        return CatalogMatchCard(
            id: cardID,
            type: type,
            value: value,
            footprint: footprint,
            mpn: record.mpn,
            description: record.description,
            brand: record.brand,
            lcscCode: record.lcscCode,
            lcscPrice: record.price,
            lcscCurrency: record.currency,
            lcscStock: record.supplierStock,
            lcscURL: record.supplierProductURL
                ?? "https://www.lcsc.com/product-detail/\(record.lcscCode).html",
            inInventory: inventoryItem != nil,
            inventoryQuantity: inventoryItem?.quantity,
            lcscRecord: record,
            lcscSource: source
        )
    }

    private static func displayValue(from record: ComponentRecord, fallback: String) -> String {
        if !record.value.isEmpty && record.value != "N/A" { return record.value }
        for key in ["Resistance", "Capacitance", "Inductance", "Voltage - Rated"] {
            if let value = record.parameters[key], !value.isEmpty { return value }
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private static func displayFootprint(from record: ComponentRecord, fallback: String) -> String {
        if !record.footprint.isEmpty { return record.footprint }
        if let pkg = record.parameters["Package"] ?? record.parameters["Package / Case"], !pkg.isEmpty {
            return pkg
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}
