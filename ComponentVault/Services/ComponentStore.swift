import Foundation
import SwiftData

@MainActor
@Observable
final class ComponentStore {
    private let modelContext: ModelContext
    private let lcscProvider = LCSCProvider()

    var isLoading = false
    var statusMessage: String?
    /// Dopo rekey/merge del codice LCSC, la lista deve selezionare questo componente.
    var focusComponent: Component?

    private var statusDismissTask: Task<Void, Never>?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func clearStatus() {
        statusDismissTask?.cancel()
        statusMessage = nil
    }

    func publishStatus(_ message: String?, autoDismissAfter seconds: TimeInterval = 4) {
        statusDismissTask?.cancel()
        statusMessage = message
        guard let message, seconds > 0 else { return }
        statusDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, statusMessage == message else { return }
            statusMessage = nil
        }
    }

    func upsert(records: [ComponentRecord], preserveLocalQuantity: Bool = true) throws {
        guard !records.isEmpty else { return }

        let existing = try modelContext.fetch(FetchDescriptor<Component>())
        var byCode = Dictionary(uniqueKeysWithValues: existing.map { ($0.lcscCode, $0) })

        for record in records {
            if let existing = byCode[record.lcscCode] {
                let savedQty = existing.quantity
                existing.apply(record, preserveQuantity: preserveLocalQuantity)
                if preserveLocalQuantity && record.quantity == 0 && savedQty > 0 {
                    existing.quantity = savedQty
                }
            } else {
                let component = Component(
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
                )
                modelContext.insert(component)
                byCode[record.lcscCode] = component
            }
        }
        try modelContext.save()
    }

    func bootstrapFromDefaultLocation() async throws -> DatabaseBootstrap.Result {
        isLoading = true
        defer { isLoading = false }

        let records = try await Task.detached(priority: .userInitiated) {
            try DatabaseBootstrap.loadDefaultRecords()
        }.value
        guard !records.isEmpty else {
            throw DatabaseBootstrap.BootstrapError.emptyDatabase
        }
        try upsert(records: records)
        let source = DatabaseBootstrap.describeSource()
        publishStatus("Database creato: \(records.count) componenti da \(source)")
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
        publishStatus("Importati \(records.count) componenti da \(url.lastPathComponent)")
    }

    func enrichFromLCSC(_ component: Component) async throws -> Component {
        isLoading = true
        defer { isLoading = false }

        let target = try await resolveAndApplyLCSC(to: component)
        try modelContext.save()
        publishStatus("Aggiornato \(target.lcscCode) da LCSC")
        return target
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
                publishStatus("Errore su \(component.lcscCode): \(error.localizedDescription)", autoDismissAfter: 8)
            }
        }
        publishStatus("Arricchimento LCSC completato (\(total) componenti)")
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

        if component.needsLCSCCodeResolution, !component.mpn.isEmpty,
           let lcscRecord = try await resolveLCSCRecord(forMPN: component.mpn) {
            let target = try assignLCSCCode(to: component, record: lcscRecord)
            target.applyLCSC(lcscRecord, preserveQuantity: true)
        }

        try modelContext.save()
        publishStatus("Aggiornato \(component.mpn) da DigiKey")
    }

    func enrichFromBoth(_ component: Component) async throws -> DigiKeyEnrichResult {
        isLoading = true
        defer { isLoading = false }

        var target = component
        do {
            target = try await resolveAndApplyLCSC(to: component)
        } catch {
            if !component.mpn.isEmpty, let lcscRecord = try? await resolveLCSCRecord(forMPN: component.mpn) {
                target = try assignLCSCCode(to: component, record: lcscRecord)
                target.applyLCSC(lcscRecord, preserveQuantity: true)
            }
        }

        guard !target.mpn.isEmpty else {
            try modelContext.save()
            publishStatus("LCSC aggiornato — serve MPN per DigiKey")
            return .applied
        }

        guard let provider = DigiKeyProvider.configured() else {
            try modelContext.save()
            publishStatus("LCSC aggiornato — DigiKey non configurato")
            return .applied
        }

        let result = try await resolveDigiKeyEnrichment(provider: provider, component: target)
        publishStatus("Aggiornati LCSC + DigiKey per \(target.resolvedLCSCCode)")
        return result
    }

    func enrichAllFromDigiKey(
        components: [Component],
        delayMs: Int = 800,
        progress: ((Int, Int) -> Void)? = nil
    ) async -> (enriched: Int, skipped: Int, ambiguous: Int) {
        guard let provider = DigiKeyProvider.configured() else {
            publishStatus("DigiKey non configurato. Autenticati da Impostazioni.", autoDismissAfter: 8)
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
                publishStatus("Errore su \(component.lcscCode): \(error.localizedDescription)", autoDismissAfter: 8)
            }
        }

        publishStatus("DigiKey: \(enriched) aggiornati, \(ambiguous) ambigui, \(skipped) errori")
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
        clearToOrderTagIfReceived(component)

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

    func assignLCSCFromMPN(_ component: Component) async throws -> Component? {
        guard component.needsLCSCCodeResolution, !component.mpn.isEmpty else { return nil }

        if let recovered = try recoverLCSCCodeFromSnapshot(component) {
            try modelContext.save()
            publishStatus("Codice LCSC recuperato: \(recovered.lcscCode)")
            return recovered
        }

        guard let record = try await resolveLCSCRecord(forMPN: component.mpn) else { return nil }

        let target = try assignLCSCCode(to: component, record: record)
        target.applyLCSC(record, preserveQuantity: true)
        try modelContext.save()
        publishStatus("Codice LCSC assegnato: \(target.lcscCode)")
        return target
    }

    func applyCatalogMatchToExisting(_ component: Component, card: CatalogMatchCard) async throws -> Component {
        isLoading = true
        defer { isLoading = false }

        guard let lcscCode = card.lcscCode, LCSCCode.isValid(lcscCode) else {
            return try await importCatalogMatch(card)
        }

        let inventory = fetchAllComponents()
        let record = card.lcscRecord ?? buildRecord(for: card, lcscCode: lcscCode, inventory: inventory)

        let target = try assignLCSCCode(to: component, record: record)
        target.applyLCSC(record, preserveQuantity: true)

        if let dkRecord = card.digikeyRecord {
            try await applyDigiKeyRecord(dkRecord, to: target)
        } else if card.digikeyPartNumber != nil, let provider = DigiKeyProvider.configured() {
            var dkRecord = record
            dkRecord.dataSource = DataSource.digikey
            try await applyDigiKeyRecord(dkRecord, to: target, provider: provider)
        }

        if target.quantity == 0 {
            markAsToOrder(target)
        }
        try modelContext.save()
        publishStatus("Codice LCSC assegnato: \(target.lcscCode)")
        return target
    }

    func importCatalogMatch(_ card: CatalogMatchCard) async throws -> Component {
        isLoading = true
        defer { isLoading = false }

        let inventory = fetchAllComponents()
        if let realCode = card.lcscCode, realCode.hasPrefix("C"), !card.mpn.isEmpty {
            let targetMPN = CatalogMatchNormalizer.mpn(card.mpn)
            if let dkTwin = inventory.first(where: {
                CatalogMatchNormalizer.mpn($0.mpn) == targetMPN
                    && DigiKeySyntheticCode.isDigiKeyOnly($0.lcscCode)
            }) {
                return try await applyCatalogMatchToExisting(dkTwin, card: card)
            }
        }

        let lcscCode: String
        if let existing = card.lcscCode {
            lcscCode = existing
        } else if let digikeyPN = card.digikeyPartNumber {
            lcscCode = DigiKeySyntheticCode.make(from: digikeyPN)
        } else {
            throw ProviderError.invalidCode
        }

        let record = buildRecord(for: card, lcscCode: lcscCode, inventory: inventory)

        let descriptor = FetchDescriptor<Component>(
            predicate: #Predicate { $0.lcscCode == lcscCode }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            if card.lcscRecord != nil || card.lcscCode != nil {
                existing.applyLCSC(record, preserveQuantity: true)
            }
            if let dkRecord = card.digikeyRecord {
                try await applyDigiKeyRecord(dkRecord, to: existing)
            } else if card.digikeyPartNumber != nil, let provider = DigiKeyProvider.configured() {
                var dkRecord = record
                dkRecord.dataSource = DataSource.digikey
                try await applyDigiKeyRecord(dkRecord, to: existing, provider: provider)
            } else {
                try modelContext.save()
            }
            if existing.quantity == 0 {
                markAsToOrder(existing)
                try modelContext.save()
            }
            publishStatus(
                existing.isToOrder
                    ? "Scheda salvata — da ordinare (\(lcscCode))"
                    : "Aggiornato \(lcscCode)"
            )
            return existing
        }

        try upsert(records: [record], preserveLocalQuantity: true)

        let insertedDescriptor = FetchDescriptor<Component>(
            predicate: #Predicate { $0.lcscCode == lcscCode }
        )
        guard let component = try modelContext.fetch(insertedDescriptor).first else {
            throw ProviderError.networkFailure("Import fallito per \(lcscCode)")
        }

        if let dkRecord = card.digikeyRecord {
            try await applyDigiKeyRecord(dkRecord, to: component)
        } else if card.digikeyPartNumber != nil, let provider = DigiKeyProvider.configured() {
            var dkRecord = record
            dkRecord.dataSource = DataSource.digikey
            try await applyDigiKeyRecord(dkRecord, to: component, provider: provider)
        }

        markAsToOrder(component)
        try modelContext.save()
        publishStatus("Scheda salvata — da ordinare (\(lcscCode))")
        return component
    }

    func importDigiKeyCandidate(_ candidate: DigiKeyCandidate) async throws -> Component {
        guard let provider = DigiKeyProvider.configured() else {
            throw ProviderError.networkFailure("DigiKey non configurato.")
        }

        isLoading = true
        defer { isLoading = false }

        let record = try await provider.importCandidate(candidate)
        let lcscCode = record.lcscCode

        let descriptor = FetchDescriptor<Component>(
            predicate: #Predicate { $0.lcscCode == lcscCode }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            try await applyDigiKeyRecord(record, to: existing, provider: provider)
            if existing.quantity == 0 {
                markAsToOrder(existing)
                try modelContext.save()
            }
            publishStatus(
                existing.isToOrder
                    ? "Scheda salvata — da ordinare (\(lcscCode))"
                    : "Aggiornato \(lcscCode) da DigiKey"
            )
            return existing
        }

        try upsert(records: [record], preserveLocalQuantity: true)
        guard let component = try modelContext.fetch(descriptor).first else {
            throw ProviderError.networkFailure("Import DigiKey fallito")
        }

        if component.needsLCSCCodeResolution, !component.mpn.isEmpty,
           let lcscRecord = try? await resolveLCSCRecord(forMPN: component.mpn) {
            let target = try assignLCSCCode(to: component, record: lcscRecord)
            target.applyLCSC(lcscRecord, preserveQuantity: true)
            markAsToOrder(target)
            try modelContext.save()
            publishStatus("Scheda salvata — \(target.lcscCode) da ordinare")
            return target
        }

        markAsToOrder(component)
        try modelContext.save()
        publishStatus("Scheda salvata — da ordinare (\(lcscCode))")
        return component
    }

    private func markAsToOrder(_ component: Component) {
        component.quantity = 0
        let tag = Component.toOrderTag
        if !component.tags.contains(where: { $0.compare(tag, options: .caseInsensitive) == .orderedSame }) {
            component.tags.append(tag)
        }
        component.lastUpdated = Date()
    }

    private func clearToOrderTagIfReceived(_ component: Component) {
        guard component.quantity > 0 else { return }
        component.tags.removeAll {
            $0.compare(Component.toOrderTag, options: .caseInsensitive) == .orderedSame
        }
    }

    private func resolveLCSCRecord(forMPN mpn: String) async throws -> ComponentRecord? {
        let trimmed = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = CatalogMatchNormalizer.mpn(trimmed)

        let inventory = fetchAllComponents()
        let archiveHits = LCSCArchiveSearcher.searchByMPN(trimmed, inventory: inventory, limit: 5)
            .filter { LCSCCode.isValid($0.lcscCode) }

        if let exact = archiveHits.first(where: {
            CatalogMatchNormalizer.mpn($0.mpn) == normalized
        }) {
            return exact
        }
        if let first = archiveHits.first {
            return first
        }

        let liveHits = try await LCSCCatalogProvider.searchByMPN(trimmed, limit: 5)
            .filter { LCSCCode.isValid($0.lcscCode) }
        if let exact = liveHits.first(where: {
            CatalogMatchNormalizer.mpn($0.mpn) == normalized
        }) {
            return exact
        }
        return liveHits.first
    }

    private func recoverLCSCCodeFromSnapshot(_ component: Component) throws -> Component? {
        guard component.needsLCSCCodeResolution else { return nil }
        guard let code = LCSCCode.extract(from: component.lcscSnapshot?.productURL),
              code.uppercased() != component.lcscCode.uppercased() else { return nil }

        let record = component.toRecord().withLCSCCode(code)
        let target = try assignLCSCCode(to: component, record: record)
        target.applyLCSC(record, preserveQuantity: true)
        return target
    }

    @discardableResult
    private func assignLCSCCode(to component: Component, record: ComponentRecord) throws -> Component {
        let newCode = record.lcscCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard LCSCCode.isValid(newCode) else { return component }

        let originalID = component.persistentModelID
        let target: Component

        if component.lcscCode.uppercased() == newCode {
            target = component
        } else if let existing = try fetchComponent(lcscCode: newCode),
                  existing.persistentModelID != component.persistentModelID {
            try mergeComponent(existing, from: component)
            existing.applyLCSC(record, preserveQuantity: true)
            target = existing
        } else {
            target = try rekeyComponent(component, to: newCode)
            target.applyLCSC(record, preserveQuantity: true)
        }

        if target.persistentModelID != originalID {
            focusComponent = target
        }
        return target
    }

    private func rekeyComponent(_ component: Component, to newCode: String) throws -> Component {
        let code = newCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard LCSCCode.isValid(code), component.lcscCode.uppercased() != code else { return component }

        let record = component.toRecord().withLCSCCode(code)
        let movements = Array(component.stockMovements)
        let items = Array(component.projectItems)

        let newComponent = makeComponent(from: record)
        modelContext.insert(newComponent)

        for movement in movements {
            movement.component = newComponent
        }
        for item in items {
            item.component = newComponent
        }

        modelContext.delete(component)
        return newComponent
    }

    private func makeComponent(from record: ComponentRecord) -> Component {
        Component(
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
        )
    }

    private func resolveAndApplyLCSC(to component: Component) async throws -> Component {
        if component.needsLCSCCodeResolution, !component.mpn.isEmpty {
            if let recovered = try recoverLCSCCodeFromSnapshot(component) {
                return recovered
            }

            guard let resolved = try await resolveLCSCRecord(forMPN: component.mpn) else {
                throw ProviderError.notFound(
                    "\(component.mpn) non è presente nel catalogo LCSC — il componente resta solo DigiKey"
                )
            }
            let target = try assignLCSCCode(to: component, record: resolved)
            target.applyLCSC(resolved, preserveQuantity: true)
            guard !target.needsLCSCCodeResolution else {
                throw ProviderError.networkFailure(
                    "Codice LCSC non assegnato — verifica connessione o MPN"
                )
            }
            return target
        }

        let record = try await lcscProvider.fetch(lcscCode: component.lcscCode)
        if record.lcscCode.hasPrefix("C"), record.lcscCode.uppercased() != component.lcscCode.uppercased() {
            let target = try assignLCSCCode(to: component, record: record)
            target.applyLCSC(record, preserveQuantity: true)
            return target
        }

        component.applyLCSC(record, preserveQuantity: true)
        return component
    }

    private func fetchComponent(lcscCode: String) throws -> Component? {
        let code = lcscCode.uppercased()
        let descriptor = FetchDescriptor<Component>(
            predicate: #Predicate { $0.lcscCode == code }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func mergeComponent(_ target: Component, from source: Component) throws {
        source.migrateLegacySnapshotsIfNeeded()

        if source.hasDigiKeyEnrichment {
            var dkRecord = source.toRecord()
            dkRecord.dataSource = DataSource.digikey
            target.applyDigiKey(dkRecord, preserveQuantity: true)
        }

        if source.quantity > target.quantity {
            target.quantity = source.quantity
        }

        for tag in source.tags where !target.tags.contains(tag) {
            target.tags.append(tag)
        }

        if target.notes.isEmpty, !source.notes.isEmpty {
            target.notes = source.notes
        }

        let linkedItems = Array(source.projectItems)
        for item in linkedItems {
            item.component = target
        }

        modelContext.delete(source)
    }

    private func buildRecord(
        for card: CatalogMatchCard,
        lcscCode: String,
        inventory: [Component]
    ) -> ComponentRecord {
        if let lcscRecord = card.lcscRecord {
            return lcscRecord
        }

        if let code = card.lcscCode,
           let component = inventory.first(where: { $0.lcscCode == code }) {
            return component.toRecord()
        }

        if let code = card.lcscCode,
           let archived = loadArchiveRecord(lcscCode: code) {
            return archived
        }

        if var digikeyRecord = card.digikeyRecord {
            digikeyRecord = ComponentRecord(
                lcscCode: lcscCode,
                mpn: digikeyRecord.mpn,
                name: digikeyRecord.name,
                description: digikeyRecord.description,
                footprint: digikeyRecord.footprint,
                quantity: digikeyRecord.quantity,
                category: digikeyRecord.category,
                value: digikeyRecord.value,
                brand: digikeyRecord.brand,
                datasheetURL: digikeyRecord.datasheetURL,
                imageURLs: digikeyRecord.imageURLs,
                price: digikeyRecord.price,
                currency: digikeyRecord.currency,
                supplierStock: digikeyRecord.supplierStock,
                dataSource: .digikey,
                parameters: digikeyRecord.parameters,
                notes: digikeyRecord.notes,
                minQuantity: digikeyRecord.minQuantity,
                tags: digikeyRecord.tags,
                updatedAt: digikeyRecord.updatedAt,
                digikeyPartNumber: digikeyRecord.digikeyPartNumber,
                supplierProductURL: digikeyRecord.supplierProductURL,
                priceBreaks: digikeyRecord.priceBreaks,
                minimumOrderQuantity: digikeyRecord.minimumOrderQuantity,
                leadTimeWeeks: digikeyRecord.leadTimeWeeks,
                digikeyProductStatus: digikeyRecord.digikeyProductStatus,
                digikeyLastFetched: digikeyRecord.digikeyLastFetched,
                lcscSnapshot: digikeyRecord.lcscSnapshot,
                digikeySnapshot: digikeyRecord.digikeySnapshot
            )
            return digikeyRecord
        }

        return ComponentRecord(
            lcscCode: lcscCode,
            mpn: card.mpn,
            name: card.mpn,
            description: card.description,
            footprint: card.footprint == "—" ? "" : card.footprint,
            category: card.type.label,
            value: card.value == "—" ? "" : card.value,
            brand: card.brand,
            price: card.lcscPrice ?? card.digikeyPrice,
            currency: card.lcscCurrency ?? card.digikeyCurrency,
            supplierStock: card.lcscStock ?? card.digikeyStock,
            dataSource: card.hasLCSC ? .lcsc : .digikey,
            digikeyPartNumber: card.digikeyPartNumber,
            supplierProductURL: card.digikeyURL ?? card.lcscURL
        )
    }

    private func loadArchiveRecord(lcscCode: String) -> ComponentRecord? {
        let path = "/Users/michelebigi/LCSC/json_full_data/\(lcscCode).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let record = try? JSONDecoder().decode(ComponentRecord.self, from: data) else {
            return nil
        }
        return record
    }

    private func fetchAllComponents() -> [Component] {
        (try? modelContext.fetch(FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)]))) ?? []
    }

    func pushToRemote(config: RemoteAPIConfig) async throws -> Int {
        isLoading = true
        defer { isLoading = false }

        let descriptor = FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)])
        let components = try modelContext.fetch(descriptor)
        let records = components.map { $0.toRecord() }
        let upserted = try await RemoteAPIClient.pushComponents(records, config: config)
        publishStatus("Caricati \(upserted) componenti sul server")
        return upserted
    }

    func pullFromRemote(config: RemoteAPIConfig) async throws -> Int {
        isLoading = true
        defer { isLoading = false }

        let records = try await RemoteAPIClient.fetchComponents(config: config)
        try upsert(records: records, preserveLocalQuantity: false)
        publishStatus("Scaricati \(records.count) componenti dal server")
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
        publishStatus(result.summary)
        return result
    }
}
