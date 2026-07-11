import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Identifiable {
    case inventory
    case catalog
    case projects
    case alerts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inventory: "Inventario"
        case .catalog: "Catalogo"
        case .projects: "Progetti"
        case .alerts: "Alert"
        case .settings: "Impostazioni"
        }
    }

    var icon: String {
        switch self {
        case .inventory: "tray.full"
        case .catalog: "square.grid.2x2"
        case .projects: "folder"
        case .alerts: "exclamationmark.triangle"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @State private var section: AppSection = .inventory

    var body: some View {
        HStack(spacing: 0) {
            AppSectionSidebar(selection: $section)
                .frame(width: AppLayout.sectionSidebarWidth)

            Divider()

            Group {
                switch section {
                case .inventory:
                    InventoryView()
                case .catalog:
                    CatalogView()
                case .projects:
                    ProjectsView()
                case .alerts:
                    LowStockView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppSectionSidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ComponentVault")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)

            ForEach(AppSection.allCases) { item in
                Button {
                    selection = item
                } label: {
                    Label(item.title, systemImage: item.icon)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            selection == item ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.bar)
    }
}

struct InventoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var components: [Component]

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("lcscRequestDelayMs") private var lcscRequestDelayMs = 800.0
    @AppStorage("digikeyRequestDelayMs") private var digikeyRequestDelayMs = 800.0

    @State private var store: ComponentStore?
    @State private var selection: Component?
    @State private var filter = ComponentFilter()
    @State private var showImportPanel = false
    @State private var showExport = false
    @State private var exportDocument = CSVDocument()
    @State private var enrichProgress: (label: String, current: Int, total: Int)?
    @State private var importError: String?

    private var filteredComponents: [Component] {
        filter.apply(to: components)
    }

    var body: some View {
        NavigationSplitView {
            inventorySidebar
        } detail: {
            if let selection {
                ComponentDetailView(component: selection, store: store)
            } else if components.isEmpty {
                emptyState
            } else {
                ContentUnavailableView(
                    "Seleziona un componente",
                    systemImage: "cpu",
                    description: Text("Scegli un componente dalla lista.")
                )
            }
        }
        .navigationTitle("Inventario")
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importCSV)) { _ in
            showImportPanel = true
        }
        .fileImporter(
            isPresented: $showImportPanel,
            allowedContentTypes: [.commaSeparatedText, .plainText, .json],
            allowsMultipleSelection: false
        ) { result in
            importFile(result)
        }
        .fileExporter(
            isPresented: $showExport,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "inventario.csv"
        ) { _ in }
        .overlay(alignment: .bottom) {
            statusOverlay
        }
        .alert("Errore import", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var inventorySidebar: some View {
        VStack(spacing: 0) {
            if !components.isEmpty {
                FilterBar(filter: $filter, components: components)
            }

            if components.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredComponents, selection: $selection) { component in
                    ComponentRowView(component: component)
                        .tag(component)
                }
            }

            inventoryToolbar
        }
        .navigationSplitViewColumnWidth(
            min: AppLayout.inventoryListMin,
            ideal: AppLayout.inventoryListIdeal
        )
    }

    private var inventoryToolbar: some View {
        HStack {
            Button("Ricarica") {
                Task { await reloadInventory() }
            }
            Button("Importa") { showImportPanel = true }
            Button("Esporta") {
                exportDocument = CSVDocument(text: ExportService.inventoryCSV(components: filteredComponents))
                showExport = true
            }
            .disabled(filteredComponents.isEmpty)
            Button("LCSC") {
                guard let store else { return }
                Task {
                    enrichProgress = ("LCSC", 0, filteredComponents.count)
                    await store.enrichAllFromLCSC(
                        components: filteredComponents,
                        delayMs: Int(lcscRequestDelayMs)
                    ) { c, t in
                        enrichProgress = ("LCSC", c, t)
                    }
                    enrichProgress = nil
                }
            }
            .disabled(filteredComponents.isEmpty || store?.isLoading == true)

            Button("DigiKey") {
                guard let store else { return }
                let eligible = filteredComponents.filter { !$0.mpn.isEmpty }
                Task {
                    enrichProgress = ("DigiKey", 0, eligible.count)
                    _ = await store.enrichAllFromDigiKey(
                        components: filteredComponents,
                        delayMs: Int(digikeyRequestDelayMs)
                    ) { c, t in
                        enrichProgress = ("DigiKey", c, t)
                    }
                    enrichProgress = nil
                }
            }
            .disabled(filteredComponents.isEmpty || store?.isLoading == true)

            Spacer()
            Text("\(filteredComponents.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.bar)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        VStack(spacing: 8) {
            if let enrichProgress {
                ProgressView("\(enrichProgress.label) \(enrichProgress.current)/\(enrichProgress.total)")
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            if let status = store?.statusMessage {
                Text(status)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Creazione database…", systemImage: "externaldrive.badge.plus")
        } description: {
            if store?.isLoading == true {
                Text("Importazione da json_full_data…")
            } else if let importError {
                Text(importError)
            } else {
                Text("Clicca Ricarica o importa il CSV manualmente.")
            }
        } actions: {
            if store?.isLoading != true {
                Button("Importa CSV…") { showImportPanel = true }
                    .buttonStyle(.borderedProminent)
                Button("Ricarica") { Task { await reloadInventory() } }
            }
        }
    }

    private func reloadInventory() async {
        guard let store else { return }
        do {
            _ = try await store.bootstrapFromDefaultLocation()
            hasCompletedOnboarding = true
            if selection == nil {
                selection = try? modelContext.fetch(
                    FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)])
                ).first
            }
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    private func bootstrapIfNeeded() async {
        await reloadInventory()
    }

    private func importFile(_ result: Result<[URL], Error>) {
        guard let store else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await store.importCSV(from: url)
                    hasCompletedOnboarding = true
                    if selection == nil {
                        selection = try? modelContext.fetch(
                            FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)])
                        ).first
                    }
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

struct ComponentRowView: View {
    let component: Component

    var body: some View {
        HStack(spacing: 10) {
            ComponentThumbnail(url: component.primaryImageURL)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(component.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if component.isLowStock {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(component.quantity == 0 ? .red : .orange)
                    }
                }
                HStack(spacing: 6) {
                    Text(component.lcscCode)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if !component.value.isEmpty && component.value != "N/A" {
                        Text(component.value)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !component.displayCommonName.isEmpty {
                    Text(component.displayCommonName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !component.footprint.isEmpty {
                    Text(component.footprint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let comparison = component.supplierComparison {
                    Text(comparison.summary)
                        .font(.caption2)
                        .foregroundStyle(comparison.cheaper == .lcsc ? .orange : .red)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("\(component.quantity)")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(component.quantity > 0 ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(component.quantity > 0 ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Component.self, Project.self], inMemory: true)
}
