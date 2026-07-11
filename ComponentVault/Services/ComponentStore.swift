import Foundation
import SwiftData

@MainActor
@Observable
final class ComponentStore {
    private let modelContext: ModelContext
    private let lcscProvider = LCSCProvider()

    var isLoading = false
    var statusMessage: String?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func upsert(records: [ComponentRecord], preserveLocalQuantity: Bool = true) throws {
        for record in records {
            let descriptor = FetchDescriptor<Component>(
                predicate: #Predicate { $0.lcscCode == record.lcscCode }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                let savedQty = existing.quantity
                existing.apply(record, preserveQuantity: preserveLocalQuantity)
                if preserveLocalQuantity && record.quantity == 0 && savedQty > 0 {
                    existing.quantity = savedQty
                }
            } else {
                modelContext.insert(Component(
                    lcscCode: record.lcscCode,
                    mpn: record.mpn,
                    name: record.name,
                    componentDescription: record.description,
                    footprint: record.footprint,
                    quantity: record.quantity,
                    category: record.category,
                    value: record.value,
                    brand: record.brand,
                    datasheetURL: record.datasheetURL,
                    imageURLs: record.imageURLs,
                    price: record.price,
                    currency: record.currency,
                    supplierStock: record.supplierStock,
                    dataSource: record.dataSource,
                    digikeyPartNumber: record.digikeyPartNumber,
                    supplierProductURL: record.supplierProductURL,
                    priceBreaksJSON: PriceBreakCodec.encode(record.priceBreaks),
                    minimumOrderQuantity: record.minimumOrderQuantity,
                    leadTimeWeeks: record.leadTimeWeeks,
                    digikeyProductStatus: record.digikeyProductStatus,
                    digikeyLastFetched: record.digikeyLastFetched.flatMap {
                        ISO8601DateFormatter().date(from: $0)
                    },
                    lcscSnapshotJSON: SupplierSnapshotCodec.encode(record.lcscSnapshot),
                    digikeySnapshotJSON: SupplierSnapshotCodec.encode(record.digikeySnapshot),
                    parameters: record.parameters.map { ComponentParameter(name: $0.key, value: $0.value) }
                ))
            }
        }
        try modelContext.save()
    }

    func bootstrapFromDefaultLocation() async throws -> DatabaseBootstrap.Result {
        isLoading = true
        defer { isLoading = false }

        let records = try DatabaseBootstrap.loadDefaultRecords()
        guard !records.isEmpty else {
            throw DatabaseBootstrap.BootstrapError.emptyDatabase
        }
        try upsert(records: records)
        let source = DatabaseBootstrap.describeSource()
        statusMessage = "Database creato: \(records.count) componenti da \(source)"
        return DatabaseBootstrap.Result(imported: records.count, source: source)
    }

    func importCSV(from url: URL) async throws {
        isLoading = true
        defer { isLoading = false }

        let records: [ComponentRecord]
        if url.lastPathComponent.lowercased().contains("riepilogo") ||
            url.deletingPathExtension().lastPathComponent.lowercased().contains("bom") {
            records = try CSVImporter.importEnrichedBOM(from: url)
        } else {
            records = try CSVImporter.importInventory(from: url)
        }

        try upsert(records: records)
        statusMessage = "Importati \(records.count) componenti da \(url.lastPathComponent)"
    }

    func enrichFromLCSC(_ component: Component) async throws {
        isLoading = true
        defer { isLoading = false }

        let record = try await lcscProvider.fetch(lcscCode: component.lcscCode)
        component.applyLCSC(record, preserveQuantity: true)
        try modelContext.save()
        statusMessage = "Aggiornato \(component.lcscCode) da LCSC"
    }

    func enrichAllFromLCSC(
        components: [Component],
        delayMs: Int = 800,
        progress: ((Int, Int) -> Void)? = nil
    ) async {
        isLoading = true
        defer { isLoading = false }

        let total = components.count
        for (index, component) in components.enumerated() {
            progress?(index + 1, total)
            do {
                try await enrichFromLCSC(component)
                try await Task.sleep(for: .milliseconds(delayMs))
            } catch {
                statusMessage = "Errore su \(component.lcscCode): \(error.localizedDescription)"
            }
        }
        statusMessage = "Arricchimento LCSC completato (\(total) componenti)"
    }

    func enrichFromDigiKey(_ component: Component) async throws -> DigiKeyEnrichResult {
        guard let provider = DigiKeyProvider.configured() else {
            throw ProviderError.networkFailure(
                "DigiKey non configurato. Autenticati da Impostazioni → DigiKey."
            )
        }
        guard !component.mpn.isEmpty else {
            throw ProviderError.invalidCode
        }

        isLoading = true
        defer { isLoading = false }

        return try await resolveDigiKeyEnrichment(provider: provider, component: component)
    }

    private func resolveDigiKeyEnrichment(
        provider: DigiKeyProvider,
        component: Component
    ) async throws -> DigiKeyEnrichResult {
        let candidates = try await provider.searchCandidates(
            mpn: component.mpn,
            lcscCode: component.lcscCode
        )

        if candidates.count == 1 {
            try await applyDigiKeyRecord(candidates[0].record, to: component, provider: provider)
            return .applied
        }

        let exact = candidates.filter {
            $0.mpn.caseInsensitiveCompare(component.mpn) == .orderedSame
        }
        if exact.count == 1 {
            try await applyDigiKeyRecord(exact[0].record, to: component, provider: provider)
            return .applied
        }

        return .chooseCandidate(candidates)
    }

    func applyDigiKeyRecord(
        _ record: ComponentRecord,
        to component: Component,
        provider: DigiKeyProvider? = nil
    ) async throws {
        let activeProvider = provider ?? DigiKeyProvider.configured()
        var merged = record
        merged.quantity = component.quantity

        if let activeProvider {
            merged = try await activeProvider.enrichRecord(merged)
        }

        component.applyDigiKey(merged)
        try modelContext.save()
        statusMessage = "Aggiornato \(component.mpn) da DigiKey"
    }

    func enrichFromBoth(_ component: Component) async throws -> DigiKeyEnrichResult {
        isLoading = true
        defer { isLoading = false }

        let record = try await lcscProvider.fetch(lcscCode: component.lcscCode)
        component.applyLCSC(record, preserveQuantity: true)

        guard !component.mpn.isEmpty else {
            try modelContext.save()
            statusMessage = "LCSC aggiornato — serve MPN per DigiKey"
            return .applied
        }

        guard let provider = DigiKeyProvider.configured() else {
            try modelContext.save()
            statusMessage = "LCSC aggiornato — DigiKey non configurato"
            return .applied
        }

        let result = try await resolveDigiKeyEnrichment(provider: provider, component: component)
        statusMessage = "Aggiornati LCSC + DigiKey per \(component.lcscCode)"
        return result
    }

    func enrichAllFromDigiKey(
        components: [Component],
        delayMs: Int = 800,
        progress: ((Int, Int) -> Void)? = nil
    ) async -> (enriched: Int, skipped: Int, ambiguous: Int) {
        guard let provider = DigiKeyProvider.configured() else {
            statusMessage = "DigiKey non configurato. Autenticati da Impostazioni."
            return (0, components.count, 0)
        }

        isLoading = true
        defer { isLoading = false }

        let eligible = components.filter { !$0.mpn.isEmpty }
        let total = eligible.count
        var enriched = 0
        var skipped = 0
        var ambiguous = 0

        for (index, component) in eligible.enumerated() {
            progress?(index + 1, total)
            do {
                switch try await resolveDigiKeyEnrichment(provider: provider, component: component) {
                case .applied:
                    enriched += 1
                case .chooseCandidate:
                    ambiguous += 1
                }
                try await Task.sleep(for: .milliseconds(delayMs))
            } catch {
                skipped += 1
                statusMessage = "Errore su \(component.lcscCode): \(error.localizedDescription)"
            }
        }

        statusMessage = "DigiKey: \(enriched) aggiornati, \(ambiguous) ambigui, \(skipped) errori"
        return (enriched, skipped, ambiguous)
    }

    func updateQuantity(_ component: Component, to quantity: Int) throws {
        let delta = quantity - component.quantity
        try adjustStock(component, delta: delta, reason: .manual, note: "Aggiornamento manuale")
    }

    func adjustStock(
        _ component: Component,
        delta: Int,
        reason: StockMovementReason = .manual,
        note: String = ""
    ) throws {
        let newQuantity = max(0, component.quantity + delta)
        component.quantity = newQuantity
        component.lastUpdated = Date()

        let movement = StockMovement(
            delta: delta,
            quantityAfter: newQuantity,
            reason: reason,
            note: note,
            component: component
        )
        component.stockMovements.insert(movement, at: 0)
        modelContext.insert(movement)
        try modelContext.save()
    }

    func updateMinQuantity(_ component: Component, to minQuantity: Int) throws {
        component.minQuantity = max(0, minQuantity)
        component.lastUpdated = Date()
        try modelContext.save()
    }

    func updateTags(_ component: Component, tags: [String]) throws {
        component.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        component.lastUpdated = Date()
        try modelContext.save()
    }

    func updateNotes(_ component: Component, notes: String) throws {
        component.notes = notes
        component.lastUpdated = Date()
        try modelContext.save()
    }

    func lowStockComponents(from components: [Component]) -> [Component] {
        components.filter(\.isLowStock).sorted { lhs, rhs in
            if lhs.quantity == rhs.quantity { return lhs.lcscCode < rhs.lcscCode }
            return lhs.quantity < rhs.quantity
        }
    }

    func pushToRemote(config: RemoteAPIConfig) async throws -> Int {
        isLoading = true
        defer { isLoading = false }

        let descriptor = FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)])
        let components = try modelContext.fetch(descriptor)
        let records = components.map { $0.toRecord() }
        let upserted = try await RemoteAPIClient.pushComponents(records, config: config)
        statusMessage = "Caricati \(upserted) componenti sul server"
        return upserted
    }

    func pullFromRemote(config: RemoteAPIConfig) async throws -> Int {
        isLoading = true
        defer { isLoading = false }

        let records = try await RemoteAPIClient.fetchComponents(config: config)
        try upsert(records: records, preserveLocalQuantity: false)
        statusMessage = "Scaricati \(records.count) componenti dal server"
        return records.count
    }

    func syncBidirectional(config: RemoteAPIConfig) async throws -> SyncBidirectionalResult {
        isLoading = true
        defer { isLoading = false }

        let remoteRecords = try await RemoteAPIClient.fetchComponents(config: config)
        let remoteByCode = Dictionary(uniqueKeysWithValues: remoteRecords.map { ($0.lcscCode, $0) })

        let descriptor = FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)])
        let localComponents = try modelContext.fetch(descriptor)
        let localByCode = Dictionary(uniqueKeysWithValues: localComponents.map { ($0.lcscCode, $0) })

        var toPush: [ComponentRecord] = []
        var pulled = 0
        var unchanged = 0

        for (code, local) in localByCode {
            let localRecord = local.toRecord()
            if let remote = remoteByCode[code] {
                let localDate = local.lastUpdated
                let remoteDate = SyncDateParser.parse(remote.updatedAt)
                if localDate > remoteDate.addingTimeInterval(1) {
                    toPush.append(localRecord)
                } else if remoteDate > localDate.addingTimeInterval(1) {
                    local.apply(remote, preserveQuantity: false)
                    pulled += 1
                } else {
                    unchanged += 1
                }
            } else {
                toPush.append(localRecord)
            }
        }

        for (code, remote) in remoteByCode where localByCode[code] == nil {
            try upsert(records: [remote], preserveLocalQuantity: false)
            pulled += 1
        }

        let pushed = toPush.isEmpty ? 0 : try await RemoteAPIClient.pushComponents(toPush, config: config)
        try modelContext.save()

        let result = SyncBidirectionalResult(pushed: pushed, pulled: pulled, unchanged: unchanged)
        statusMessage = result.summary
        return result
    }
}
