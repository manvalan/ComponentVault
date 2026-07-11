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

enum RemoteAPIClient {
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
