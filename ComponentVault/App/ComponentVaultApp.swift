import SwiftUI
import SwiftData

@main
struct ComponentVaultApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try Persistence.makeContainer()
        } catch {
            fatalError("Impossibile avviare il database: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
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
    }
}

extension Notification.Name {
    static let importCSV = Notification.Name("ComponentVault.importCSV")
    static let exportInventory = Notification.Name("ComponentVault.exportInventory")
}
