import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Identifiable {
    case inventory
    case catalog
    case projects
    case alerts
    case search
    case kicadLibrary
    case settings

    var id: String { rawValue }

    /// I tre posti di tutti i giorni; il resto sta sotto "Altro". Impostazioni in fondo.
    static var mainCases: [AppSection] { [.search, .projects, .inventory] }
    static var moreCases: [AppSection] { [.alerts, .catalog, .kicadLibrary] }
    static var navigableCases: [AppSection] { mainCases + moreCases }

    var title: String {
        switch self {
        case .inventory: String(localized: "Magazzino")
        case .catalog: String(localized: "Per categoria")
        case .projects: String(localized: "Progetti")
        case .alerts: String(localized: "Scorte basse")
        case .search: String(localized: "Cerca")
        case .kicadLibrary: String(localized: "Libreria KiCad")
        case .settings: String(localized: "Impostazioni")
        }
    }

    var icon: String {
        switch self {
        case .inventory: "tray.full"
        case .catalog: "square.grid.2x2"
        case .projects: "folder"
        case .alerts: "exclamationmark.triangle"
        case .search: "magnifyingglass"
        case .kicadLibrary: "books.vertical"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    var body: some View {
        #if os(macOS)
        MacContentShell()
        #else
        PadContentView()
        #endif
    }
}

private struct MacContentShell: View {
    @Query(sort: \Component.quantity) private var components: [Component]
    @State private var section: AppSection = .search

    private var lowStockCount: Int {
        components.filter(\.isLowStock).count
    }

    var body: some View {
        HStack(spacing: 0) {
            AppSectionSidebar(selection: $section, lowStockCount: lowStockCount)
                .frame(width: AppLayout.sectionSidebarWidth)

            Divider()

            AppSectionContent(section: section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppSectionSidebar: View {
    @Binding var selection: AppSection
    var lowStockCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ComponentVault")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)

            ForEach(AppSection.mainCases) { item in
                sidebarButton(item)
            }
            sidebarGroup("Altro", items: AppSection.moreCases)

            Divider()
                .padding(.vertical, 4)

            sidebarButton(.settings)

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.bar)
    }

    private func sidebarGroup(_ title: LocalizedStringKey, items: [AppSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            ForEach(items) { item in
                sidebarButton(item)
            }
        }
    }

    @ViewBuilder
    private func sidebarButton(_ item: AppSection) -> some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 8) {
                Label(item.title, systemImage: item.icon)
                    .font(.subheadline)
                Spacer(minLength: 0)
                if item == .alerts, lowStockCount > 0 {
                    Text("\(lowStockCount)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                }
            }
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
}

struct InventoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var components: [Component]

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private var lcscRequestDelayMs: Int { AppConfigIO.current().lcsc.requestDelayMs }

    @State private var store: ComponentStore?
    @State private var selection: Component?
    @State private var filter = ComponentFilter()
    @State private var showImportPanel = false
    @State private var showScanImport = false
    @State private var showExport = false
    @State private var exportDocument = CSVDocument()
    @State private var enrichProgress: (label: String, current: Int, total: Int)?
    @State private var importError: String?
    @State private var filteredComponents: [Component] = []

    private func refreshFilteredComponents() {
        filteredComponents = filter.apply(to: components)
    }

    private var inventoryDetail: some View {
        Group {
            if let selected = selection {
                ComponentDetailView(component: selected, store: store) { replacement in
                    selection = replacement
                }
            } else if components.isEmpty {
                emptyState
            } else {
                ContentUnavailableView(
                    String(localized: "Seleziona un componente"),
                    systemImage: "cpu",
                    description: Text("Scegli un componente dalla lista.")
                )
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            inventorySidebar
        } detail: {
            inventoryDetail
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !components.isEmpty {
                FilterBar(filter: $filter, components: components)
            }
        }
        .navigationTitle("Inventario")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Ricarica") {
                    Task { await reloadInventory() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showScanImport = true
                } label: {
                    Label("Carica da etichetta", systemImage: "barcode.viewfinder")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImportPanel = true
                    } label: {
                        Label("Importa CSV", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        exportDocument = CSVDocument(text: ExportService.inventoryCSV(components: filteredComponents))
                        showExport = true
                    } label: {
                        Label("Esporta CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(filteredComponents.isEmpty)
                    Divider()
                    Button {
                        guard let store else { return }
                        Task {
                            enrichProgress = ("LCSC", 0, filteredComponents.count)
                            await store.enrichAllFromLCSC(
                                components: filteredComponents,
                                delayMs: lcscRequestDelayMs
                            ) { c, t in
                                enrichProgress = ("LCSC", c, t)
                            }
                            enrichProgress = nil
                        }
                    } label: {
                        Label("Arricchisci LCSC", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(filteredComponents.isEmpty || store?.isLoading == true)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        #endif
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
            refreshFilteredComponents()
        }
        .onChange(of: components.count) { _, _ in
            refreshFilteredComponents()
        }
        .onChange(of: filter.searchText) { _, _ in
            refreshFilteredComponents()
        }
        .onChange(of: filter.category) { _, _ in refreshFilteredComponents() }
        .onChange(of: filter.footprint) { _, _ in refreshFilteredComponents() }
        .onChange(of: filter.brand) { _, _ in refreshFilteredComponents() }
        .onChange(of: filter.tag) { _, _ in refreshFilteredComponents() }
        .onChange(of: filter.showLowStockOnly) { _, _ in refreshFilteredComponents() }
        .onChange(of: filter.showOutOfStockOnly) { _, _ in refreshFilteredComponents() }
        .onReceive(NotificationCenter.default.publisher(for: .importCSV)) { _ in
            showImportPanel = true
        }
        .sheet(isPresented: $showScanImport) {
            ScanImportView()
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

    @ViewBuilder
    private var inventoryToolbar: some View {
        #if os(macOS)
        HStack {
            Button("Ricarica") {
                Task { await reloadInventory() }
            }
            Button("Importa") { showImportPanel = true }
            Button("Etichetta") { showScanImport = true }
                .help("Carica da etichetta (lettore USB o codice)")
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
                        delayMs: lcscRequestDelayMs
                    ) { c, t in
                        enrichProgress = ("LCSC", c, t)
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
        #else
        HStack {
            Spacer()
            Text("\(filteredComponents.count) componenti")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        #endif
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
            refreshFilteredComponents()
        } catch {
            importError = error.localizedDescription
        }
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
                    refreshFilteredComponents()
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
                    if component.isToOrder {
                        Image(systemName: "cart.badge.clock")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .platformHelp("Da ordinare")
                    } else if component.isLowStock {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(component.quantity == 0 ? .red : .orange)
                    }
                }
                HStack(spacing: 6) {
                    ComponentCodesRow(component: component, compact: true)
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
            }

            Spacer()

            if let place = component.storageLabel {
                Label(place, systemImage: "archivebox")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .labelStyle(.titleAndIcon)
            }

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

/// Riga codici inventario CV e LCSC Cxxxxx.
struct ComponentCodesRow: View {
    let component: Component
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 5 : 8) {
            CodeChip(
                title: "CV",
                code: component.inventoryCode,
                tint: .teal,
                compact: compact
            )
            CodeChip(
                title: "LCSC",
                code: component.supplierLCSCCode ?? "—",
                tint: .orange,
                dimmed: component.supplierLCSCCode == nil,
                compact: compact,
                copyOnTap: component.supplierLCSCCode
            )
        }
    }
}

private struct CodeChip: View {
    let title: String
    let code: String
    let tint: Color
    var dimmed: Bool = false
    var compact: Bool = false
    var copyOnTap: String? = nil

    var body: some View {
        Group {
            if let copyOnTap, !copyOnTap.isEmpty {
                Button {
                    PlatformPasteboard.copy(copyOnTap)
                } label: {
                    chipContent
                }
                .buttonStyle(.plain)
                .platformHelp("Copia \(copyOnTap) per EasyEDA")
            } else {
                chipContent
            }
        }
    }

    private var chipContent: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
                .foregroundStyle(tint.opacity(dimmed ? 0.5 : 1))
            Text(code)
                .font(compact ? .caption2.monospaced() : .caption.monospaced())
                .foregroundStyle(dimmed ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(tint.opacity(dimmed ? 0.05 : 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
