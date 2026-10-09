import SwiftUI
import SwiftData

/// Aggiunta di righe alla BOM: una sola ricerca su magazzino e catalogo, oppure un
/// componente nuovo da MPN o codice LCSC. Il foglio resta aperto per aggiungerne altri.
struct ProjectAddItemsView: View {
    let project: Project
    let projectStore: ProjectStore?
    let store: ComponentStore?

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Component.lcscCode) private var inventory: [Component]

    @State private var query = ""
    @State private var quantity = 1
    @State private var designator = ""
    @State private var provider = SupplierCatalogSearchService.effective(AppConfigIO.current().catalog.searchProvider)
    @State private var catalogCards: [CatalogMatchCard] = []
    @State private var catalogMessage: String?
    @State private var isSearching = false
    @State private var searchedAll = false
    @State private var isAdding = false
    @State private var added: [String] = []
    @State private var errorMessage: String?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var inventoryMatches: [Component] {
        let terms = trimmedQuery.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return inventory.filter { component in
            let haystack = [
                component.lcscCode, component.supplierLCSCCode ?? "", component.mpn, component.name,
                component.value, component.footprint, component.brand, component.componentDescription,
                component.storageLabel ?? "",
            ].joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        .prefix(40)
        .map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                lineSection
                if trimmedQuery.isEmpty {
                    hintSection
                } else {
                    inventorySection
                    catalogSection
                    newComponentSection
                }
            }
            .navigationTitle("Aggiungi alla BOM")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: Text("Magazzino, valore, MPN o codice LCSC"))
            .onSubmit(of: .search) { Task { await searchCatalog() } }
            .task(id: query) {
                // Ricerca nel catalogo mentre si scrive (dopo una breve pausa).
                catalogCards = []
                catalogMessage = nil
                searchedAll = false
                guard trimmedQuery.count >= 3 else { return }
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                await searchCatalog()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .alert("Errore", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }

    // MARK: Sezioni

    private var lineSection: some View {
        Section {
            TextField("Designator (es. R1, R2, C5)", text: $designator)
                .autocorrectionDisabled()
                .onChange(of: designator) { _, newValue in
                    // "R1, R2, R3" → quantità 3, finché l'utente non la cambia a mano.
                    let count = Self.designatorCount(newValue)
                    if count > 1 { quantity = count }
                }
            Stepper(value: $quantity, in: 1...999_999) {
                LabeledContent("Quantità", value: "\(quantity)")
            }
        } footer: {
            if !added.isEmpty {
                Text("Aggiunti: \(added.joined(separator: ", "))")
            }
        }
    }

    private var hintSection: some View {
        Section {
            Label("Cerca nel magazzino per valore, footprint, MPN o posizione.", systemImage: "shippingbox")
            Label("Cerca anche nel catalogo del fornitore predefinito (\(provider.label)); gli altri distributori a richiesta.", systemImage: "magnifyingglass")
            Label("Se non c'è, aggiungi l'MPN o il codice LCSC come componente nuovo: finisce in magazzino come «da ordinare».", systemImage: "plus.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var inventorySection: some View {
        let matches = inventoryMatches
        Section("In magazzino") {
            if matches.isEmpty {
                Text("Nessun componente in magazzino.").foregroundStyle(.secondary)
            }
            ForEach(matches) { component in
                addRow(
                    title: component.displayTitle,
                    subtitle: [component.value, component.footprint, component.storageLabel]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    trailing: String(localized: "Stock \(component.quantity)"),
                    trailingColor: component.quantity >= quantity ? .green : .orange
                ) {
                    add(component)
                }
            }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        Section {
            if catalogCards.isEmpty {
                Button {
                    Task { await searchCatalog() }
                } label: {
                    HStack {
                        Label("Cerca «\(trimmedQuery)» nel catalogo", systemImage: "magnifyingglass")
                        Spacer()
                        if isSearching { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isSearching)
            }
            if let catalogMessage {
                Text(catalogMessage).font(.caption).foregroundStyle(.secondary)
            }
            let others = SupplierCatalogSearchService.otherSuppliers(than: provider)
            if !others.isEmpty, !searchedAll, !catalogCards.isEmpty || catalogMessage != nil {
                Button {
                    Task { await searchCatalog(allSuppliers: true) }
                } label: {
                    Label("Cerca anche su \(others.joined(separator: ", "))", systemImage: "plus.magnifyingglass")
                }
                .disabled(isSearching)
            }
            ForEach(catalogCards) { card in
                addRow(
                    title: card.mpn.isEmpty ? (card.lcscCode ?? card.value) : card.mpn,
                    subtitle: [card.brand, card.value, card.footprint, card.lcscCode ?? card.offer?.supplier]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    trailing: card.inInventory
                        ? String(localized: "In magazzino")
                        : (card.lcscStock ?? card.offer?.stock).map { String(localized: "Stock \($0)") },
                    trailingColor: card.inInventory ? .green : .secondary
                ) {
                    addCatalog(card)
                }
            }
        } header: {
            HStack {
                Text("Catalogo")
                Spacer()
                Picker("Fonte", selection: $provider) {
                    ForEach(CatalogSearchProvider.available) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: provider) { _, _ in
                    catalogCards = []
                    catalogMessage = nil
                    searchedAll = false
                }
            }
        }
    }

    private var newComponentSection: some View {
        Section {
            Button {
                addNew()
            } label: {
                Label("Aggiungi «\(trimmedQuery)» come componente nuovo", systemImage: "plus.circle")
            }
            .disabled(isAdding)
        } footer: {
            Text("MPN o codice LCSC (Cxxxx). Se è nell'archivio LCSC prende i dati da lì; in magazzino va a stock 0.")
        }
    }

    private func addRow(
        title: String,
        subtitle: String,
        trailing: String?,
        trailingColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.monospaced()).foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if let trailing {
                    Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(trailingColor)
                }
                Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdding)
    }

    // MARK: Azioni

    private func add(_ component: Component) {
        do {
            try projectStore?.addComponent(component, to: project, quantity: quantity, designator: designator.trimmingCharacters(in: .whitespaces))
            added.append(component.displayTitle)
            designator = ""
            quantity = 1
            query = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addCatalog(_ card: CatalogMatchCard) {
        guard let store else { return }
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                add(try await store.importCatalogMatch(card))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addNew() {
        guard let store, let label = LabelParser.parse(trimmedQuery) else {
            errorMessage = String(localized: "Inserisci un MPN o un codice LCSC.")
            return
        }
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                let result = try await store.receiveScanned(label, quantity: 0, location: "", slot: "")
                add(result.component)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func searchCatalog(allSuppliers: Bool = false) async {
        guard !trimmedQuery.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        searchedAll = allSuppliers
        let searchQuery = CatalogSearchQuery(type: nil, valueAmount: trimmedQuery)
        do {
            let outcome = try await SupplierCatalogSearchService.search(
                query: searchQuery,
                inventory: inventory,
                provider: provider,
                allSuppliers: allSuppliers
            )
            catalogCards = Array(outcome.cards.prefix(40))
            catalogMessage = outcome.cards.isEmpty ? String(localized: "Nessun risultato nel catalogo.") : outcome.statusMessage
        } catch {
            catalogMessage = error.localizedDescription
        }
    }

    /// Conta i designator: "R1, R2 R3" → 3, "R1-R4" → 4.
    static func designatorCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).reduce(0) { total, token in
            let parts = token.split(separator: "-")
            if parts.count == 2,
               let start = Int(parts[0].drop { !$0.isNumber }),
               let end = Int(parts[1].drop { !$0.isNumber }),
               end >= start, end - start < 1000 {
                return total + end - start + 1
            }
            return total + 1
        }
    }
}
