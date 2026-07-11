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

    func upsert(records: [ComponentRecord]) throws {
        for record in records {
            let descriptor = FetchDescriptor<Component>(
                predicate: #Predicate { $0.lcscCode == record.lcscCode }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                let savedQty = existing.quantity
                existing.apply(record)
                if record.quantity == 0 && savedQty > 0 {
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
        var merged = record
        merged.quantity = component.quantity
        component.apply(merged)
        try modelContext.save()
        statusMessage = "Aggiornato \(component.lcscCode) da LCSC"
    }

    func enrichAllFromLCSC(components: [Component], progress: ((Int, Int) -> Void)? = nil) async {
        isLoading = true
        defer { isLoading = false }

        let total = components.count
        for (index, component) in components.enumerated() {
            progress?(index + 1, total)
            do {
                try await enrichFromLCSC(component)
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                statusMessage = "Errore su \(component.lcscCode): \(error.localizedDescription)"
            }
        }
        statusMessage = "Arricchimento completato (\(total) componenti)"
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
}
