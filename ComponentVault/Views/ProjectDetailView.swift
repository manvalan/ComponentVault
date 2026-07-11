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
    @State private var exportDocument = CSVDocument()
    @State private var digikeyExportDocument = CSVDocument()
    @State private var importResult: BOMImportResult?
    @State private var importError: String?
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

    var body: some View {
        VStack(spacing: 0) {
            summaryBar

            Table(project.items.sorted(by: { $0.designator < $1.designator })) {
                TableColumn("Ref") { item in
                    Text(item.designator.isEmpty ? "—" : item.designator)
                        .font(.caption.monospaced())
                }
                .width(60)

                TableColumn("LCSC") { item in
                    Text(item.component?.lcscCode ?? "—")
                        .font(.caption.monospaced())
                }
                .width(90)

                TableColumn("DigiKey") { item in
                    let pn = item.component?.digikeyPartNumber
                        ?? item.component?.digikeySnapshot?.digikeyPartNumber
                    Text(pn?.isEmpty == false ? pn! : "—")
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
                    if let line = bomSummary.lines.first(where: { $0.item.persistentModelID == item.persistentModelID }),
                       let unit = line.unitPrice,
                       let currency = line.currency {
                        Text(String(format: "%.3f %@", unit, currency))
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                    }
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
                        if let line = bomSummary.lines.first(where: { $0.item.persistentModelID == item.persistentModelID }),
                           line.isObsolete {
                            ObsoleteBadge()
                        }
                    }
                }
                .width(130)

                TableColumn("") { item in
                    HStack(spacing: 4) {
                        if let line = bomSummary.lines.first(where: { $0.item.persistentModelID == item.persistentModelID }),
                           line.isObsolete {
                            Button {
                                Task { await loadSubstitutes(for: item) }
                            } label: {
                                Image(systemName: "arrow.triangle.swap")
                            }
                            .buttonStyle(.borderless)
                            .help("Cerca sostituti DigiKey")
                        }

                        Button(role: .destructive) {
                            try? projectStore?.removeItem(item, from: project)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .width(56)
            }
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
                        digikeyExportDocument = CSVDocument(text: ExportService.projectBOMDigiKeyCSV(project: project))
                        showDigiKeyExport = true
                    } label: {
                        Label("BOM DigiKey (costi)", systemImage: "dollarsign.circle")
                    }
                } label: {
                    Label("Esporta BOM", systemImage: "square.and.arrow.up")
                }

                Button {
                    guard let store else { return }
                    try? projectStore?.reserveForProject(project, store: store)
                } label: {
                    Label("Riserva stock", systemImage: "minus.circle")
                }
                .help("Scala le quantità dall'inventario per i componenti disponibili")
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

    private var summaryBar: some View {
        HStack(spacing: 16) {
            SummaryPill(title: "Righe", value: "\(project.totalItems)", color: .blue)
            SummaryPill(title: "Mancanti", value: "\(project.missingCount)", color: project.missingCount > 0 ? .orange : .green)
            SummaryPill(title: "Scorta bassa", value: "\(project.lowStockCount)", color: project.lowStockCount > 0 ? .yellow : .green)

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
                    Text("\(c.lcscCode) — \(c.displayTitle)").tag(c.lcscCode)
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
