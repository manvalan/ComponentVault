import SwiftUI
import SwiftData

struct CatalogLookupView: View {
    var embeddedInNavigation = false

    @Query(sort: \Component.lcscCode) private var inventory: [Component]
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var query = CatalogSearchQuery()
    @State private var searchProvider = AppConfigIO.current().catalog.searchProvider
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
    @State private var kicadMessage: String?

    var body: some View {
        resultsPanel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                searchForm
            }
            .modifier(CatalogLookupChrome(embeddedInNavigation: embeddedInNavigation))
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
            if projectStore == nil { projectStore = ProjectStore(modelContext: modelContext) }
            searchProvider = AppConfigIO.current().catalog.searchProvider
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
        .alert("KiCad", isPresented: .constant(kicadMessage != nil)) {
            Button("OK") { kicadMessage = nil }
        } message: {
            Text(kicadMessage ?? "")
        }
    }

    private var searchForm: some View {
        VStack(spacing: 0) {
            CatalogDesignFilterBar(
                query: $query,
                inventory: inventory,
                isSearching: isSearching,
                searchProvider: searchProvider,
                onSearch: { Task { await runSearch() } }
            )

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(.bar)
        .onAppear {
            restoreCatalogSearchDefaults()
            searchProvider = AppConfigIO.current().catalog.searchProvider
        }
    }

    private func restoreCatalogSearchDefaults() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: CatalogSearchDefaults.typeClearedKey) {
            query.type = nil
        } else if let raw = defaults.string(forKey: CatalogSearchDefaults.typeKey),
                  let type = ComponentType(rawValue: raw) {
            query.type = type
        }
        if let unitRaw = defaults.string(forKey: CatalogSearchDefaults.valueUnitKey),
           let unit = ComponentValueUnit(rawValue: unitRaw) {
            query.valueUnit = unit
        } else if let type = query.type {
            query.valueUnit = ComponentValueUnit.defaultUnit(for: type)
        }
        if let amount = defaults.string(forKey: CatalogSearchDefaults.valueAmountKey), !amount.isEmpty {
            query.valueAmount = amount
        } else if let legacy = defaults.string(forKey: CatalogSearchDefaults.legacyValueKey), !legacy.isEmpty {
            let parsed = ComponentValueFormatter.parse(legacy, type: query.resolvedType)
            query.valueAmount = parsed.amount
            query.valueUnit = parsed.unit
        }
        if let footprint = defaults.string(forKey: CatalogSearchDefaults.footprintKey), !footprint.isEmpty {
            query.footprint = footprint
        }
        if let brand = defaults.string(forKey: CatalogSearchDefaults.brandKey), !brand.isEmpty {
            query.brand = brand
        }
        sanitizeCatalogQuerySelections()
    }

    private func persistCatalogSearchDefaults() {
        let defaults = UserDefaults.standard
        if let type = query.type {
            defaults.set(type.rawValue, forKey: CatalogSearchDefaults.typeKey)
            defaults.set(false, forKey: CatalogSearchDefaults.typeClearedKey)
        } else {
            defaults.set(true, forKey: CatalogSearchDefaults.typeClearedKey)
        }
        defaults.set(query.valueAmount, forKey: CatalogSearchDefaults.valueAmountKey)
        defaults.set(query.valueUnit.rawValue, forKey: CatalogSearchDefaults.valueUnitKey)
        defaults.set(query.footprint, forKey: CatalogSearchDefaults.footprintKey)
        defaults.set(query.brand, forKey: CatalogSearchDefaults.brandKey)
    }

    private func sanitizeCatalogQuerySelections() {
        let footprints = CatalogFilterOptions.footprints(in: inventory, for: query.resolvedType)
        if !query.footprint.isEmpty, !footprints.contains(query.footprint) {
            query.footprint = ""
        }
        let brands = CatalogFilterOptions.brands(
            in: inventory,
            type: query.resolvedType,
            value: query.value,
            footprint: query.footprint
        )
        if !query.brand.isEmpty {
            if !query.hasValueAndFootprint || !brands.contains(query.brand) {
                query.brand = ""
            }
        }
    }

    @ViewBuilder
    private var resultsPanel: some View {
        ZStack {
            if results.isEmpty && !isSearching {
                ContentUnavailableView(
                    "Catalogo fornitori",
                    systemImage: "cpu",
                    description: Text(emptyStateDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LCSCSearchResultsTable(
                    results: results,
                    canAddToProject: !projects.isEmpty,
                    onImport: { card in Task { await importCard(card) } },
                    onAddToProject: { card in
                        projectPickerCard = card
                        selectedProjectID = ""
                        addDesignator = ""
                        addQuantity = 1
                    },
                    onAddToKiCad: { card in addCardToKiCad(card) }
                )
            }

            if isSearching {
                ProgressView("Ricerca in corso…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var emptyStateDescription: String {
        let provider = searchProvider.label
        return """
        Provider: \(provider) (Impostazioni)

        Parametrica: Tipo · Valore · Footprint
        Da MPN: scrivi l'MPN nel campo Valore (es. INA219AIDR)
        """
    }

    private func runSearch() async {
        isSearching = true
        errorMessage = nil
        statusMessage = nil
        defer { isSearching = false }

        searchProvider = AppConfigIO.current().catalog.searchProvider

        do {
            persistCatalogSearchDefaults()
            let outcome = try await SupplierCatalogSearchService.search(
                query: query,
                inventory: inventory,
                provider: searchProvider
            )
            results = outcome.cards
            statusMessage = outcome.statusMessage
            if results.isEmpty {
                statusMessage = (statusMessage ?? "") + " · nessun risultato"
            }
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

    private func addCardToKiCad(_ card: CatalogMatchCard) {
        do {
            if let record = card.lcscRecord {
                let url = try KiCadExportService.appendToPersonalLibrary(record: record)
                kicadMessage = "Simbolo aggiunto a \(url.lastPathComponent)"
            } else {
                kicadMessage = "Serve un codice LCSC valido per KiCad."
            }
        } catch {
            kicadMessage = error.localizedDescription
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
    var onAddToKiCad: (() -> Void)? = nil

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
                title: card.usesInternalLCSCPlaceholder ? "CV interno" : "LCSC",
                code: card.lcscDisplayCode,
                tint: card.usesInternalLCSCPlaceholder ? .teal : .orange,
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
            if let onAddToKiCad, card.hasLCSC {
                Button("KiCad", action: onAddToKiCad)
                    .buttonStyle(.bordered)
                    .platformHelp("Aggiunge il simbolo alla libreria KiCad personale")
            }
            Button("Salva scheda", action: onImport)
                .buttonStyle(.bordered)
                .platformHelp("Salva la scheda tecnica con qty 0 — da ordinare, non in magazzino")
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

struct LCSCSearchResultsTable: View {
    let results: [CatalogMatchCard]
    let canAddToProject: Bool
    let onImport: (CatalogMatchCard) -> Void
    let onAddToProject: (CatalogMatchCard) -> Void
    let onAddToKiCad: (CatalogMatchCard) -> Void

    @State private var selectedCard: CatalogMatchCard?

    var body: some View {
        #if os(macOS)
        macTable
        #else
        iosList
        #endif
    }

    #if os(macOS)
    private var macTable: some View {
        Table(results) {
            TableColumn("Codice") { card in
                primaryCodeCell(for: card)
            }
            .width(min: 120, ideal: 160)

            TableColumn("MPN") { card in
                Text(card.mpn)
                    .font(.caption.monospaced())
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 180)

            TableColumn("Footprint") { card in
                Text(card.footprint)
                    .font(.caption)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Produttore") { card in
                Text(card.brand.isEmpty ? "—" : card.brand)
                    .font(.caption)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 140)

            TableColumn("Stock") { card in
                stockCell(for: card)
            }
            .width(min: 90, ideal: 110)

            TableColumn("") { card in
                rowActions(for: card)
            }
            .width(min: 180, ideal: 220)
        }
    }
    #endif

    private var iosList: some View {
        List(results) { card in
            Button {
                selectedCard = card
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        primaryCodeCell(for: card)
                        Spacer()
                        stockCell(for: card)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(card.mpn)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                    if !card.description.isEmpty {
                        Text(card.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack {
                        Text(card.footprint).font(.caption2)
                        Text("·").foregroundStyle(.tertiary)
                        Text(card.brand.isEmpty ? "—" : card.brand).font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    rowActions(for: card)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .sheet(item: $selectedCard) { card in
            NavigationStack {
                ScrollView {
                    CatalogMatchCardView(
                        card: card,
                        canAddToProject: canAddToProject,
                        onImport: { onImport(card); selectedCard = nil },
                        onAddToProject: { onAddToProject(card); selectedCard = nil },
                        onAddToKiCad: { onAddToKiCad(card) }
                    )
                    .padding(16)
                }
                .navigationTitle(card.mpn)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Chiudi") { selectedCard = nil }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func primaryCodeCell(for card: CatalogMatchCard) -> some View {
        HStack(spacing: 8) {
            if card.hasLCSC, let lcsc = card.lcscCode {
                codeChip(lcsc, tint: .orange)
            }
            if card.hasDigiKey, let dk = card.digikeyPartNumber {
                codeChip(dk, tint: .red)
            }
            if !card.hasLCSC && !card.hasDigiKey {
                Text("—")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func codeChip(_ code: String, tint: Color) -> some View {
        Button(code) {
            PlatformPasteboard.copy(code)
        }
        .buttonStyle(.plain)
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(tint)
    }

    @ViewBuilder
    private func lcscCell(for card: CatalogMatchCard) -> some View {
        primaryCodeCell(for: card)
    }

    @ViewBuilder
    private func stockCell(for card: CatalogMatchCard) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if card.hasLCSC, let stock = card.lcscStock {
                Text("LCSC \(stock)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(stock > 0 ? Color.orange : Color.secondary)
            }
            if card.hasDigiKey, let stock = card.digikeyStock {
                Text("DK \(stock)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(stock > 0 ? Color.red : Color.secondary)
            }
            if !card.hasLCSC && !card.hasDigiKey {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func rowActions(for card: CatalogMatchCard) -> some View {
        HStack(spacing: 8) {
            Button("Salva") { onImport(card) }
                .buttonStyle(.bordered)
            if card.hasLCSC {
                Button("KiCad") { onAddToKiCad(card) }
                    .buttonStyle(.bordered)
            }
            Button("Progetto") { onAddToProject(card) }
                .buttonStyle(.borderedProminent)
                .disabled(!canAddToProject)
        }
        .controlSize(.small)
    }
}

private struct CatalogLookupChrome: ViewModifier {
    let embeddedInNavigation: Bool
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        if embeddedInNavigation {
            content
                .navigationTitle("Ricerca catalogo")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } else {
            content
                .platformSheetFrame(minWidth: 760, minHeight: 560)
                .navigationTitle("Trova componente — progettazione")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Chiudi") { dismiss() }
                    }
                }
        }
    }
}
