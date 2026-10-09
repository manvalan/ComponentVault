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

        for record in records.map({ $0.normalizedForInventory() }) {
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
                    lcscSupplierCode: record.lcscSupplierCode,
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
        publishStatus(String(localized: "Database creato: \(records.count) componenti da \(source)"))
        return DatabaseBootstrap.Result(imported: records.count, source: source)
    }

    /// Converte codici `DK-*` legacy in `CV-*` (one-shot all'avvio).
    @discardableResult
    func migrateLegacyInventoryCodesIfNeeded() throws -> Int {
        let components = fetchAllComponents()
        var count = 0
        for component in components {
            guard InternalComponentCode.isLegacyPlaceholder(component.lcscCode) else { continue }
            let seed = component.digikeyPartNumber.flatMap { $0.isEmpty ? nil : $0 }
                ?? component.mpn
            guard !seed.isEmpty else { continue }
            component.lcscCode = InternalComponentCode.migrateLegacyCode(component.lcscCode, seed: seed)
            count += 1
        }
        if count > 0 {
            try modelContext.save()
        }
        return count
    }

    /// Sposta `Cxxxxx` legacy da chiave primaria a `lcscSupplierCode` e assegna `CV-*`.
    @discardableResult
    func migrateLegacyPrimaryKeysToCVIfNeeded() throws -> Int {
        let components = fetchAllComponents()
        var count = 0
        for component in components {
            guard LCSCCode.isValid(component.lcscCode),
                  !InternalComponentCode.isInternal(component.lcscCode) else { continue }

            let supplier = component.lcscCode.uppercased()
            component.lcscSupplierCode = supplier

            let seed = component.digikeyPartNumber.flatMap { $0.isEmpty ? nil : $0 } ?? component.mpn
            guard !seed.isEmpty else { continue }

            let cvCode = InternalComponentCode.make(from: seed)
            guard component.lcscCode.uppercased() != cvCode.uppercased() else { continue }

            if let existing = try fetchComponent(lcscCode: cvCode),
               existing.persistentModelID != component.persistentModelID {
                try mergeComponent(existing, from: component)
                existing.lcscSupplierCode = supplier
            } else {
                component.lcscCode = cvCode
            }
            count += 1
        }
        if count > 0 {
            try modelContext.save()
        }
        return count
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
        publishStatus(String(localized: "Importati \(records.count) componenti da \(url.lastPathComponent)"))
    }

    func enrichFromLCSC(_ component: Component) async throws -> Component {
        isLoading = true
        defer { isLoading = false }

        let target = try await resolveAndApplyLCSC(to: component)
        try modelContext.save()
        publishStatus(String(localized: "Aggiornato \(target.lcscCode) da LCSC"))
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
                _ = try await enrichFromLCSC(component)
                try await Task.sleep(for: .milliseconds(delayMs))
            } catch {
                publishStatus(String(localized: "Errore su \(component.lcscCode): \(error.localizedDescription)"), autoDismissAfter: 8)
            }
        }
        publishStatus(String(localized: "Arricchimento LCSC completato (\(total) componenti)"))
    }

    /// Cerca codici LCSC Cxxxxx per tutte le righe del progetto che ne sono prive.
    func resolveLCSCForProject(_ project: Project) async throws -> (resolved: Int, stillMissing: Int) {
        isLoading = true
        defer { isLoading = false }

        var resolved = 0
        var stillMissing = 0

        for item in project.items {
            guard let component = item.component else {
                stillMissing += 1
                continue
            }
            if component.hasValidLCSCCode { continue }
            guard !component.mpn.isEmpty else {
                stillMissing += 1
                continue
            }
            if let updated = try await assignLCSCFromMPN(component), updated.hasValidLCSCCode {
                resolved += 1
            } else {
                stillMissing += 1
            }
        }

        project.updatedAt = Date()
        try modelContext.save()
        publishStatus(String(localized: "EasyEDA: \(resolved) LCSC trovati, \(stillMissing) ancora senza C"))
        return (resolved, stillMissing)
    }

    // MARK: DigiKey (solo con credenziali inserite sul dispositivo)

    func enrichFromDigiKey(_ component: Component) async throws -> DigiKeyEnrichResult {
        guard let provider = DigiKeyProvider.configured() else {
            throw ProviderError.networkFailure(String(localized: "Inserisci le credenziali DigiKey in Impostazioni."))
        }
        guard !component.mpn.isEmpty else { throw ProviderError.invalidCode }

        isLoading = true
        defer { isLoading = false }

        let candidates = try await provider.searchCandidates(mpn: component.mpn, lcscCode: component.lcscCode)
        let exact = candidates.filter { $0.mpn.caseInsensitiveCompare(component.mpn) == .orderedSame }
        if candidates.count == 1 || exact.count == 1 {
            try await applyDigiKeyRecord((exact.first ?? candidates[0]).record, to: component, provider: provider)
            return .applied
        }
        return .chooseCandidate(candidates)
    }

    func applyDigiKeyRecord(_ record: ComponentRecord, to component: Component, provider: DigiKeyProvider? = nil) async throws {
        var merged = record
        merged.quantity = component.quantity
        if let provider = provider ?? DigiKeyProvider.configured() {
            merged = try await provider.enrichRecord(merged)
        }
        component.applyDigiKey(merged)
        try modelContext.save()
        publishStatus(String(localized: "Aggiornato \(component.mpn) da DigiKey"))
    }

    func updateQuantity(_ component: Component, to quantity: Int) throws {
        let delta = quantity - component.quantity
        try adjustStock(component, delta: delta, reason: .manual, note: String(localized: "Aggiornamento manuale"))
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

    func setLowStockAlertEnabled(_ component: Component, enabled: Bool) throws {
        if enabled {
            if component.minQuantity == 0 {
                component.minQuantity = 1
            }
        } else {
            component.minQuantity = 0
        }
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
            publishStatus(String(localized: "Codice LCSC assegnato: \(recovered.supplierLCSCCode ?? recovered.lcscCode)"))
            return recovered
        }

        guard let record = try await resolveLCSCRecord(forMPN: component.mpn) else { return nil }

        let target = try assignLCSCCode(to: component, record: record)
        target.applyLCSC(record, preserveQuantity: true)
        try modelContext.save()
        publishStatus(String(localized: "Codice LCSC assegnato: \(target.supplierLCSCCode ?? target.lcscCode)"))
        return target
    }

    func applyCatalogMatchToExisting(_ component: Component, card: CatalogMatchCard) async throws -> Component {
        isLoading = true
        defer { isLoading = false }

        guard let lcscCode = card.lcscCode, LCSCCode.isValid(lcscCode) else {
            return try await importCatalogMatch(card)
        }

        let inventory = fetchAllComponents()
        let record = card.lcscRecord
            ?? buildRecord(for: card, inventoryCode: component.lcscCode, inventory: inventory)
            .withSupplierLCSC(lcscCode)

        let target = try assignLCSCCode(to: component, record: record)
        target.applyLCSC(record, preserveQuantity: true)

        if target.quantity == 0 {
            markAsToOrder(target)
        }
        try modelContext.save()
        publishStatus(String(localized: "Codice LCSC assegnato: \(target.supplierLCSCCode ?? target.lcscCode)"))
        return target
    }

    func importCatalogMatch(_ card: CatalogMatchCard) async throws -> Component {
        isLoading = true
        defer { isLoading = false }

        let inventory = fetchAllComponents()
        if let realCode = card.lcscCode, LCSCCode.isValid(realCode), !card.mpn.isEmpty {
            let targetMPN = CatalogMatchNormalizer.mpn(card.mpn)
            if let dkTwin = inventory.first(where: {
                CatalogMatchNormalizer.mpn($0.mpn) == targetMPN
                    && InternalComponentCode.isInternal($0.lcscCode)
                    && $0.supplierLCSCCode == nil
            }) {
                return try await applyCatalogMatchToExisting(dkTwin, card: card)
            }
        }

        let supplierLCSC = card.lcscCode.flatMap { LCSCCode.isValid($0) ? $0 : nil }
        let inventoryCode: String
        if !card.mpn.isEmpty {
            inventoryCode = InternalComponentCode.make(from: card.mpn)
        } else if let supplierLCSC {
            inventoryCode = InternalComponentCode.make(from: supplierLCSC)
        } else {
            throw ProviderError.invalidCode
        }

        var record = buildRecord(for: card, inventoryCode: inventoryCode, inventory: inventory)
        if let supplierLCSC {
            record = record.withSupplierLCSC(supplierLCSC)
        }

        let descriptor = FetchDescriptor<Component>(
            predicate: #Predicate { $0.lcscCode == inventoryCode }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            if card.lcscRecord != nil || card.lcscCode != nil {
                existing.applyLCSC(record, preserveQuantity: true)
            }
            try modelContext.save()
            if existing.quantity == 0 {
                markAsToOrder(existing)
                try modelContext.save()
            }
            publishStatus(
                existing.isToOrder
                    ? String(localized: "Scheda salvata — da ordinare (\(inventoryCode))")
                    : "Aggiornato \(inventoryCode)"
            )
            return existing
        }

        try upsert(records: [record], preserveLocalQuantity: true)

        let insertedDescriptor = FetchDescriptor<Component>(
            predicate: #Predicate { $0.lcscCode == inventoryCode }
        )
        guard let component = try modelContext.fetch(insertedDescriptor).first else {
            throw ProviderError.networkFailure(String(localized: "Import fallito per \(inventoryCode)"))
        }

        markAsToOrder(component)
        try modelContext.save()
        publishStatus(String(localized: "Scheda salvata — da ordinare (\(inventoryCode))"))
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
        guard let code = LCSCCode.extract(from: component.lcscSnapshot?.productURL) else { return nil }
        guard component.supplierLCSCCode?.uppercased() != code.uppercased() else { return nil }

        component.lcscSupplierCode = code.uppercased()
        return component
    }

    @discardableResult
    private func assignLCSCCode(to component: Component, record: ComponentRecord) throws -> Component {
        let newSupplierCode = record.lcscSupplierCode.flatMap { LCSCCode.isValid($0) ? $0.uppercased() : nil }
            ?? (LCSCCode.isValid(record.lcscCode) ? record.lcscCode.uppercased() : nil)
        guard let newSupplierCode else { return component }

        if let duplicate = fetchAllComponents().first(where: {
            $0.persistentModelID != component.persistentModelID
                && $0.supplierLCSCCode?.uppercased() == newSupplierCode
        }) {
            try mergeComponent(duplicate, from: component)
            duplicate.lcscSupplierCode = newSupplierCode
            duplicate.applyLCSC(record, preserveQuantity: true)
            focusComponent = duplicate
            return duplicate
        }

        component.lcscSupplierCode = newSupplierCode
        component.applyLCSC(record, preserveQuantity: true)
        return component
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
            lcscSupplierCode: record.lcscSupplierCode,
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
                    String(localized: "\(component.mpn) non è presente nel catalogo LCSC")
                )
            }
            let target = try assignLCSCCode(to: component, record: resolved)
            target.applyLCSC(resolved, preserveQuantity: true)
            guard !target.needsLCSCCodeResolution else {
                throw ProviderError.networkFailure(
                    String(localized: "Codice LCSC non assegnato — verifica connessione o MPN")
                )
            }
            return target
        }

        let fetchCode = component.supplierLCSCCode
            ?? (LCSCCode.isValid(component.lcscCode) ? component.lcscCode : nil)
        guard let fetchCode else {
            throw ProviderError.invalidCode
        }

        let record = try await lcscProvider.fetch(lcscCode: fetchCode)
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
        inventoryCode: String,
        inventory: [Component]
    ) -> ComponentRecord {
        if let lcscRecord = card.lcscRecord {
            let supplier = LCSCCode.isValid(lcscRecord.lcscCode) ? lcscRecord.lcscCode : card.lcscCode
            return ComponentRecord(
                lcscCode: inventoryCode,
                mpn: lcscRecord.mpn,
                name: lcscRecord.name,
                description: lcscRecord.description,
                footprint: lcscRecord.footprint,
                quantity: lcscRecord.quantity,
                category: lcscRecord.category,
                value: lcscRecord.value,
                brand: lcscRecord.brand,
                datasheetURL: lcscRecord.datasheetURL,
                imageURLs: lcscRecord.imageURLs,
                price: lcscRecord.price,
                currency: lcscRecord.currency,
                supplierStock: lcscRecord.supplierStock,
                dataSource: lcscRecord.dataSource,
                parameters: lcscRecord.parameters,
                notes: lcscRecord.notes,
                minQuantity: lcscRecord.minQuantity,
                tags: lcscRecord.tags,
                updatedAt: lcscRecord.updatedAt,
                digikeyPartNumber: lcscRecord.digikeyPartNumber,
                supplierProductURL: lcscRecord.supplierProductURL,
                priceBreaks: lcscRecord.priceBreaks,
                lcscSupplierCode: {
                    if let supplier, LCSCCode.isValid(supplier) { return supplier }
                    return nil
                }(),
                minimumOrderQuantity: lcscRecord.minimumOrderQuantity,
                leadTimeWeeks: lcscRecord.leadTimeWeeks,
                digikeyProductStatus: lcscRecord.digikeyProductStatus,
                digikeyLastFetched: lcscRecord.digikeyLastFetched,
                lcscSnapshot: lcscRecord.lcscSnapshot,
                digikeySnapshot: lcscRecord.digikeySnapshot
            )
        }

        if let code = card.lcscCode,
           let component = inventory.first(where: { $0.lcscCode == code || $0.supplierLCSCCode == code }) {
            return component.toRecord().with(inventoryCode: inventoryCode)
        }

        if let code = card.lcscCode,
           let archived = loadArchiveRecord(lcscCode: code) {
            return archived.normalizedForInventory().with(inventoryCode: inventoryCode)
        }

        return ComponentRecord(
            lcscCode: inventoryCode,
            mpn: card.mpn,
            name: card.mpn,
            description: card.description,
            footprint: card.footprint == "—" ? "" : card.footprint,
            category: card.type.englishLabel,
            value: card.value == "—" ? "" : card.value,
            brand: card.brand,
            price: card.lcscPrice,
            currency: card.lcscCurrency,
            supplierStock: card.lcscStock,
            dataSource: card.hasLCSC ? .lcsc : .manual,
            supplierProductURL: card.lcscURL,
            lcscSupplierCode: card.lcscCode.flatMap { LCSCCode.isValid($0) ? $0 : nil }
        )
    }

    private func loadArchiveRecord(lcscCode: String) -> ComponentRecord? {
        let path = AppPaths.jsonArchiveDirectory.appendingPathComponent("\(lcscCode).json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let record = try? JSONDecoder().decode(ComponentRecord.self, from: data) else {
            return nil
        }
        return record
    }

    private func fetchAllComponents() -> [Component] {
        (try? modelContext.fetch(FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)]))) ?? []
    }

    /// Componente già in inventario che corrisponde all'etichetta (LCSC, poi MPN).
    func existingComponent(for label: ScannedLabel) -> Component? {
        let inventory = fetchAllComponents()
        if let lcsc = label.lcsc?.uppercased(),
           let hit = inventory.first(where: { $0.supplierLCSCCode?.uppercased() == lcsc || $0.lcscCode.uppercased() == lcsc }) {
            return hit
        }
        if let mpn = label.mpn {
            let key = CatalogMatchNormalizer.mpn(mpn)
            if !key.isEmpty, let hit = inventory.first(where: { CatalogMatchNormalizer.mpn($0.mpn) == key }) {
                return hit
            }
        }
        return nil
    }

    /// Carico da etichetta: se il componente c'è già aggiunge la quantità, altrimenti
    /// lo crea (con i dati LCSC quando il codice o l'MPN si trovano nel catalogo).
    /// La posizione indicata (dispensario e numero) sostituisce quella precedente.
    func receiveScanned(
        _ label: ScannedLabel,
        quantity: Int,
        location: String,
        slot: String
    ) async throws -> (component: Component, created: Bool) {
        isLoading = true
        defer { isLoading = false }

        let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let slot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = String(localized: "Carico da etichetta")

        if let existing = existingComponent(for: label) {
            if !location.isEmpty { existing.storageLocation = location }
            if !slot.isEmpty { existing.storageSlot = slot }
            if existing.supplierLCSCCode == nil, let lcsc = label.lcsc { existing.lcscSupplierCode = lcsc }
            if quantity != 0 {
                try adjustStock(existing, delta: quantity, reason: .importAction, note: note)
            } else {
                existing.lastUpdated = Date()
                try modelContext.save()
            }
            return (existing, false)
        }

        var record: ComponentRecord?
        if let lcsc = label.lcsc {
            record = try? await lcscProvider.fetch(lcscCode: lcsc)
        }
        if record == nil, let mpn = label.mpn,
           let hit = try? await resolveLCSCRecord(forMPN: mpn),
           CatalogMatchNormalizer.mpn(hit.mpn) == CatalogMatchNormalizer.mpn(mpn) {
            record = hit
        }
        let seed = label.mpn ?? label.lcsc ?? label.raw
        var base = record ?? ComponentRecord(
            lcscCode: label.lcsc ?? InternalComponentCode.make(from: seed),
            mpn: label.mpn ?? "",
            brand: label.manufacturer ?? "",
            dataSource: .manual
        )
        base.quantity = 0
        base.storageLocation = location.isEmpty ? nil : location
        base.storageSlot = slot.isEmpty ? nil : slot
        let normalized = base.normalizedForInventory()
        try upsert(records: [normalized], preserveLocalQuantity: false)

        let code = normalized.lcscCode
        guard let component = try modelContext.fetch(
            FetchDescriptor<Component>(predicate: #Predicate { $0.lcscCode == code })
        ).first else {
            throw ProviderError.networkFailure(String(localized: "Import fallito per \(code)"))
        }
        component.storageLocation = normalized.storageLocation
        component.storageSlot = normalized.storageSlot
        if quantity != 0 {
            try adjustStock(component, delta: quantity, reason: .importAction, note: note)
        } else {
            try modelContext.save()
        }
        return (component, true)
    }

    /// Dispensari già usati, per suggerirli durante il carico.
    func knownStorageLocations() -> [String] {
        let all = fetchAllComponents().compactMap { $0.storageLocation?.trimmingCharacters(in: .whitespaces) }
        return Array(Set(all.filter { !$0.isEmpty })).sorted()
    }

    func allRecords() throws -> [ComponentRecord] {
        try modelContext.fetch(FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)]))
            .map { $0.toRecord() }
    }

    /// Fonde l'inventario di un altro dispositivo (cartella condivisa): per ogni
    /// codice vince la modifica più recente. `pushed` = record locali più nuovi.
    func merge(remote remoteRecords: [ComponentRecord]) throws -> SyncBidirectionalResult {
        isLoading = true
        defer { isLoading = false }

        var remoteByCode: [String: ComponentRecord] = [:]
        for record in remoteRecords { remoteByCode[record.lcscCode] = record }

        let localComponents = try modelContext.fetch(FetchDescriptor<Component>())
        var localByCode: [String: Component] = [:]
        for component in localComponents { localByCode[component.lcscCode] = component }

        var pushed = 0
        var pulled = 0
        var unchanged = 0

        for (code, local) in localByCode {
            if let remote = remoteByCode[code] {
                let localDate = local.lastUpdated
                let remoteDate = SyncDateParser.parse(remote.updatedAt)
                if localDate > remoteDate.addingTimeInterval(1) {
                    pushed += 1
                } else if remoteDate > localDate.addingTimeInterval(1) {
                    local.apply(remote, preserveQuantity: false)
                    local.lastUpdated = remoteDate
                    pulled += 1
                } else {
                    unchanged += 1
                }
            } else {
                pushed += 1
            }
        }

        let newRecords = remoteByCode.filter { localByCode[$0.key] == nil }.map(\.value)
        try upsert(records: newRecords, preserveLocalQuantity: false)
        pulled += newRecords.count
        try modelContext.save()

        let result = SyncBidirectionalResult(pushed: pushed, pulled: pulled, unchanged: unchanged)
        publishStatus(result.summary)
        return result
    }
}
