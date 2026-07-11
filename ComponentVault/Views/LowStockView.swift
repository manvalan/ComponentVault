import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LowStockView: View {
    @Query(sort: \Component.quantity) private var components: [Component]

    @State private var store: ComponentStore?
    @State private var selection: Component?
    @State private var showExport = false
    @State private var showDigiKeyExport = false
    @State private var exportDocument = CSVDocument()
    @State private var digikeyExportDocument = CSVDocument()

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

                HStack(spacing: 12) {
                    Button("Esporta alert") {
                        exportDocument = CSVDocument(text: ExportService.lowStockCSV(components: components))
                        showExport = true
                    }
                    .disabled(lowStock.isEmpty)

                    Button("Esporta DigiKey") {
                        digikeyExportDocument = CSVDocument(text: ExportService.lowStockDigiKeyCSV(components: components))
                        showDigiKeyExport = true
                    }
                    .disabled(lowStock.isEmpty)
                    .help("CSV con stock, prezzo e suggerimento riordino DigiKey")

                    Spacer()
                    Text("\(lowStock.count) alert")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.bar)
            }
            .navigationSplitViewColumnWidth(
                min: AppLayout.alertsListMin,
                ideal: AppLayout.alertsListIdeal
            )
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
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
        }
        .fileExporter(
            isPresented: $showExport,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "scorte-basse.csv"
        ) { _ in }
        .fileExporter(
            isPresented: $showDigiKeyExport,
            document: digikeyExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "scorte-basse-digikey.csv"
        ) { _ in }
    }
}

struct LowStockRow: View {
    let component: Component

    private var reorderHint: String? {
        BOMPricingService.reorderSuggestion(for: component)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.displayTitle)
                    .font(.headline)
                Text(component.lcscCode)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !component.displayCommonName.isEmpty {
                    Text(component.displayCommonName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let reorderHint {
                    Text(reorderHint)
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .lineLimit(2)
                }
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
