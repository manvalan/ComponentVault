import Foundation

/// Dati LCSC dall'archivio locale (`json_full_data/Cxxxxx.json`). Nessun accesso
/// al sito LCSC: non esiste un'API pubblica autorizzata per farlo dall'app.
struct LCSCProvider: ComponentDataProvider {
    let source: DataSource = .lcsc

    private static var localArchivePath: String { AppPaths.jsonArchivePath }

    func fetch(lcscCode: String) async throws -> ComponentRecord {
        let code = lcscCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard LCSCCode.isValid(code) else {
            throw ProviderError.invalidCode
        }
        guard let local = Self.loadLocalArchive(lcscCode: code) else {
            throw ProviderError.notFound(code)
        }
        return local
    }

    private static func loadLocalArchive(lcscCode: String) -> ComponentRecord? {
        let path = "\(localArchivePath)/\(lcscCode).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let record = try? JSONDecoder().decode(ComponentRecord.self, from: data) else {
            return nil
        }
        return record
    }
}

/// Immagini remote solo da fornitori con API autorizzata (le loro condizioni ne
/// consentono la visualizzazione); niente immagini prese dal sito LCSC.
enum RemoteImagePolicy {
    private static let allowedHosts = ["mouser.com", "digikey.com", "digikey.it"]

    static func isAllowed(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), url?.scheme == "https" else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
