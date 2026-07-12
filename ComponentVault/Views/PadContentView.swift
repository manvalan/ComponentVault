import SwiftUI

/// Shell iPad: TabView con le stesse sezioni del Mac, senza sidebar fissa.
struct PadContentView: View {
    @State private var section: AppSection = .inventory

    var body: some View {
        TabView(selection: $section) {
            InventoryView()
                .tabItem { Label(AppSection.inventory.title, systemImage: AppSection.inventory.icon) }
                .tag(AppSection.inventory)

            CatalogView()
                .tabItem { Label(AppSection.catalog.title, systemImage: AppSection.catalog.icon) }
                .tag(AppSection.catalog)

            ProjectsView()
                .tabItem { Label(AppSection.projects.title, systemImage: AppSection.projects.icon) }
                .tag(AppSection.projects)

            LowStockView()
                .tabItem { Label(AppSection.alerts.title, systemImage: AppSection.alerts.icon) }
                .tag(AppSection.alerts)

            SettingsView()
                .tabItem { Label(AppSection.settings.title, systemImage: AppSection.settings.icon) }
                .tag(AppSection.settings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            section = .settings
        }
        #endif
    }
}
