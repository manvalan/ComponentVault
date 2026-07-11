import SwiftUI
import SwiftData

@main
struct ComponentVaultApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            Component.self,
            ComponentParameter.self
        ])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Importa CSV…") {
                    NotificationCenter.default.post(name: .importCSV, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let importCSV = Notification.Name("ComponentVault.importCSV")
}
