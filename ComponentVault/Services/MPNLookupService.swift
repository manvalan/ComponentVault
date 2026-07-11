import Foundation

enum LCSCMatchSource: String, Sendable {
    case inventory
    case archive
    case live
}

enum MPNLookupService {
    struct LookupStats: Sendable {
        let archiveCount: Int
        let liveCount: Int
        let digikeyFound: Bool
    }

    /// Cerca il codice LCSC (Cxxxxx) a partire da un MPN.
    /// Ordine: inventario → archivio JSON locale → API LCSC live → DigiKey (opzionale).
    static func search(
        mpn rawMPN: String,
        inventory: [Component],
        includeDigiKey: Bool = true
    ) async throws -> (cards: [CatalogMatchCard], stats: LookupStats) {
        let mpn = rawMPN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mpn.isEmpty else { return ([], LookupStats(archiveCount: 0, liveCount: 0, digikeyFound: false)) }

        var records: [(record: ComponentRecord, source: LCSCMatchSource)] = []
        var seen = Set<String>()

        func append(_ record: ComponentRecord?, source: LCSCMatchSource) {
            guard let record, seen.insert(record.lcscCode).inserted else { return }
            records.append((record, source))
        }

        for hit in LCSCArchiveSearcher.searchByMPN(mpn, inventory: inventory, limit: 12) {
            let source: LCSCMatchSource
            if inventory.contains(where: { $0.lcscCode == hit.lcscCode }) {
                source = .inventory
            } else {
                source = .archive
            }
            append(hit, source: source)
        }

        let archiveCount = records.filter { $0.source == .archive || $0.source == .inventory }.count

        var liveCount = 0
        do {
            let liveHits = try await LCSCCatalogProvider.searchByMPN(mpn, limit: 8)
            for hit in liveHits {
                if seen.insert(hit.lcscCode).inserted {
                    records.append((hit, .live))
                    liveCount += 1
                }
            }
        } catch {
            if records.isEmpty { throw error }
        }

        records.sort { lhs, rhs in
            let leftExact = CatalogMatchNormalizer.mpn(lhs.record.mpn) == CatalogMatchNormalizer.mpn(mpn)
            let rightExact = CatalogMatchNormalizer.mpn(rhs.record.mpn) == CatalogMatchNormalizer.mpn(mpn)
            if leftExact != rightExact { return leftExact }
            return lhs.record.lcscCode < rhs.record.lcscCode
        }

        var digikeyCandidate: DigiKeyCandidate?
        if includeDigiKey, let provider = DigiKeyProvider.configured() {
            if let candidates = try? await provider.searchCandidates(
                mpn: mpn,
                lcscCode: "MPN-LOOKUP",
                recordCount: 5
            ) {
                digikeyCandidate = pickBestDigiKey(candidates, mpn: mpn)
            }
        }

        if records.isEmpty, let digikey = digikeyCandidate {
            let card = makeCard(
                mpn: mpn,
                lcsc: nil,
                lcscSource: nil,
                digikey: digikey,
                inventory: inventory
            )
            return (
                [card],
                LookupStats(archiveCount: 0, liveCount: 0, digikeyFound: true)
            )
        }

        let cards = records.map { item in
            makeCard(
                mpn: mpn,
                lcsc: item.record,
                lcscSource: item.source,
                digikey: digikeyCandidate,
                inventory: inventory
            )
        }

        return (
            cards,
            LookupStats(
                archiveCount: archiveCount,
                liveCount: liveCount,
                digikeyFound: digikeyCandidate != nil
            )
        )
    }

    private static func pickBestDigiKey(_ candidates: [DigiKeyCandidate], mpn: String) -> DigiKeyCandidate? {
        guard !candidates.isEmpty else { return nil }
        let target = CatalogMatchNormalizer.mpn(mpn)
        if let exact = candidates.first(where: { CatalogMatchNormalizer.mpn($0.mpn) == target }) {
            return exact
        }
        return candidates.first
    }

    private static func makeCard(
        mpn: String,
        lcsc: ComponentRecord?,
        lcscSource: LCSCMatchSource?,
        digikey: DigiKeyCandidate?,
        inventory: [Component]
    ) -> CatalogMatchCard {
        let type = ComponentType.from(category: lcsc?.category ?? digikey?.record.category ?? "")
        let value = displayValue(from: lcsc ?? digikey?.record)
        let footprint = displayFootprint(from: lcsc ?? digikey?.record)
        let lcscCode = lcsc?.lcscCode
        let inventoryItem = lcscCode.flatMap { code in
            inventory.first { $0.lcscCode == code }
        }

        let cardID = [
            lcscCode ?? "",
            digikey?.digikeyPartNumber ?? "",
            CatalogMatchNormalizer.mpn(mpn),
            lcscSource?.rawValue ?? "",
        ].joined(separator: "|")

        return CatalogMatchCard(
            id: cardID.isEmpty ? UUID().uuidString : cardID,
            type: type,
            value: value,
            footprint: footprint,
            mpn: lcsc?.mpn.isEmpty == false ? lcsc!.mpn : (digikey?.mpn ?? mpn),
            description: lcsc?.description ?? digikey?.description ?? "",
            brand: lcsc?.brand ?? digikey?.manufacturer ?? "",
            lcscCode: lcscCode,
            lcscPrice: lcsc?.price,
            lcscCurrency: lcsc?.currency,
            lcscStock: lcsc?.supplierStock,
            lcscURL: lcsc?.supplierProductURL
                ?? lcscCode.map { "https://www.lcsc.com/product-detail/\($0).html" },
            digikeyPartNumber: digikey?.digikeyPartNumber,
            digikeyPrice: digikey?.unitPrice,
            digikeyCurrency: digikey?.currency,
            digikeyStock: digikey?.stock,
            digikeyURL: digikey?.productURL,
            inInventory: inventoryItem != nil,
            inventoryQuantity: inventoryItem?.quantity,
            digikeyRecord: digikey?.record,
            lcscRecord: lcsc,
            lcscSource: lcscSource
        )
    }

    private static func displayValue(from record: ComponentRecord?) -> String {
        guard let record else { return "—" }
        if !record.value.isEmpty && record.value != "N/A" { return record.value }
        for key in ["Resistance", "Capacitance", "Inductance", "Voltage - Rated"] {
            if let value = record.parameters[key], !value.isEmpty { return value }
        }
        return "—"
    }

    private static func displayFootprint(from record: ComponentRecord?) -> String {
        guard let record else { return "—" }
        if !record.footprint.isEmpty { return record.footprint }
        return record.parameters["Package"] ?? record.parameters["Package / Case"] ?? "—"
    }
}
