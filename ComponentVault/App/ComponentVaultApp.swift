import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class AppContainer {
    private(set) var modelContainer: ModelContainer?
    private(set) var startupError: String?

    init() {
        reload()
    }

    func reload() {
        do {
            modelContainer = try Persistence.makeContainer()
            startupError = nil
        } catch {
            modelContainer = nil
            startupError = error.localizedDescription
        }
    }

    func resetStoreAndReload() {
        Persistence.resetStoreForRecovery()
        reload()
    }
}

@main
struct ComponentVaultApp: App {
    @State private var appContainer = AppContainer()

    init() {
        #if os(macOS)
        DispatchQueue.main.async {
            Self.applyApplicationIcon()
        }
        #endif
    }

    #if os(macOS)
    private static func applyApplicationIcon() {
        if let icon = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = icon
            return
        }

        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    #endif

    var body: some Scene {
        mainWindow
        #if os(macOS)
        settingsWindow
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            Group {
                if appContainer.modelContainer != nil {
                    RootView()
                } else {
                    DatabaseStartupErrorView(
                        message: appContainer.startupError ?? "Database locale non disponibile.",
                        onReset: { appContainer.resetStoreAndReload() }
                    )
                }
            }
            .platformWindowMinSize(width: AppLayout.minWidth, height: AppLayout.minHeight)
        }
        #if os(macOS)
        .defaultSize(
            width: AppLayout.defaultWidth,
            height: AppLayout.defaultHeight
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Importa CSV…") {
                    NotificationCenter.default.post(name: .importCSV, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .importExport) {
                Button("Esporta inventario…") {
                    NotificationCenter.default.post(name: .exportInventory, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        #endif
        .modelContainer(appContainer.modelContainer ?? Self.ephemeralContainer)
    }

    #if os(macOS)
    private var settingsWindow: some Scene {
        Settings {
            if appContainer.modelContainer != nil {
                SettingsView()
                    .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 760)
            } else {
                DatabaseStartupErrorView(
                    message: appContainer.startupError ?? "Database locale non disponibile.",
                    onReset: { appContainer.resetStoreAndReload() }
                )
                .frame(minWidth: 560, minHeight: 400)
            }
        }
        .modelContainer(appContainer.modelContainer ?? Self.ephemeralContainer)
    }
    #endif

    /// Container in-memory solo per soddisfare SwiftUI quando il database disco non è disponibile.
    private static let ephemeralContainer: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: Persistence.schema, configurations: config)
    }()
}

struct DatabaseStartupErrorView: View {
    let message: String
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Database non disponibile")
                .font(.title2.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Text("Un backup del database precedente è in Application Support/backups/ se disponibile.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("Riprova") { onReset() }
                    .buttonStyle(.borderedProminent)
                #if os(macOS)
                Button("Esci") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.bordered)
                #endif
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Notification.Name {
    static let importCSV = Notification.Name("ComponentVault.importCSV")
    static let exportInventory = Notification.Name("ComponentVault.exportInventory")
    static let openSettings = Notification.Name("ComponentVault.openSettings")
}
