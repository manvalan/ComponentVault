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

    var body: some View {
        VStack(spacing: 0) {
            summaryBar

            #if os(macOS)
            bomTable
            #else
            bomList
            #endif
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showAddComponent = true
                } label: {
                    Label("Aggiungi", systemImage: "plus")
                }

                Button {
                    showImportBOM = true
                } label: {
                    Label("Importa BOM", systemImage: "square.and.arrow.down")
                }

                Menu {
                    Button {
                        exportDocument = CSVDocument(text: ExportService.projectBOMCSV(project: project))
                        showExport = true
                    } label: {
                        Label("BOM inventario", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        easyEDAExportDocument = CSVDocument(text: ExportService.projectBOMEasyEDACSV(project: project))
                        showEasyEDAExport = true
                    } label: {
                        Label("BOM EasyEDA / JLC", systemImage: "square.grid.2x2")
                    }
                    .disabled(easyEDAReadyCount == 0)

                    Button {
                        easyEDAMissingExportDocument = CSVDocument(text: ExportService.projectBOMMissingEasyEDACSV(project: project))
                        showEasyEDAMissingExport = true
                    } label: {
                        Label("Da ordinare (mancanti stock)", systemImage: "cart")
                    }

                    Button {
                        digikeyExportDocument = CSVDocument(text: ExportService.projectBOMDigiKeyCSV(project: project))
                        showDigiKeyExport = true
                    } label: {
                        Label("BOM DigiKey (costi)", systemImage: "dollarsign.circle")
                    }
                } label: {
                    Label("Esporta BOM", systemImage: "square.and.arrow.up")
                }

                Button {
                    Task { await resolveLCSCForEasyEDA() }
                } label: {
                    if isResolvingLCSC {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Risolvi LCSC", systemImage: "number")
                    }
                }
                .disabled(isResolvingLCSC || store == nil || easyEDAMissingCount == 0)
                .platformHelp("Cerca codici Cxxxxx LCSC dal MPN per EasyEDA")

                Button {
                    guard let store else { return }
                    try? projectStore?.reserveForProject(project, store: store)
                } label: {
                    Label("Riserva stock", systemImage: "minus.circle")
                }
                .platformHelp("Scala le quantità dall'inventario per i componenti disponibili")
            }
        }
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
        }
        .sheet(isPresented: $showAddComponent) {
            addComponentSheet
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

    #if os(macOS)
    private var bomTable: some View {
        Table(sortedItems) {
            TableColumn("Ref") { item in
                Text(item.designator.isEmpty ? "—" : item.designator)
                    .font(.caption.monospaced())
            }
            .width(60)

            TableColumn("CV") { item in
                Text(item.component?.inventoryCode ?? "—")
                    .font(.caption.monospaced())
            }
            .width(100)

            TableColumn("LCSC") { item in
                lcscCell(for: item)
            }
            .width(90)

            TableColumn("DigiKey") { item in
                Text(digiKeyPart(for: item))
                    .font(.caption.monospaced())
                    .lineLimit(1)
            }
            .width(100)

            TableColumn("MPN") { item in
                Text(item.component?.mpn ?? "—")
                    .lineLimit(1)
            }

            TableColumn("Richiesti") { item in
                Text("\(item.requiredQuantity)")
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("Prezzo DK") { item in
                Text(priceLabel(for: item))
                    .font(.caption.monospacedDigit())
            }
            .width(100)

            TableColumn("Disponibili") { item in
                Text("\(item.availableQuantity)")
                    .monospacedDigit()
                    .foregroundStyle(item.isAvailable ? Color.primary : Color.orange)
            }
            .width(80)

            TableColumn("Stato") { item in
                HStack(spacing: 4) {
                    StatusBadge(item: item)
                    if item.component?.hasValidLCSCCode == true {
                        EasyEDABadge()
                    }
                    if isObsolete(item) { ObsoleteBadge() }
                }
            }
            .width(150)

            TableColumn("") { item in
                bomRowActions(for: item)
            }
            .width(56)
        }
    }
    #endif

    #if os(iOS)
    private var bomList: some View {
        List {
            ForEach(Array(sortedItems.enumerated()), id: \.element.persistentModelID) { _, item in
                bomRowContent(for: item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            try? projectStore?.removeItem(item, from: project)
                        } label: {
                            Label("Elimina", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func bomRowContent(for item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.designator.isEmpty ? "—" : item.designator)
                    .font(.caption.monospaced().weight(.semibold))
                Spacer()
                bomRowActions(for: item)
            }
            HStack(spacing: 8) {
                Text(item.component?.inventoryCode ?? "—")
                    .font(.caption2.monospaced())
                if let lcsc = item.component?.supplierLCSCCode {
                    Button(lcsc) {
                        PlatformPasteboard.copy(lcsc)
                    }
                    .font(.caption2.monospaced())
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                } else {
                    Text("—")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Text(digiKeyPart(for: item))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(item.component?.mpn ?? "—")
                .font(.caption)
                .lineLimit(1)
            HStack {
                Text("Rich. \(item.requiredQuantity)")
                Text("Disp. \(item.availableQuantity)")
                    .foregroundStyle(item.isAvailable ? Color.primary : Color.orange)
                Text(priceLabel(for: item))
                    .foregroundStyle(.secondary)
                StatusBadge(item: item)
                if isObsolete(item) { ObsoleteBadge() }
            }
            .font(.caption2)
        }
        .padding(.vertical, 4)
    }
    #endif

    private func digiKeyPart(for item: ProjectItem) -> String {
        let pn = item.component?.digikeyPartNumber
            ?? item.component?.digikeySnapshot?.digikeyPartNumber
        return pn?.isEmpty == false ? pn! : "—"
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

    @ViewBuilder
    private func lcscCell(for item: ProjectItem) -> some View {
        if let lcsc = item.component?.supplierLCSCCode {
            Button(lcsc) {
                PlatformPasteboard.copy(lcsc)
            }
            .buttonStyle(.plain)
            .font(.caption.monospaced())
            .foregroundStyle(.orange)
            .platformHelp("Copia Cxxxxx per EasyEDA")
        } else {
            Text("—")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func bomRowActions(for item: ProjectItem) -> some View {
        HStack(spacing: 4) {
            if isObsolete(item) {
                Button {
                    Task { await loadSubstitutes(for: item) }
                } label: {
                    Image(systemName: "arrow.triangle.swap")
                }
                .buttonStyle(.borderless)
                .platformHelp("Cerca sostituti DigiKey")
            }

            Button(role: .destructive) {
                try? projectStore?.removeItem(item, from: project)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            SummaryPill(title: "Righe", value: "\(project.totalItems)", color: .blue)
            SummaryPill(title: "Mancanti", value: "\(project.missingCount)", color: project.missingCount > 0 ? .orange : .green)
            SummaryPill(title: "Scorta bassa", value: "\(project.lowStockCount)", color: project.lowStockCount > 0 ? .yellow : .green)

            SummaryPill(
                title: "EasyEDA",
                value: "\(easyEDAReadyCount)/\(project.totalItems)",
                color: easyEDAMissingCount > 0 ? .orange : .green
            )

            if obsoleteCount > 0 {
                SummaryPill(title: "Obsoleti", value: "\(obsoleteCount)", color: .red)
            }

            VStack(spacing: 2) {
                Text(bomSummary.formattedTotal)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(bomSummary.total != nil ? .purple : .secondary)
                Text("Costo DigiKey")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if bomSummary.missingLines > 0 {
                    Text("\(bomSummary.missingLines) senza prezzo")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
            if !project.projectDescription.isEmpty {
                Text(project.projectDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.bar)
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
