import Foundation
import Security

/// Credenziali DigiKey inserite a mano dall'utente nella propria copia dell'app.
/// Restano nel Portachiavi (di questo dispositivo, o iCloud se l'utente sceglie di
/// condividerle): non vanno nel file di configurazione, nella cartella o altrove.
/// Escono dall'app solo verso api.digikey.com, per le richieste DigiKey.
struct DigiKeyCredentials: Codable, Sendable, Equatable {
    enum Environment: String, Codable, Sendable, CaseIterable, Identifiable {
        case production
        case sandbox

        var id: String { rawValue }

        var apiBaseURL: String {
            switch self {
            case .production: "https://api.digikey.com"
            case .sandbox: "https://sandbox-api.digikey.com"
            }
        }
    }

    var clientID = ""
    var clientSecret = ""
    var accessToken = ""
    var refreshToken = ""
    /// Scadenza dell'access token (nil = sconosciuta: si prova finché DigiKey lo accetta).
    var expiresAt: Date?
    var environment: Environment = .production
    var market = "IT"
    var currency = "EUR"
    var language = "it"

    var apiBaseURL: String { environment.apiBaseURL }

    var isComplete: Bool {
        !clientID.trimmed.isEmpty && (!accessToken.trimmed.isEmpty || !refreshToken.trimmed.isEmpty)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Portachiavi per le credenziali dei fornitori. Di norma gli elementi restano solo su
/// questo dispositivo (niente iCloud, niente backup). Se l'utente lo chiede, passano nel
/// Portachiavi iCloud (cifrato end-to-end da Apple) e li vedono solo le copie di
/// ComponentVault sui suoi dispositivi (Mac e iPad hanno lo stesso identificativo app).
enum SupplierKeychain {
    private static let service = "it.michelebigi.ComponentVault.suppliers"
    private static let accounts = ["mouser", "digikey", "nexar"]
    private static let shareDefaultsKey = "suppliers.shareViaICloudKeychain"

    private static func query(_ account: String, synchronizable: CFTypeRef) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func data(account: String, synchronizable: CFTypeRef = kSecAttrSynchronizableAny) -> Data? {
        var q = query(account, synchronizable: synchronizable)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func add(_ data: Data, account: String, shared: Bool) -> OSStatus {
        var q = query(account, synchronizable: shared ? kCFBooleanTrue! : kCFBooleanFalse!)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = shared
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil)
    }

    static func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        data(account: account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// Aggiorna l'elemento dove si trova già (locale o iCloud); se manca lo crea
    /// secondo la scelta "Condividi con i miei dispositivi".
    static func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary,
                                   attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = add(data, account: account, shared: sharesAcrossDevices)
        }
        guard status == errSecSuccess else {
            throw ProviderError.networkFailure(String(localized: "Impossibile salvare nel Portachiavi (\(status))."))
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary)
    }

    /// Vero se le chiavi stanno (o andranno) nel Portachiavi iCloud.
    static var sharesAcrossDevices: Bool {
        UserDefaults.standard.bool(forKey: shareDefaultsKey)
            || accounts.contains { data(account: $0, synchronizable: kCFBooleanTrue!) != nil }
    }

    /// Sposta le chiavi già salvate nel Portachiavi iCloud o di nuovo solo su questo
    /// dispositivo. Togliendo la condivisione spariscono anche dagli altri dispositivi.
    static func setSharesAcrossDevices(_ shared: Bool) throws {
        UserDefaults.standard.set(shared, forKey: shareDefaultsKey)
        let from: CFTypeRef = shared ? kCFBooleanFalse! : kCFBooleanTrue!
        for account in accounts {
            guard let value = data(account: account, synchronizable: from) else { continue }
            SecItemDelete(query(account, synchronizable: from) as CFDictionary)
            let status = add(value, account: account, shared: shared)
            if status == errSecDuplicateItem {
                continue  // c'era già una copia nella destinazione: si tiene quella
            }
            guard status == errSecSuccess else {
                _ = add(value, account: account, shared: !shared)
                throw ProviderError.networkFailure(String(localized: "Impossibile spostare le chiavi nel Portachiavi (\(status))."))
            }
        }
    }
}

enum DigiKeyKeychain {
    private static let account = "digikey"

    static func load() -> DigiKeyCredentials? {
        SupplierKeychain.load(DigiKeyCredentials.self, account: account)
    }

    static func save(_ credentials: DigiKeyCredentials) throws {
        try SupplierKeychain.save(credentials, account: account)
    }

    static func delete() {
        SupplierKeychain.delete(account: account)
    }

    static var isConfigured: Bool {
        load()?.isComplete ?? false
    }
}

/// Access token DigiKey: quello inserito dall'utente, rinnovato con il refresh token
/// quando scade. I token rinnovati tornano nel Portachiavi.
actor DigiKeyAuthService {
    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private var credentials: DigiKeyCredentials

    init(credentials: DigiKeyCredentials) {
        self.credentials = credentials
    }

    func accessToken() async throws -> String {
        let current = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let stillValid = credentials.expiresAt.map { Date() < $0.addingTimeInterval(-60) } ?? true
        if !current.isEmpty, stillValid {
            return current
        }
        return try await refresh()
    }

    /// Rinnova con il refresh token (anche dopo un 401 di DigiKey).
    @discardableResult
    func refresh() async throws -> String {
        let refreshToken = credentials.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshToken.isEmpty, !credentials.clientSecret.isEmpty else {
            throw ProviderError.networkFailure(
                String(localized: "Token DigiKey scaduto. Inserisci un nuovo token in Impostazioni → DigiKey.")
            )
        }

        var request = URLRequest(url: URL(string: "\(credentials.apiBaseURL)/v1/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.networkFailure(
                String(localized: "DigiKey non ha rinnovato il token. Inserisci un nuovo token in Impostazioni → DigiKey.")
            )
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        credentials.accessToken = token.accessToken
        if let newRefresh = token.refreshToken, !newRefresh.isEmpty {
            credentials.refreshToken = newRefresh
        }
        credentials.expiresAt = token.expiresIn.map { Date().addingTimeInterval(Double($0)) }
        try DigiKeyKeychain.save(credentials)
        return token.accessToken
    }
}
