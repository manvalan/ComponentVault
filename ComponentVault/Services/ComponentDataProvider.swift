import Foundation

/// Contratto per fonti dati esterne (LCSC, DigiKey, …).
protocol ComponentDataProvider: Sendable {
    var source: DataSource { get }
    func fetch(lcscCode: String) async throws -> ComponentRecord
}

enum ProviderError: LocalizedError {
    case invalidCode
    case networkFailure(String)
    case parseFailure
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            String(localized: "Codice LCSC non valido.")
        case .networkFailure(let detail):
            String(localized: "Errore di rete: \(detail)")
        case .parseFailure:
            String(localized: "Impossibile interpretare la risposta del fornitore.")
        case .notFound(let code):
            String(localized: "Componente \(code) non trovato.")
        }
    }
}
