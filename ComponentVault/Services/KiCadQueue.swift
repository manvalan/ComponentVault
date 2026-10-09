import Foundation

// MARK: - Richieste per la libreria KiCad dell'utente, senza server
//
// L'app scrive soltanto "aggiungi questi componenti" nella cartella condivisa:
// il download da SnapEDA/UltraLibrarian/EasyEDA lo esegue il worker sul Mac con
// KiCad (mikylab_kikad_library/scripts/fetch_worker.py), l'unico che conosce le
// credenziali dei fornitori. Il worker risponde nella stessa cartella.
//
//     kicad/jobs/<uuid>/request.json   scritto dall'app
//     kicad/jobs/<uuid>/status.json    scritto dal worker (assente = in coda)
//     kicad/jobs/<uuid>/<nome>.zip     file KiCad · <nome>.png render 3D

struct KiCadFetchItem: Codable, Sendable {
    var mpn: String
    var lcsc: String?
    var ref: String = ""
    var funzione: String = ""
    var nome: String?
    var categoria: String?
}

struct KiCadFetchModel3D: Decodable, Sendable {
    let status: String
    let messages: [String]?
}

struct KiCadFetchComponent: Decodable, Sendable, Identifiable {
    let name: String
    let mpn: String?
    let status: String
    let source: String?
    let detail: String?
    let files: [String: String]?
    let model3d: [KiCadFetchModel3D]?

    var id: String { name }
    var kicadFile: String? { files?["kicad"] }
    var renderFile: String? { files?["render"] }
    var needsModelReview: Bool { model3d?.contains { $0.status == "WARN" } ?? false }
}

struct KiCadFetchResult: Decodable, Sendable {
    let components: [KiCadFetchComponent]?
}

private struct KiCadJobRequest: Codable {
    let id: String
    let createdAt: String
    let device: String
    let update: Bool
    let items: [KiCadFetchItem]
}

private struct KiCadJobStatus: Decodable {
    let status: String
    let updatedAt: String?
    let worker: String?
    let result: KiCadFetchResult?
    let error: String?
}

struct KiCadFetchJob: Sendable, Identifiable {
    let id: String
    let status: String
    let createdAt: Date
    let itemCount: Int
    let error: String?
    let result: KiCadFetchResult?

    var isFinished: Bool { ["done", "partial", "failed"].contains(status) }
}

/// Stato del Mac con KiCad, dal suo heartbeat nella cartella condivisa.
struct KiCadWorkerStatus: Decodable, Sendable {
    let host: String
    let lastSeen: String

    var lastSeenDate: Date { SyncDateParser.parse(lastSeen) }

    /// Il worker riscrive l'heartbeat ogni 5 minuti mentre è attivo.
    var isActive: Bool { Date().timeIntervalSince(lastSeenDate) < 12 * 60 }
}

enum KiCadQueueError: LocalizedError {
    case noSharedFolder
    case sharedFolderUnreachable
    case invalidJob

    var errorDescription: String? {
        switch self {
        case .noSharedFolder:
            String(localized: "Scegli una cartella condivisa in Impostazioni: è lì che il Mac con KiCad riceve le richieste.")
        case .sharedFolderUnreachable:
            String(localized: "Cartella condivisa non raggiungibile.")
        case .invalidJob:
            String(localized: "Richiesta non trovata.")
        }
    }
}

enum KiCadQueue {
    nonisolated(unsafe) private static let fileNamePattern = try! Regex("^[A-Za-z0-9][A-Za-z0-9._+-]{0,150}\\.(zip|png)$")

    static var isAvailable: Bool { SharedFolder.url != nil }

    private static func kicadDirectory() throws -> URL {
        guard let root = SharedFolder.url else { throw KiCadQueueError.noSharedFolder }
        guard SharedFolder.isReachable else { throw KiCadQueueError.sharedFolderUnreachable }
        return root.appendingPathComponent("kicad", isDirectory: true)
    }

    private static func jobDirectory(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw KiCadQueueError.invalidJob }
        return try kicadDirectory()
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(uuid.uuidString.lowercased(), isDirectory: true)
    }

    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        "iPad"
        #endif
    }

    // Le operazioni su file possono attendere il download da iCloud: mai sul main thread.
    private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility, operation: work).value
    }

    static func createJob(_ items: [KiCadFetchItem], update: Bool) async throws -> KiCadFetchJob {
        let device = deviceName
        return try await background {
            let id = UUID().uuidString.lowercased()
            let request = KiCadJobRequest(
                id: id,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                device: device,
                update: update,
                items: items
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try CoordinatedFile.write(
                try encoder.encode(request),
                to: try jobDirectory(id).appendingPathComponent("request.json")
            )
            return try readJob(id)
        }
    }

    static func job(id: String) async throws -> KiCadFetchJob {
        try await background { try readJob(id) }
    }

    static func listJobs(limit: Int = 20) async throws -> [KiCadFetchJob] {
        try await background {
            let jobs = try kicadDirectory().appendingPathComponent("jobs", isDirectory: true)
            guard FileManager.default.fileExists(atPath: jobs.path) else { return [] }
            let ids = try FileManager.default.contentsOfDirectory(atPath: jobs.path)
                .filter { UUID(uuidString: $0) != nil }
            return ids.compactMap { try? readJob($0) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
                .map { $0 }
        }
    }

    private static func readJob(_ id: String) throws -> KiCadFetchJob {
        let dir = try jobDirectory(id)
        let request = try JSONDecoder().decode(
            KiCadJobRequest.self,
            from: CoordinatedFile.read(dir.appendingPathComponent("request.json"))
        )
        let statusURL = dir.appendingPathComponent("status.json")
        let status: KiCadJobStatus? = CoordinatedFile.exists(statusURL)
            ? try? JSONDecoder().decode(KiCadJobStatus.self, from: CoordinatedFile.read(statusURL))
            : nil
        return KiCadFetchJob(
            id: request.id,
            status: status?.status ?? "queued",
            createdAt: SyncDateParser.parse(request.createdAt),
            itemCount: request.items.count,
            error: status?.error,
            result: status?.result
        )
    }

    /// File prodotto dal worker (zip KiCad o render), scaricato se serve.
    static func file(jobID: String, name: String) async throws -> URL {
        guard name.wholeMatch(of: fileNamePattern) != nil else { throw KiCadQueueError.invalidJob }
        return try await background {
            let url = try jobDirectory(jobID).appendingPathComponent(name)
            // Copia in una cartella temporanea: ShareLink e Image non conoscono
            // il security scope della cartella condivisa.
            let data = try CoordinatedFile.read(url)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kicad-fetch/\(jobID)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent(name)
            try data.write(to: copy, options: .atomic)
            return copy
        }
    }

    static func workerStatus() async -> KiCadWorkerStatus? {
        try? await background {
            let url = try kicadDirectory().appendingPathComponent("worker.json")
            return try JSONDecoder().decode(KiCadWorkerStatus.self, from: CoordinatedFile.read(url))
        }
    }

    /// Indice della libreria scritto dal worker, solo se è cambiato rispetto a `knownDate`.
    static func libraryIndex(newerThan knownDate: Date?) async throws -> (data: Data, date: Date)? {
        try await background {
            let url = try kicadDirectory().appendingPathComponent("library_index.json")
            guard CoordinatedFile.exists(url) else { return nil }
            let date = CoordinatedFile.modificationDate(url) ?? Date()
            if let knownDate, abs(date.timeIntervalSince(knownDate)) < 1 { return nil }
            return (try CoordinatedFile.read(url), date)
        }
    }
}
