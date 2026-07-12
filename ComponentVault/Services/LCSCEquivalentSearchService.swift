import Foundation

enum LCSCEquivalentSearchService {
    struct SearchResult: Sendable {
        let keyword: String
        let cards: [CatalogMatchCard]
        let totalFound: Int
    }

    /// Costruisce una keyword LCSC dalle specifiche del componente (footprint, valore, dielettrico, tensione…).
    static func keyword(for component: Component) -> String? {
        var parts: [String] = []

        let footprint = CatalogMatchNormalizer.footprintToken(component.displayFootprint)
        if !footprint.isEmpty {
            parts.append(footprint)
        }

        let value = component.displayValue
        if value != "—", value != "N/A" {
            parts.append(normalizeValueToken(value))
        }

        let extraKeys = [
            "Voltage - Rated",
            "Voltage Rated",
            "Rated Voltage",
            "Dielectric",
            "Tolerance",
            "Temperature Coefficient",
        ]
        for key in extraKeys {
            guard let param = component.parameters.first(where: { $0.name == key }),
                  !param.value.isEmpty else { continue }
            let token = normalizeValueToken(param.value)
            guard !token.isEmpty, !parts.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) else {
                continue
            }
            parts.append(token)
        }

        guard parts.count >= 2 else { return nil }
        return parts.joined(separator: " ")
    }

    static func search(
        component: Component,
        inventory: [Component],
        limit: Int = 12
    ) async throws -> SearchResult {
        guard let keyword = keyword(for: component) else {
            throw ProviderError.networkFailure(
                "Specifiche insufficienti per la ricerca (servono almeno footprint e valore)."
            )
        }

        let encap = CatalogMatchNormalizer.footprintToken(component.displayFootprint)
        let records = try await LCSCCatalogProvider.searchEquivalents(
            keyword: keyword,
            encap: encap.isEmpty ? nil : encap,
            limit: limit
        )

        let cards = records.map { record in
            makeCard(record: record, component: component, inventory: inventory)
        }

        return SearchResult(
            keyword: keyword,
            cards: cards,
            totalFound: cards.count
        )
    }

    private static func makeCard(
        record: ComponentRecord,
        component: Component,
        inventory: [Component]
    ) -> CatalogMatchCard {
        let type = component.componentType
        let inventoryItem = inventory.first { $0.lcscCode == record.lcscCode }
        let cardID = [
            record.lcscCode,
            CatalogMatchNormalizer.mpn(record.mpn),
            "equivalent",
        ].joined(separator: "|")

        return CatalogMatchCard(
            id: cardID,
            type: type,
            value: component.displayValue,
            footprint: component.displayFootprint,
            mpn: record.mpn,
            description: record.description,
            brand: record.brand,
            lcscCode: record.lcscCode,
            lcscPrice: record.price,
            lcscCurrency: record.currency,
            lcscStock: record.supplierStock,
            lcscURL: record.supplierProductURL,
            digikeyPartNumber: component.digikeyPartNumber,
            digikeyPrice: component.digikeyUnitPriceForInventory,
            digikeyCurrency: component.currency,
            digikeyStock: component.supplierStock,
            digikeyURL: component.digikeySnapshot?.productURL ?? component.supplierProductURL,
            inInventory: inventoryItem != nil,
            inventoryQuantity: inventoryItem?.quantity,
            digikeyRecord: nil,
            lcscRecord: record,
            lcscSource: .live
        )
    }

    private static func normalizeValueToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "Ω", with: "ohm")
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "μ", with: "u")
    }
}
