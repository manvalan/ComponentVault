import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

@main
struct ComponentVaultApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try Persistence.makeContainer()
        } catch {
            fatalError("Impossibile avviare il database: \(error.localizedDescription)")
        }

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
            RootView()
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
        .modelContainer(container)
    }

    #if os(macOS)
    private var settingsWindow: some Scene {
        Settings {
            SettingsView()
                .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 760)
        }
        .modelContainer(container)
    }
    #endif
}

extension Notification.Name {
    static let importCSV = Notification.Name("ComponentVault.importCSV")
    static let exportInventory = Notification.Name("ComponentVault.exportInventory")
    static let openSettings = Notification.Name("ComponentVault.openSettings")
}
