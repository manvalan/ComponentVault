import Foundation

struct RemoteAPIConfig: Sendable {
    let baseURL: URL
    let apiKey: String

    static func from(baseURLString: String, apiKey: String) throws -> RemoteAPIConfig {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw RemoteAPIError.missingURL }
        guard !trimmedKey.isEmpty else { throw RemoteAPIError.missingAPIKey }
        guard let url = URL(string: trimmedURL) else { throw RemoteAPIError.invalidURL }
        return RemoteAPIConfig(baseURL: url, apiKey: trimmedKey)
    }
}

enum RemoteAPIError: LocalizedError {
    case missingURL
    case missingAPIKey
    case invalidURL
    case unauthorized
    case serverError(Int, String)
    case decodeFailure

    var errorDescription: String? {
        switch self {
        case .missingURL: "Inserisci l'URL del server."
        case .missingAPIKey: "Inserisci la API key."
        case .invalidURL: "URL server non valido."
        case .unauthorized: "API key non valida."
        case .serverError(let code, let detail): "Errore server (\(code)): \(detail)"
        case .decodeFailure: "Risposta server non interpretabile."
        }
    }
}

struct RemoteHealthResponse: Decodable, Sendable {
    let status: String
    let components: Int
}

private struct SyncPushBody: Encodable {
    let components: [ComponentRecord]
}

private struct SyncPushResponse: Decodable {
    let upserted: Int
}

private struct ProjectSyncPushBody: Encodable {
    let projects: [ProjectRecord]
}

private struct ProjectSyncPushResponse: Decodable {
    let upserted: Int
}

// MARK: - Coda libreria KiCad (MIKILAB)
//
// L'app chiede soltanto "aggiungi questi componenti": il download da
// SnapEDA/UltraLibrarian/EasyEDA lo esegue il worker sul Mac
// (mikylab_kikad_library/scripts/fetch_worker.py), l'unico che conosce le
// credenziali dei fornitori. L'app usa solo la propria API key.

struct KiCadFetchItem: Codable, Sendable {
    var mpn: String
    var lcsc: String?
    var ref: String = ""
    var funzione: String = ""
    var nome: String?
    var categoria: String?
}

private struct KiCadFetchJobBody: Encodable {
    let items: [KiCadFetchItem]
    let update: Bool
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

struct KiCadFetchJob: Decodable, Sendable, Identifiable {
    let id: String
    let status: String
    let error: String?
    let result: KiCadFetchResult?

    var isFinished: Bool { ["done", "partial", "failed"].contains(status) }
}

enum RemoteAPIClient {
    static func createKiCadFetchJob(
        _ items: [KiCadFetchItem],
        update: Bool = false,
        config: RemoteAPIConfig
    ) async throws -> KiCadFetchJob {
        try await post(config: config, path: "fetch/jobs", body: KiCadFetchJobBody(items: items, update: update))
    }

    static func kiCadFetchJob(id: String, config: RemoteAPIConfig) async throws -> KiCadFetchJob {
        try await get(config: config, path: "fetch/jobs/\(id)")
    }

    static func listKiCadFetchJobs(limit: Int = 20, config: RemoteAPIConfig) async throws -> [KiCadFetchJob] {
        let endpoint = config.baseURL.appending(path: "fetch/jobs")
            .appending(queryItems: [URLQueryItem(name: "limit", value: String(limit))])
        var request = URLRequest(url: endpoint)
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    /// Indice della libreria KiCad pubblicato dal worker. Con `etag` della copia
    /// locale ritorna `nil` se non è cambiato (HTTP 304).
    static func fetchKiCadLibraryIndex(etag: String?, config: RemoteAPIConfig) async throws -> (data: Data, etag: String?)? {
        var request = URLRequest(url: config.baseURL.appending(path: "library/index"))
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteAPIError.decodeFailure }
        if http.statusCode == 304 { return nil }
        if http.statusCode == 401 { throw RemoteAPIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteAPIError.serverError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http.value(forHTTPHeaderField: "ETag"))
    }

    /// Scarica uno zip KiCad o un render del job in una cartella temporanea.
    static func downloadKiCadFetchFile(jobID: String, name: String, config: RemoteAPIConfig) async throws -> URL {
        let endpoint = config.baseURL.appending(path: "fetch/jobs/\(jobID)/files/\(name)")
        var request = URLRequest(url: endpoint)
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteAPIError.decodeFailure }
        if http.statusCode == 401 { throw RemoteAPIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteAPIError.serverError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "kicad-fetch/\(jobID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: (name as NSString).lastPathComponent)
        try data.write(to: file, options: .atomic)
        return file
    }

    static func checkConnection(config: RemoteAPIConfig) async throws -> RemoteHealthResponse {
        try await get(config: config, path: "health")
    }

    static func projectsAPIAvailable(config: RemoteAPIConfig) async -> Bool {
        let endpoint = config.baseURL.appending(path: "projects")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return http.statusCode != 404
    }

    static func fetchComponents(config: RemoteAPIConfig) async throws -> [ComponentRecord] {
        try await get(config: config, path: "components")
    }

    static func pushComponents(_ records: [ComponentRecord], config: RemoteAPIConfig) async throws -> Int {
        let response: SyncPushResponse = try await post(
            config: config,
            path: "sync/push",
            body: SyncPushBody(components: records)
        )
        return response.upserted
    }

    static func fetchProjects(config: RemoteAPIConfig) async throws -> [ProjectRecord] {
        try await get(config: config, path: "projects")
    }

    static func pushProjects(_ projects: [ProjectRecord], config: RemoteAPIConfig) async throws -> Int {
        let response: ProjectSyncPushResponse = try await post(
            config: config,
            path: "sync/projects/push",
            body: ProjectSyncPushBody(projects: projects)
        )
        return response.upserted
    }

    private static func get<T: Decodable>(config: RemoteAPIConfig, path: String) async throws -> T {
        let endpoint = config.baseURL.appending(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private static func post<T: Decodable, B: Encodable>(
        config: RemoteAPIConfig,
        path: String,
        body: B
    ) async throws -> T {
        let endpoint = config.baseURL.appending(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private static func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteAPIError.decodeFailure
        }
        if http.statusCode == 401 { throw RemoteAPIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw RemoteAPIError.serverError(http.statusCode, detail)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteAPIError.decodeFailure
        }
    }
}
