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
            "Codice LCSC non valido."
        case .networkFailure(let detail):
            "Errore di rete: \(detail)"
        case .parseFailure:
            "Impossibile interpretare la risposta del fornitore."
        case .notFound(let code):
            "Componente \(code) non trovato."
        }
    }
}
