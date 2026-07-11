import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var components: [Component]

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var store: ComponentStore?
    @State private var selection: Component?
    @State private var searchText = ""
    @State private var filterCategory = "Tutte"
    @State private var showImportPanel = false
    @State private var enrichProgress: (current: Int, total: Int)?
    @State private var importError: String?

    private var categories: [String] {
        let values = Set(components.map(\.category).filter { !$0.isEmpty })
        return ["Tutte"] + values.sorted()
    }

    private var filteredComponents: [Component] {
        components.filter { component in
            let matchesSearch = searchText.isEmpty ||
                component.lcscCode.localizedCaseInsensitiveContains(searchText) ||
                component.mpn.localizedCaseInsensitiveContains(searchText) ||
                component.componentDescription.localizedCaseInsensitiveContains(searchText) ||
                component.footprint.localizedCaseInsensitiveContains(searchText)

            let matchesCategory = filterCategory == "Tutte" || component.category == filterCategory
            return matchesSearch && matchesCategory
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selection {
                ComponentDetailView(component: selection, store: store)
            } else if components.isEmpty {
                emptyState
            } else {
                ContentUnavailableView(
                    "Seleziona un componente",
                    systemImage: "cpu",
                    description: Text("Scegli un componente dalla lista a sinistra.")
                )
            }
        }
        .navigationTitle("ComponentVault")
        .onAppear {
            if store == nil {
                store = ComponentStore(modelContext: modelContext)
            }
            if components.isEmpty {
                Task { await bootstrapIfNeeded() }
            }
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
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let enrichProgress {
                    ProgressView("Arricchimento LCSC \(enrichProgress.current)/\(enrichProgress.total)")
                        .padding()
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
        .alert("Errore import", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Creazione database…", systemImage: "externaldrive.badge.plus")
        } description: {
            if store?.isLoading == true {
                Text("Importazione da /Users/michelebigi/LCSC/json_full_data")
            } else {
                Text("Database non trovato.\n\nClicca per importare manualmente il CSV\noppure esegui:\npython3 Tools/lcsc_enrich.py")
            }
        } actions: {
            if store?.isLoading != true {
                Button("Importa CSV…") { showImportPanel = true }
                    .buttonStyle(.borderedProminent)
                Button("Ricarica database") { Task { await bootstrapIfNeeded() } }
            }
        }
    }

    private func bootstrapIfNeeded() async {
        guard let store, components.isEmpty else { return }
        do {
            let result = try await store.bootstrapFromDefaultLocation()
            hasCompletedOnboarding = true
            if selection == nil, let first = try? modelContext.fetch(
                FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)])
            ).first {
                selection = first
            }
            _ = result
        } catch {
            if !hasCompletedOnboarding {
                showImportPanel = true
            }
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
                    if selection == nil, let first = try? modelContext.fetch(
                        FetchDescriptor<Component>(sortBy: [SortDescriptor(\.lcscCode)])
                    ).first {
                        selection = first
                    }
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !components.isEmpty {
                HStack {
                    TextField("Cerca…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Picker("Categoria", selection: $filterCategory) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                .padding(8)
            }

            if components.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredComponents, selection: $selection) { component in
                    ComponentRowView(component: component)
                        .tag(component)
                }
            }

            toolbar
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 340)
    }

    private var toolbar: some View {
        HStack {
            Button("Importa CSV") { showImportPanel = true }
            Button("Aggiorna tutti LCSC") {
                guard let store else { return }
                Task {
                    enrichProgress = (0, filteredComponents.count)
                    await store.enrichAllFromLCSC(components: filteredComponents) { current, total in
                        enrichProgress = (current, total)
                    }
                    enrichProgress = nil
                }
            }
            .disabled(filteredComponents.isEmpty || store?.isLoading == true)

            Spacer()

            Text("\(filteredComponents.count) componenti")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(8)
        .background(.bar)
    }
}

struct ComponentRowView: View {
    let component: Component

    var body: some View {
        HStack(spacing: 10) {
            ComponentThumbnail(url: component.primaryImageURL)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(component.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(component.lcscCode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !component.footprint.isEmpty {
                    Text(component.footprint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
        .modelContainer(for: Component.self, inMemory: true)
}
