import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LowStockView: View {
    @Query(sort: \Component.quantity) private var components: [Component]

    @State private var store: ComponentStore?
    @State private var selection: Component?
    @State private var showExport = false
    @State private var exportDocument = CSVDocument()

    @Environment(\.modelContext) private var modelContext

    private var lowStock: [Component] {
        (store ?? ComponentStore(modelContext: modelContext))
            .lowStockComponents(from: components)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if lowStock.isEmpty {
                    ContentUnavailableView(
                        "Tutto OK",
                        systemImage: "checkmark.circle",
                        description: Text("Nessun componente sotto soglia o esaurito.")
                    )
                } else {
                    List(lowStock, selection: $selection) { component in
                        LowStockRow(component: component)
                            .tag(component)
                    }
                }

                HStack {
                    Button("Esporta alert") {
                        exportDocument = CSVDocument(text: ExportService.lowStockCSV(components: components))
                        showExport = true
                    }
                    .disabled(lowStock.isEmpty)
                    Spacer()
                    Text("\(lowStock.count) alert")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.bar)
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if let selection {
                ComponentDetailView(component: selection, store: store)
            } else {
                ContentUnavailableView(
                    "Alert scorte",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Componenti esauriti o sotto la soglia minima.")
                )
            }
        }
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
        }
        .fileExporter(
            isPresented: $showExport,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "scorte-basse.csv"
        ) { _ in }
    }
}

struct LowStockRow: View {
    let component: Component

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.displayTitle)
                    .font(.headline)
                Text(component.lcscCode)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(component.quantity)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(component.quantity == 0 ? .red : .orange)
                if component.minQuantity > 0 {
                    Text("soglia \(component.minQuantity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
