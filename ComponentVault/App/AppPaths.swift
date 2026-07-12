import Foundation

/// Percorsi dati LCSC/DigiKey — macOS usa ~/LCSC; iPad usa Documents/LCSC o cartella scelta dall'utente.
enum AppPaths {
    private static let lcscRootOverrideKey = "lcscDataRootPath"

    static var lcscDataRoot: URL {
        #if os(macOS)
        URL(fileURLWithPath: macDefaultBasePath, isDirectory: true)
        #else
        if let custom = UserDefaults.standard.string(forKey: lcscRootOverrideKey),
           !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCSC", isDirectory: true)
        #endif
    }

    static let macDefaultBasePath = "/Users/michelebigi/LCSC"

    static var jsonArchiveDirectory: URL {
        lcscDataRoot.appendingPathComponent("json_full_data", isDirectory: true)
    }

    static var defaultCSV: URL {
        lcscDataRoot.appendingPathComponent("Componenti Elettronici.csv")
    }

    static var bomCSV: URL {
        lcscDataRoot.appendingPathComponent("bom_riepilogo.csv")
    }

    static var digiKeyConfigFile: URL {
        lcscDataRoot.appendingPathComponent("digikey_config.yml")
    }

    static var digiKeyTokenCacheFile: URL {
        lcscDataRoot.appendingPathComponent("digikey_token_cache.json")
    }

    static var defaultCSVPath: String { defaultCSV.path }
    static var jsonArchivePath: String { jsonArchiveDirectory.path }
    static var digiKeyConfigPath: String { digiKeyConfigFile.path }
    static var digiKeyTokenCachePath: String { digiKeyTokenCacheFile.path }

    static func setLCSCDataRoot(_ path: String) {
        UserDefaults.standard.set(path, forKey: lcscRootOverrideKey)
    }

    static func defaultPaths() -> (csv: URL, json: URL, bom: URL) {
        (defaultCSV, jsonArchiveDirectory, bomCSV)
    }
}
