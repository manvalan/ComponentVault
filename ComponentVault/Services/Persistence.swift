import Foundation
import SwiftData

enum Persistence {
    static let schemaVersion = 3
    private static let versionKey = "ComponentVault.schemaVersion"

    enum BootstrapError: LocalizedError {
        case containerUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .containerUnavailable(let detail):
                "Impossibile aprire il database locale: \(detail)"
            }
        }
    }

    static let schema = Schema([
        Component.self,
        ComponentParameter.self,
        StockMovement.self,
        StockMovement.self,
        Project.self,
        ProjectItem.self
    ])

    static func makeContainer() throws -> ModelContainer {
        applySchemaVersionMigration()
        do {
            return try openContainer()
        } catch {
            backupStoreFiles(tag: "open-failure")
            clearStoreFiles()
            do {
                return try openContainer()
            } catch {
                throw BootstrapError.containerUnavailable(error.localizedDescription)
            }
        }
    }

    /// Reset manuale da schermata di errore avvio.
    static func resetStoreForRecovery() {
        backupStoreFiles(tag: "user-recovery")
        clearStoreFiles()
        UserDefaults.standard.set(schemaVersion, forKey: versionKey)
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }

    private static func openContainer() throws -> ModelContainer {
        try ModelContainer(for: schema)
    }

    /// Migrazioni note tra versioni. Solo gli upgrade incompatibili azzerano il database.
    private static func applySchemaVersionMigration() {
        let stored = UserDefaults.standard.integer(forKey: versionKey)
        guard stored != schemaVersion else { return }

        let hasStore = storeExists()

        // v2 → v3: aggiunto lcscSupplierCode (opzionale) — SwiftData migra senza wipe.
        if stored == 2 && schemaVersion == 3 {
            if hasStore { backupStoreFiles(tag: "v2-v3") }
            UserDefaults.standard.set(schemaVersion, forKey: versionKey)
            return
        }

        // Store esistente ma versione mai scritta (upgrade da build precedente).
        if stored == 0 && hasStore {
            backupStoreFiles(tag: "legacy-v\(schemaVersion)")
            UserDefaults.standard.set(schemaVersion, forKey: versionKey)
            return
        }

        // Prima installazione: nessun file da preservare.
        if stored == 0 && !hasStore {
            UserDefaults.standard.set(schemaVersion, forKey: versionKey)
            return
        }

        // Upgrade incompatibile: backup poi wipe.
        if hasStore {
            backupStoreFiles(tag: "wipe-v\(stored)-to-v\(schemaVersion)")
        }
        clearStoreFiles()
        UserDefaults.standard.set(schemaVersion, forKey: versionKey)
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }

    private static func storeDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static func storeExists() -> Bool {
        guard let url = storeDirectory()?.appendingPathComponent("default.store") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func backupStoreFiles(tag: String) {
        guard let dir = storeDirectory() else { return }
        let stamp = backupTimestamp()
        let backupDir = dir
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("\(tag)-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            let source = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.copyItem(at: source, to: backupDir.appendingPathComponent(name))
        }
    }

    private static func backupTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func clearStoreFiles() {
        guard let dir = storeDirectory() else { return }

        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
