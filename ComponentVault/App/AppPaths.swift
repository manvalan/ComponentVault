import Foundation

/// Percorsi dati. Due radici:
/// - `localRoot`: solo di questo dispositivo (configurazione senza cartella, cache);
/// - `lcscDataRoot`: archivio LCSC/CSV, la cartella condivisa se scelta, altrimenti quella locale.
enum AppPaths {
    /// macOS: Application Support del container; iPad: Documents/LCSC (visibile nell'app File).
    static var localRoot: URL {
        #if os(macOS)
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ComponentVault", isDirectory: true)
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCSC", isDirectory: true)
        #endif
    }

    static var lcscDataRoot: URL {
        SharedFolder.url ?? localRoot
    }

    static var jsonArchiveDirectory: URL {
        lcscDataRoot.appendingPathComponent("json_full_data", isDirectory: true)
    }

    static var defaultCSV: URL {
        lcscDataRoot.appendingPathComponent("Componenti Elettronici.csv")
    }

    static var bomCSV: URL {
        lcscDataRoot.appendingPathComponent("bom_riepilogo.csv")
    }

    static var localConfigFile: URL {
        localRoot.appendingPathComponent(AppConfig.fileName)
    }

    /// Con una cartella scelta la configurazione sta lì (uguale per tutti i
    /// dispositivi); altrimenti resta su questo dispositivo.
    static var appConfigFile: URL {
        SharedFolder.url?.appendingPathComponent(AppConfig.fileName) ?? localConfigFile
    }

    static var kicadIndexCacheFile: URL {
        localRoot.appendingPathComponent("kicad_library_index.json")
    }

    static var defaultCSVPath: String { defaultCSV.path }
    static var jsonArchivePath: String { jsonArchiveDirectory.path }

    static func defaultPaths() -> (csv: URL, json: URL, bom: URL) {
        (defaultCSV, jsonArchiveDirectory, bomCSV)
    }

    static func ensureLocalDirectory() throws {
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
    }

    static func ensureLCSCDirectory() throws {
        try ensureLocalDirectory()
        try FileManager.default.createDirectory(at: lcscDataRoot, withIntermediateDirectories: true)
    }
}
