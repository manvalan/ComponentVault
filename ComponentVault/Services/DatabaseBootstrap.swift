import Foundation

/// Crea e popola il database locale dalla cartella LCSC predefinita.
enum DatabaseBootstrap {
    static var defaultBasePath: String { AppPaths.lcscDataRoot.path }

    struct Result {
        let imported: Int
        let source: String
    }

    static func defaultPaths() -> (csv: URL, json: URL, bom: URL) {
        AppPaths.defaultPaths()
    }

    static func isDatabaseAvailable() -> Bool {
        let paths = defaultPaths()
        return FileManager.default.fileExists(atPath: paths.csv.path) ||
            FileManager.default.fileExists(atPath: paths.json.path)
    }

    /// Carica record dalla cartella LCSC predefinita (priorità: JSON > BOM > CSV).
    static func loadDefaultRecords() throws -> [ComponentRecord] {
        let paths = defaultPaths()

        if FileManager.default.fileExists(atPath: paths.json.path) {
            return try CSVImporter.importJSONArchive(from: paths.json)
        }
        if FileManager.default.fileExists(atPath: paths.bom.path) {
            return try CSVImporter.importEnrichedBOM(from: paths.bom)
        }
        if FileManager.default.fileExists(atPath: paths.csv.path) {
            return try CSVImporter.importInventory(from: paths.csv)
        }
        throw BootstrapError.databaseNotFound
    }

    static func describeSource() -> String {
        let paths = defaultPaths()
        if FileManager.default.fileExists(atPath: paths.json.path) { return "json_full_data" }
        if FileManager.default.fileExists(atPath: paths.bom.path) { return "bom_riepilogo.csv" }
        if FileManager.default.fileExists(atPath: paths.csv.path) { return "Componenti Elettronici.csv" }
        return "sconosciuto"
    }

    enum BootstrapError: LocalizedError {
        case databaseNotFound
        case emptyDatabase

        var errorDescription: String? {
            switch self {
            case .databaseNotFound:
                "Database non trovato in \(defaultBasePath). Esegui prima:\npython3 Tools/lcsc_enrich.py"
            case .emptyDatabase:
                "Nessun componente valido trovato in \(defaultBasePath)/json_full_data"
            }
        }
    }
}
