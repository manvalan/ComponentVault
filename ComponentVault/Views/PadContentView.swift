import SwiftUI
import SwiftData

/// Shell iPadOS: sidebar collassabile + area contenuto (stile app di sistema).
struct PadContentView: View {
    @Query(sort: \Component.quantity) private var components: [Component]

    @State private var section: AppSection? = .inventory
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var lowStockCount: Int {
        components.filter(\.isLowStock).count
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            if let section {
                AppSectionContent(section: section)
                    .id(section)
            } else {
                ContentUnavailableView(
                    "ComponentVault",
                    systemImage: "cpu",
                    description: Text("Seleziona una sezione dalla sidebar.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            section = .settings
        }
    }

    private var sidebar: some View {
        List(selection: $section) {
            Section {
                ForEach(AppSection.warehouseCases) { item in
                    sidebarRow(item)
                }
            } header: {
                Text("Magazzino")
            }

            Section {
                ForEach(AppSection.workspaceCases) { item in
                    sidebarRow(item)
                }
            } header: {
                Text("Catalogo & Progetti")
            }

            Section {
                ForEach(AppSection.toolCases) { item in
                    sidebarRow(item)
                }
            } header: {
                Text("Strumenti")
            }

            Section {
                sidebarRow(.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ComponentVault")
        .navigationSplitViewColumnWidth(
            min: AppLayout.padSidebarMin,
            ideal: AppLayout.padSidebarIdeal
        )
    }

    @ViewBuilder
    private func sidebarRow(_ item: AppSection) -> some View {
        Label {
            HStack {
                Text(item.title)
                Spacer(minLength: 8)
                if item == .alerts, lowStockCount > 0 {
                    Text("\(lowStockCount)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: item.icon)
        }
        .tag(item)
    }
}

/// Contenuto principale per ogni sezione dell'app.
struct AppSectionContent: View {
    let section: AppSection

    var body: some View {
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
            case .search:
                ComponentSearchView()
            case .kicadLibrary:
                KiCadLibraryView()
            case .settings:
                SettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Ricerca componenti nel catalogo fornitori (provider in Impostazioni).
struct ComponentSearchView: View {
    var body: some View {
        CatalogLookupView(embeddedInNavigation: true)
            .navigationTitle("Ricerca")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}
