import SwiftUI
import SwiftData
import AppKit

@main
struct ComponentVaultApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try Persistence.makeContainer()
        } catch {
            fatalError("Impossibile avviare il database: \(error.localizedDescription)")
        }

        DispatchQueue.main.async {
            Self.applyApplicationIcon()
        }
    }

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

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(
                    minWidth: AppLayout.minWidth,
                    minHeight: AppLayout.minHeight
                )
        }
        .defaultSize(
            width: AppLayout.defaultWidth,
            height: AppLayout.defaultHeight
        )
        .windowResizability(.contentMinSize)
        .modelContainer(container)
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

        Settings {
            SettingsView()
        }
        .modelContainer(container)
    }
}

extension Notification.Name {
    static let importCSV = Notification.Name("ComponentVault.importCSV")
    static let exportInventory = Notification.Name("ComponentVault.exportInventory")
}
