import SwiftUI
import SwiftData

enum CatalogLookupMode: String, CaseIterable, Identifiable {
    case design
    case mpn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .design: "Progettazione"
        case .mpn: "Da MPN"
        }
    }
}

struct CatalogLookupView: View {
    @Query(sort: \Component.lcscCode) private var inventory: [Component]
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var query = CatalogSearchQuery()
    @State private var mode: CatalogLookupMode = .design
    @State private var mpnQuery = ""
    @State private var results: [CatalogMatchCard] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var store: ComponentStore?
    @State private var projectStore: ProjectStore?
    @State private var projectPickerCard: CatalogMatchCard?
    @State private var selectedProjectID = ""
    @State private var addDesignator = ""
    @State private var addQuantity = 1
    @State private var importedComponent: Component?

    var body: some View {
        VStack(spacing: 0) {
            searchForm
            Divider()
            resultsPanel
        }
        .frame(minWidth: 760, minHeight: 560)
        .navigationTitle("Trova componente — progettazione")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Chiudi") { dismiss() }
            }
        }
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
            if projectStore == nil { projectStore = ProjectStore(modelContext: modelContext) }
        }
        .sheet(isPresented: Binding(
            get: { projectPickerCard != nil },
            set: { if !$0 { projectPickerCard = nil } }
        )) {
            if let card = projectPickerCard {
                addToProjectSheet(card: card)
            }
        }
        .sheet(item: $importedComponent) { component in
            ComponentDetailSheet(component: component, store: store)
        }
    }

    private var searchForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Modalità", selection: $mode) {
                ForEach(CatalogLookupMode.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .design:
                designSearchForm
            case .mpn:
                mpnSearchForm
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private var designSearchForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cerca nei cataloghi fornitori: DigiKey trova il componente, LCSC restituisce il codice C.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Picker("Tipo", selection: $query.type) {
                    ForEach(ComponentType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .frame(width: 220)

                TextField("Valore (es. 10kΩ, 100nF)", text: $query.value)
                    .textFieldStyle(.roundedBorder)

                TextField("Footprint (es. 0805, SOT-23)", text: $query.footprint)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Button {
                    Task { await runDesignSearch() }
                } label: {
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Cerca", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSearching || query.isEmpty)
            }

            Text("Flusso: DigiKey → MPN → LCSC · Richiede token DigiKey")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var mpnSearchForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trova il codice LCSC (Cxxxxx) dal Manufacturer Part Number.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                TextField("MPN (es. INA219AIDR, FRC0805F1002TS)", text: $mpnQuery)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await runMPNSearch() }
                } label: {
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Trova LCSC", systemImage: "number")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSearching || mpnQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Ordine: inventario → archivio JSON locale → API LCSC live (+ DigiKey se configurato)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("API live LCSC integrata · archivio: `~/LCSC/json_full_data/`")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var resultsPanel: some View {
        if results.isEmpty && !isSearching {
            ContentUnavailableView(
                mode == .mpn ? "Ricerca da MPN" : "Catalogo fornitori",
                systemImage: mode == .mpn ? "number" : "cpu",
                description: Text(
                    mode == .mpn
                        ? "Inserisci un MPN per trovare il codice LCSC.\nEsempio: INA219AIDR"
                        : "Imposta tipo, valore e footprint.\nEsempio: Resistenze · 10kΩ · 0805"
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(results) { card in
                        CatalogMatchCardView(
                            card: card,
                            canAddToProject: !projects.isEmpty,
                            onImport: { Task { await importCard(card) } },
                            onAddToProject: {
                                projectPickerCard = card
                                selectedProjectID = ""
                                addDesignator = ""
                                addQuantity = 1
                            }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private func runDesignSearch() async {
        isSearching = true
        errorMessage = nil
        statusMessage = nil
        defer { isSearching = false }

        do {
            let cards = try await CatalogSearchService.search(query: query, inventory: inventory)
            results = cards
            let dual = cards.filter(\.hasBothCodes).count
            statusMessage = "\(cards.count) da DigiKey · \(dual) con codice LCSC"
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }

    private func runMPNSearch() async {
        isSearching = true
        errorMessage = nil
        statusMessage = nil
        defer { isSearching = false }

        do {
            let (cards, stats) = try await MPNLookupService.search(
                mpn: mpnQuery,
                inventory: inventory
            )
            results = cards
            let withLCSC = cards.filter(\.hasLCSC).count
            var parts = ["\(withLCSC) con codice LCSC"]
            if stats.archiveCount > 0 { parts.append("\(stats.archiveCount) da archivio") }
            if stats.liveCount > 0 { parts.append("\(stats.liveCount) da LCSC live") }
            if stats.digikeyFound { parts.append("DigiKey OK") }
            statusMessage = parts.joined(separator: " · ")
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }

    private func importCard(_ card: CatalogMatchCard) async {
        guard let store else { return }
        do {
            let component = try await store.importCatalogMatch(card)
            importedComponent = component
            statusMessage = component.isToOrder
                ? "Scheda salvata — da ordinare (\(component.lcscCode))"
                : "Aggiornato \(component.lcscCode)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addToProjectSheet(card: CatalogMatchCard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aggiungi al progetto")
                .font(.headline)
            Text(card.mpn)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Picker("Progetto", selection: $selectedProjectID) {
                Text("Seleziona…").tag("")
                ForEach(projects, id: \.persistentModelID) { project in
                    Text(project.name).tag(projectID(project))
                }
            }

            TextField("Designator (es. R1, C5)", text: $addDesignator)
            Stepper("Quantità: \(addQuantity)", value: $addQuantity, in: 1...9999)

            HStack {
                Spacer()
                Button("Annulla") { projectPickerCard = nil }
                Button("Aggiungi") {
                    Task { await addCardToProject(card) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedProjectID.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func addCardToProject(_ card: CatalogMatchCard) async {
        guard let store, let projectStore else { return }
        guard let project = projects.first(where: { projectID($0) == selectedProjectID }) else { return }

        do {
            let component = try await store.importCatalogMatch(card)
            try projectStore.addComponent(
                component,
                to: project,
                quantity: addQuantity,
                designator: addDesignator
            )
            statusMessage = "\(component.lcscCode) aggiunto a \(project.name) — da ordinare"
            importedComponent = component
            projectPickerCard = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func projectID(_ project: Project) -> String {
        String(describing: project.persistentModelID)
    }
}

struct CatalogMatchCardView: View {
    let card: CatalogMatchCard
    let canAddToProject: Bool
    let onImport: () -> Void
    let onAddToProject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            codesRow
            metaRow
            actionRow
        }
        .padding(14)
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(card.hasBothCodes ? Color.purple.opacity(0.35) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: card.type.icon)
                        .foregroundStyle(card.type.tint)
                    Text(card.mpn)
                        .font(.headline.monospaced())
                }
                if !card.brand.isEmpty {
                    Text(card.brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !card.description.isEmpty {
                    Text(card.description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(card.value) · \(card.footprint)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                if card.hasBothCodes {
                    Text("LCSC + DigiKey")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var codesRow: some View {
        HStack(spacing: 12) {
            SupplierCodeTile(
                title: "LCSC",
                code: card.lcscCode ?? "—",
                tint: .orange,
                price: card.lcscPrice,
                currency: card.lcscCurrency,
                stock: card.lcscStock,
                url: card.lcscLink
            )

            SupplierCodeTile(
                title: "DigiKey",
                code: card.digikeyPartNumber ?? "—",
                tint: .red,
                price: card.digikeyPrice,
                currency: card.digikeyCurrency,
                stock: card.digikeyStock,
                url: card.digikeyLink
            )
        }
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            if let source = card.lcscSource {
                Label(sourceLabel(source), systemImage: sourceIcon(source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if card.inInventory, let qty = card.inventoryQuantity {
                Label("Già in inventario · qty \(qty)", systemImage: "tray.full")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
        }
    }

    private func sourceLabel(_ source: LCSCMatchSource) -> String {
        switch source {
        case .inventory: "Dal tuo inventario"
        case .archive: "Archivio LCSC locale"
        case .live: "LCSC live"
        }
    }

    private func sourceIcon(_ source: LCSCMatchSource) -> String {
        switch source {
        case .inventory: "tray.full"
        case .archive: "internaldrive"
        case .live: "globe"
        }
    }

    private var actionRow: some View {
        HStack {
            if let lcscURL = card.lcscLink {
                Link(destination: lcscURL) {
                    Label("LCSC", systemImage: "arrow.up.right")
                }
                .font(.caption)
            }
            if let dkURL = card.digikeyLink {
                Link(destination: dkURL) {
                    Label("DigiKey", systemImage: "arrow.up.right")
                }
                .font(.caption)
            }
            Spacer()
            Button("Salva scheda", action: onImport)
                .buttonStyle(.bordered)
                .help("Salva la scheda tecnica con qty 0 — da ordinare, non in magazzino")
            Button("Nel progetto", action: onAddToProject)
                .buttonStyle(.borderedProminent)
                .disabled(!canAddToProject)
        }
    }
}

private struct SupplierCodeTile: View {
    let title: String
    let code: String
    let tint: Color
    let price: Double?
    let currency: String?
    let stock: Int?
    let url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)

            if let url, code != "—" {
                Link(code, destination: url)
                    .font(.title3.weight(.bold).monospaced())
            } else {
                Text(code)
                    .font(.title3.weight(.bold).monospaced())
                    .foregroundStyle(code == "—" ? .tertiary : .primary)
            }

            HStack(spacing: 8) {
                if let price, let currency {
                    Text(String(format: "%.4f %@", price, currency))
                        .font(.caption.monospacedDigit())
                }
                if let stock {
                    Text("stock \(stock)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
