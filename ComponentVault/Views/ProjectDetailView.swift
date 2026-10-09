import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    @Bindable var project: Project
    var projectStore: ProjectStore?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var allComponents: [Component]

    @State private var store: ComponentStore?
    @State private var showAddComponent = false
    @State private var showImportBOM = false
    @State private var showExport = false
    @State private var showDigiKeyExport = false
    @State private var showEasyEDAExport = false
    @State private var showEasyEDAMissingExport = false
    @State private var exportDocument = CSVDocument()
    @State private var digikeyExportDocument = CSVDocument()
    @State private var easyEDAExportDocument = CSVDocument()
    @State private var easyEDAMissingExportDocument = CSVDocument()
    @State private var importResult: BOMImportResult?
    @State private var importError: String?
    @State private var isResolvingLCSC = false
    @State private var lcscResolveMessage: String?
    @State private var selectedLCSC = ""
    @State private var addQuantity = 1
    @State private var addDesignator = ""
    @State private var substituteItem: ProjectItem?
    @State private var substitutes: [DigiKeyCrossReference] = []
    @State private var isLoadingSubstitutes = false
    @State private var substituteError: String?
    @State private var showKiCadCheck = false
    @State private var showKiCadFetch = false
    @State private var focus: BOMFocus?
    @State private var library = KiCadLibraryStore.shared

    private var bomSummary: BOMCostSummary {
        BOMPricingService.digikeyCostSummary(for: project)
    }

    private var obsoleteCount: Int {
        bomSummary.lines.filter(\.isObsolete).count
    }

    private var easyEDAReadyCount: Int {
        EasyEDAService.easyEDAReadyCount(for: project)
    }

    private var easyEDAMissingCount: Int {
        EasyEDAService.projectItemsMissingLCSC(project).count
    }

    private var sortedItems: [ProjectItem] {
        project.items.sorted { $0.designator < $1.designator }
    }

    private func kicadMatch(_ item: ProjectItem) -> KiCadLibraryMatch {
        guard let component = item.component else { return .noPartNumber }
        return library.match(mpn: component.mpn, lcsc: component.supplierLCSCCode)
    }

    private func isMissingInKiCad(_ item: ProjectItem) -> Bool {
        if case .missing = kicadMatch(item) { return !(item.component?.mpn.isEmpty ?? true) }
        return false
    }

    private func hasPrice(_ item: ProjectItem) -> Bool {
        bomSummary.lines.first(where: { $0.item.persistentModelID == item.persistentModelID })?.unitPrice != nil
    }

    private var stockReadyCount: Int { project.items.filter(\.isAvailable).count }

    private var kicadReadyCount: Int {
        project.items.filter { if case .present = kicadMatch($0) { true } else { false } }.count
    }

    /// Componenti distinti (per MPN) da scaricare nella libreria KiCad.
    private var kicadMissingItems: [KiCadFetchItem] {
        var seen = Set<String>()
        var result: [KiCadFetchItem] = []
        for item in sortedItems where isMissingInKiCad(item) {
            guard let component = item.component, seen.insert(component.mpn.uppercased()).inserted else { continue }
            let refs = sortedItems.filter { $0.component?.mpn == component.mpn }.map(\.designator)
            result.append(KiCadFetchItem(
                mpn: String(component.mpn.prefix(128)),
                lcsc: component.supplierLCSCCode,
                ref: String(refs.joined(separator: ",").prefix(64)),
                funzione: String(component.category.prefix(256))
            ))
        }
        return result
    }

    private var visibleItems: [ProjectItem] {
        switch focus {
        case nil: sortedItems
        case .stock: sortedItems.filter { !$0.isAvailable }
        case .kicad: sortedItems.filter { if case .present = kicadMatch($0) { false } else { true } }
        case .price: sortedItems.filter { !hasPrice($0) }
        }
    }

    var body: some View {
        List {
            Section {
                healthHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if visibleItems.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                }
                ForEach(visibleItems, id: \.persistentModelID) { item in
                    BOMRow(item: item, kicad: kicadMatch(item), price: hasPrice(item) ? priceLabel(for: item) : nil)
                        .contextMenu { rowMenu(for: item) }
                        #if os(iOS)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                try? projectStore?.removeItem(item, from: project)
                            } label: {
                                Label("Elimina", systemImage: "trash")
                            }
                            if isObsolete(item) {
                                Button {
                                    Task { await loadSubstitutes(for: item) }
                                } label: {
                                    Label("Sostituti", systemImage: "arrow.triangle.swap")
                                }
                                .tint(.indigo)
                            }
                        }
                        #endif
                }
            } header: {
                if let focus {
                    HStack {
                        Text("\(focus.title): da completare")
                        Spacer()
                        Button("Mostra tutto") { withAnimation(.snappy) { self.focus = nil } }
                            .font(.caption)
                    }
                } else {
                    Text("\(project.totalItems) righe")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            primaryAction
        }
        .navigationTitle(project.name)
        .task { await library.refresh() }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showAddComponent = true
                } label: {
                    Label("Aggiungi", systemImage: "plus")
                }

                Menu {
                    Button {
                        showImportBOM = true
                    } label: {
                        Label("Importa BOM…", systemImage: "square.and.arrow.down")
                    }

                    Menu {
                        Button("BOM inventario") {
                            exportDocument = CSVDocument(text: ExportService.projectBOMCSV(project: project))
                            showExport = true
                        }
                        Button("BOM EasyEDA / JLC") {
                            easyEDAExportDocument = CSVDocument(text: ExportService.projectBOMEasyEDACSV(project: project))
                            showEasyEDAExport = true
                        }
                        .disabled(easyEDAReadyCount == 0)
                        Button("Da ordinare (mancanti stock)") { exportMissingStock() }
                        Button("BOM DigiKey (costi)") {
                            digikeyExportDocument = CSVDocument(text: ExportService.projectBOMDigiKeyCSV(project: project))
                            showDigiKeyExport = true
                        }
                    } label: {
                        Label("Esporta", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button {
                        showKiCadCheck = true
                    } label: {
                        Label("Libreria KiCad…", systemImage: "books.vertical")
                    }

                    Button {
                        Task { await resolveLCSCForEasyEDA() }
                    } label: {
                        Label("Risolvi codici LCSC", systemImage: "number")
                    }
                    .disabled(isResolvingLCSC || store == nil || easyEDAMissingCount == 0)

                    Button {
                        reserveStock()
                    } label: {
                        Label("Riserva stock", systemImage: "minus.circle")
                    }
                } label: {
                    Label("Altro", systemImage: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
        }
        .sheet(isPresented: $showAddComponent) {
            addComponentSheet
        }
        .sheet(isPresented: $showKiCadCheck) {
            ProjectKiCadCheckView(project: project)
        }
        .sheet(isPresented: $showKiCadFetch) {
            KiCadFetchView(items: kicadMissingItems, title: "Scarica in KiCad")
        }
        .sheet(item: $substituteItem) { item in
            substituteSheet(for: item)
        }
        .fileImporter(
            isPresented: $showImportBOM,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importBOMFile(result)
        }
        .fileExporter(
            isPresented: $showExport,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "\(project.name)-BOM.csv"
        ) { _ in }
        .fileExporter(
            isPresented: $showDigiKeyExport,
            document: digikeyExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "\(project.name)-BOM-DigiKey.csv"
        ) { _ in }
        .fileExporter(
            isPresented: $showEasyEDAExport,
            document: easyEDAExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "\(project.name)-EasyEDA-BOM.csv"
        ) { _ in }
        .fileExporter(
            isPresented: $showEasyEDAMissingExport,
            document: easyEDAMissingExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "\(project.name)-JLC-da-ordinare.csv"
        ) { _ in }
        .alert("Risoluzione LCSC", isPresented: .constant(lcscResolveMessage != nil)) {
            Button("OK") { lcscResolveMessage = nil }
        } message: {
            Text(lcscResolveMessage ?? "")
        }
        .alert("Import BOM completato", isPresented: .constant(importResult != nil)) {
            Button("OK") { importResult = nil }
        } message: {
            if let result = importResult {
                if result.missingLCSC.isEmpty {
                    Text("Importate \(result.imported) righe nel progetto.")
                } else {
                    Text("Importate \(result.imported) righe.\n\nNon in inventario (\(result.missingLCSC.count)):\n\(result.missingLCSC.prefix(8).joined(separator: ", "))\(result.missingLCSC.count > 8 ? "…" : "")")
                }
            }
        }
        .alert("Errore import BOM", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func loadSubstitutes(for item: ProjectItem) async {
        guard let provider = DigiKeyProvider.configured() else {
            substituteError = "DigiKey non configurato."
            substituteItem = item
            return
        }

        let partNumber = item.component?.digikeyPartNumber
            ?? item.component?.digikeySnapshot?.digikeyPartNumber
            ?? item.component?.mpn
            ?? ""

        guard !partNumber.isEmpty else {
            substituteError = "Nessun MPN o codice DigiKey per cercare sostituti."
            substituteItem = item
            return
        }

        isLoadingSubstitutes = true
        substituteItem = item
        substituteError = nil
        defer { isLoadingSubstitutes = false }

        do {
            substitutes = try await provider.fetchSubstitutions(
                partNumber: partNumber,
                referenceMPN: item.component?.mpn ?? partNumber
            )
        } catch {
            substituteError = error.localizedDescription
            substitutes = []
        }
    }

    private func substituteSheet(for item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sostituti DigiKey — \(item.designator)")
                .font(.headline)

            if let component = item.component {
                Text("\(component.mpn) · \(component.lcscCode)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if isLoadingSubstitutes {
                ProgressView("Ricerca sostituti…")
            } else if let substituteError {
                Text(substituteError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if substitutes.isEmpty {
                ContentUnavailableView("Nessun sostituto", systemImage: "arrow.triangle.swap")
            } else {
                List(substitutes) { sub in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sub.digikeyPartNumber.isEmpty ? sub.mpn : sub.digikeyPartNumber)
                            .font(.headline.monospaced())
                        Text(sub.description)
                            .font(.caption)
                            .lineLimit(2)
                        if let stock = sub.stock {
                            Text("Stock \(stock)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 200)
            }

            HStack {
                Spacer()
                Button("Chiudi") { substituteItem = nil }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }

    private func resolveLCSCForEasyEDA() async {
        guard let store else { return }
        isResolvingLCSC = true
        defer { isResolvingLCSC = false }
        do {
            let result = try await store.resolveLCSCForProject(project)
            lcscResolveMessage = "Trovati \(result.resolved) codici LCSC.\nAncora senza C: \(result.stillMissing)."
        } catch {
            lcscResolveMessage = error.localizedDescription
        }
    }

    private func importBOMFile(_ result: Result<[URL], Error>) {
        guard let projectStore else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                importResult = try projectStore.importBOM(from: url, into: project, components: allComponents)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private var healthHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(BOMFocus.allCases) { item in
                    HealthRing(
                        focus: item,
                        done: done(for: item),
                        total: project.totalItems,
                        isSelected: focus == item
                    ) {
                        withAnimation(.snappy) { focus = focus == item ? nil : item }
                    }
                }
            }
            HStack(spacing: 6) {
                Text(bomSummary.formattedTotal)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("costo BOM").foregroundStyle(.secondary)
                if obsoleteCount > 0 {
                    Text("· \(obsoleteCount) obsoleti").foregroundStyle(.red)
                }
            }
            .font(.subheadline)
            if !project.projectDescription.isEmpty {
                Text(project.projectDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func done(for focus: BOMFocus) -> Int {
        switch focus {
        case .stock: stockReadyCount
        case .kicad: kicadReadyCount
        case .price: bomSummary.pricedLines
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if project.items.isEmpty {
            ContentUnavailableView {
                Label("BOM vuota", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Importa un file BOM o aggiungi i componenti uno alla volta.")
            } actions: {
                Button("Importa BOM…") { showImportBOM = true }
            }
        } else {
            ContentUnavailableView(
                "Tutto a posto",
                systemImage: "checkmark.seal",
                description: Text("Nessuna riga da completare per \(focus?.title.lowercased() ?? "questo filtro").")
            )
        }
    }

    /// L'azione che serve adesso: prima la libreria KiCad, poi gli ordini, poi lo stock.
    @ViewBuilder
    private var primaryAction: some View {
        let kicadMissing = kicadMissingItems.count
        let stockMissing = project.items.filter { !$0.isAvailable && $0.component != nil }.count
        if project.items.isEmpty {
            EmptyView()
        } else if kicadMissing > 0 && SyncSettings.isConfigured {
            PrimaryActionBar(
                title: "Scarica \(kicadMissing) \(kicadMissing == 1 ? "componente" : "componenti") in KiCad",
                systemImage: "square.and.arrow.down.on.square",
                subtitle: library.index == nil ? "Indice libreria non ancora disponibile" : nil
            ) { showKiCadFetch = true }
        } else if stockMissing > 0 {
            PrimaryActionBar(
                title: "Ordina \(stockMissing) \(stockMissing == 1 ? "componente" : "componenti")",
                systemImage: "cart",
                subtitle: "Esporta la lista per JLC / LCSC"
            ) { exportMissingStock() }
        } else {
            PrimaryActionBar(
                title: "Riserva stock",
                systemImage: "checkmark.circle",
                subtitle: "Tutto disponibile: scala le quantità dal magazzino"
            ) { reserveStock() }
        }
    }

    @ViewBuilder
    private func rowMenu(for item: ProjectItem) -> some View {
        if let lcsc = item.component?.supplierLCSCCode {
            Button {
                PlatformPasteboard.copy(lcsc)
            } label: {
                Label("Copia \(lcsc)", systemImage: "doc.on.doc")
            }
        }
        if let mpn = item.component?.mpn, !mpn.isEmpty {
            Button {
                PlatformPasteboard.copy(mpn)
            } label: {
                Label("Copia MPN", systemImage: "doc.on.doc")
            }
        }
        if isObsolete(item) {
            Button {
                Task { await loadSubstitutes(for: item) }
            } label: {
                Label("Cerca sostituti", systemImage: "arrow.triangle.swap")
            }
        }
        Divider()
        Button(role: .destructive) {
            try? projectStore?.removeItem(item, from: project)
        } label: {
            Label("Elimina riga", systemImage: "trash")
        }
    }

    private func exportMissingStock() {
        easyEDAMissingExportDocument = CSVDocument(text: ExportService.projectBOMMissingEasyEDACSV(project: project))
        showEasyEDAMissingExport = true
    }

    private func reserveStock() {
        guard let store else { return }
        try? projectStore?.reserveForProject(project, store: store)
    }

    private func priceLabel(for item: ProjectItem) -> String {
        if let line = bomSummary.lines.first(where: { $0.item.persistentModelID == item.persistentModelID }),
           let unit = line.unitPrice,
           let currency = line.currency {
            return String(format: "%.3f %@", unit, currency)
        }
        return "—"
    }

    private func isObsolete(_ item: ProjectItem) -> Bool {
        bomSummary.lines.first(where: { $0.item.persistentModelID == item.persistentModelID })?.isObsolete == true
    }

    private var addComponentSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aggiungi componente al progetto")
                .font(.headline)

            Picker("Componente", selection: $selectedLCSC) {
                Text("Seleziona…").tag("")
                ForEach(allComponents, id: \.lcscCode) { c in
                    let lcsc = c.supplierLCSCCode ?? "—"
                    Text("\(c.inventoryCode) · \(lcsc) — \(c.displayTitle)").tag(c.lcscCode)
                }
            }

            HStack {
                Text("Quantità")
                Stepper("\(addQuantity)", value: $addQuantity, in: 1...999_999)
            }

            TextField("Designator (es. R1, C5)", text: $addDesignator)

            HStack {
                Spacer()
                Button("Annulla") { showAddComponent = false }
                Button("Aggiungi") {
                    guard let component = allComponents.first(where: { $0.lcscCode == selectedLCSC }) else { return }
                    try? projectStore?.addComponent(
                        component,
                        to: project,
                        quantity: addQuantity,
                        designator: addDesignator
                    )
                    showAddComponent = false
                    addQuantity = 1
                    addDesignator = ""
                    selectedLCSC = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedLCSC.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

extension ProjectItem: Identifiable {}

struct EasyEDABadge: View {
    var body: some View {
        Text("C")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15))
            .foregroundStyle(.orange)
            .clipShape(Capsule())
            .platformHelp("Codice LCSC pronto per EasyEDA")
    }
}

struct ObsoleteBadge: View {
    var body: some View {
        Text("OBS")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.15))
            .foregroundStyle(.red)
            .clipShape(Capsule())
    }
}

struct StatusBadge: View {
    let item: ProjectItem

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var label: String {
        if item.isAvailable { return "OK" }
        if item.isLowStock { return "Bassa" }
        return "Manca"
    }

    private var color: Color {
        if item.isAvailable { return .green }
        if item.isLowStock { return .orange }
        return .red
    }
}

struct SummaryPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
