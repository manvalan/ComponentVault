import Foundation
import SwiftData

/// Scambio di inventario e progetti tra dispositivi tramite la cartella condivisa.
/// Il database resta locale (SwiftData/SQLite su ogni dispositivo): nella cartella
/// ci sono solo due file JSON, fusi con "vince l'ultima modifica".
@MainActor
enum FolderSync {
    enum SyncError: LocalizedError {
        case noSharedFolder
        case unreachable

        var errorDescription: String? {
            switch self {
            case .noSharedFolder: String(localized: "Scegli prima una cartella condivisa.")
            case .unreachable: String(localized: "Cartella condivisa non raggiungibile.")
            }
        }
    }

    static var isAvailable: Bool { SharedFolder.url != nil }

    static var autoSyncOnLaunch: Bool { AppConfigIO.current().sync.autoOnLaunch }
    static var autoSyncIntervalMinutes: Int { AppConfigIO.current().sync.intervalMinutes }

    private static func syncDirectory() throws -> URL {
        guard let root = SharedFolder.url else { throw SyncError.noSharedFolder }
        guard SharedFolder.isReachable else { throw SyncError.unreachable }
        return root.appendingPathComponent("sync", isDirectory: true)
    }

    static func run(modelContext: ModelContext) async throws -> String {
        let dir = try syncDirectory()
        let componentsURL = dir.appendingPathComponent("components.json")
        let projectsURL = dir.appendingPathComponent("projects.json")

        let remoteComponents: [ComponentRecord] = try await read(componentsURL)
        let remoteProjects: [ProjectRecord] = try await read(projectsURL)

        let componentStore = ComponentStore(modelContext: modelContext)
        let componentResult = try componentStore.merge(remote: remoteComponents)
        let components = try modelContext.fetch(FetchDescriptor<Component>())
        let projectStore = ProjectStore(modelContext: modelContext)
        let projectResult = try projectStore.merge(remote: remoteProjects, components: components)

        // Dopo la fusione il database locale contiene tutto: lo si riscrive per gli altri.
        try await write(componentStore.allRecords(), to: componentsURL)
        try await write(projectStore.allRecords(), to: projectsURL)

        markSyncSuccess()
        return String(localized: "Componenti \(componentResult.summary) · Progetti \(projectResult.summary)")
    }

    private static func read<T: Decodable & Sendable>(_ url: URL) async throws -> [T] {
        try await Task.detached(priority: .utility) {
            guard CoordinatedFile.exists(url) else { return [] }
            return try JSONDecoder().decode([T].self, from: CoordinatedFile.read(url))
        }.value
    }

    private static func write<T: Encodable & Sendable>(_ records: [T], to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        try await Task.detached(priority: .utility) {
            try CoordinatedFile.write(data, to: url)
        }.value
    }

    private static func markSyncSuccess() {
        var config = AppConfigIO.current()
        config.sync.lastSyncAt = ISO8601DateFormatter().string(from: Date())
        _ = try? AppConfigIO.save(config)
    }
}

struct SyncBidirectionalResult: Sendable {
    let pushed: Int
    let pulled: Int
    let unchanged: Int

    var summary: String {
        "↑\(pushed) ↓\(pulled) =\(unchanged)"
    }
}

enum SyncDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String?) -> Date {
        guard let value, !value.isEmpty else { return .distantPast }
        return fractional.date(from: value)
            ?? standard.date(from: value)
            ?? .distantPast
    }
}
