import Foundation
import SwiftData

enum Persistence {
    static let schemaVersion = 2
    private static let versionKey = "ComponentVault.schemaVersion"

    static let schema = Schema([
        Component.self,
        ComponentParameter.self,
        StockMovement.self,
        Project.self,
        ProjectItem.self
    ])

    static func makeContainer() throws -> ModelContainer {
        resetStoreIfSchemaChanged()
        do {
            return try ModelContainer(for: schema)
        } catch {
            clearStoreFiles()
            return try ModelContainer(for: schema)
        }
    }

    private static func resetStoreIfSchemaChanged() {
        let stored = UserDefaults.standard.integer(forKey: versionKey)
        guard stored != schemaVersion else { return }
        clearStoreFiles()
        UserDefaults.standard.set(schemaVersion, forKey: versionKey)
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }

    private static func clearStoreFiles() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }

        let storeNames = [
            "default.store",
            "default.store-shm",
            "default.store-wal"
        ]

        for name in storeNames {
            let url = appSupport.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
