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
    @State private var exportDocument = CSVDocument()
    @State private var importResult: BOMImportResult?
    @State private var importError: String?
    @State private var selectedLCSC = ""
    @State private var addQuantity = 1
    @State private var addDesignator = ""

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

                TableColumn("MPN") { item in
                    Text(item.component?.mpn ?? "—")
                        .lineLimit(1)
                }

                TableColumn("Richiesti") { item in
                    Text("\(item.requiredQuantity)")
                        .monospacedDigit()
                }
                .width(70)

                TableColumn("Disponibili") { item in
                    Text("\(item.availableQuantity)")
                        .monospacedDigit()
                        .foregroundStyle(item.isAvailable ? Color.primary : Color.orange)
                }
                .width(80)

                TableColumn("Stato") { item in
                    StatusBadge(item: item)
                }
                .width(100)

                TableColumn("") { item in
                    Button(role: .destructive) {
                        try? projectStore?.removeItem(item, from: project)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .width(30)
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

                Button {
                    exportDocument = CSVDocument(text: ExportService.projectBOMCSV(project: project))
                    showExport = true
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
