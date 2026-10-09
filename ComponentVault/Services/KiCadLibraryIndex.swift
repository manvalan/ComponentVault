import Foundation
import Observation

/// Un simbolo della libreria KiCad dell'utente (indice scritto da scripts/library_index.py).
struct KiCadLibraryEntry: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let lib: String
    let category: String
    let footprint: String?
    let lcsc: String?
    let mpn: String?
    let own: Bool?
    let model3d: Bool?

    var id: String { "\(lib):\(name)" }
    var isOwnComponent: Bool { own ?? false }
}

struct KiCadLibraryIndexFile: Codable, Sendable {
    let format: Int
    let library: String
    let generatedAt: String
    let count: Int
    let components: [KiCadLibraryEntry]
}

/// Esito del confronto di una riga BOM con la libreria.
enum KiCadLibraryMatch: Sendable {
    case present(KiCadLibraryEntry)
    case missing
    case noPartNumber
    /// Indice non ancora scaricato: lo stato non è noto (non va trattato come mancante).
    case unknown
}

/// Indice della libreria KiCad: scritto dal worker sul Mac nella cartella condivisa
/// e copiato in locale, così la verifica delle BOM funziona anche offline.
@MainActor
@Observable
final class KiCadLibraryStore {
    static let shared = KiCadLibraryStore()

    private(set) var index: KiCadLibraryIndexFile?
    private(set) var isRefreshing = false
    var errorMessage: String?

    @ObservationIgnored private var byKey: [String: KiCadLibraryEntry] = [:]
    @ObservationIgnored private static let dateKey = "ComponentVault.kicadLibraryIndexDate"

    static var cacheFile: URL {
        AppPaths.kicadIndexCacheFile
    }

    private init() {
        loadCached()
    }

    /// Nome della libreria: quello scritto dal worker nell'indice, altrimenti
    /// la cartella impostata dal Mac, altrimenti un nome generico.
    var displayName: String {
        if let name = index?.library.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let folder = AppConfigIO.current().kicad.libraryName
        return folder.isEmpty ? String(localized: "Libreria KiCad") : folder
    }

    var ownComponentsCount: Int {
        index?.components.filter(\.isOwnComponent).count ?? 0
    }

    func loadCached() {
        guard let data = try? Data(contentsOf: Self.cacheFile),
              let decoded = try? JSONDecoder().decode(KiCadLibraryIndexFile.self, from: data) else { return }
        apply(decoded)
    }

    /// Sul Mac con la libreria: indice letto direttamente dalla cartella KiCad e
    /// pubblicato nella cartella condivisa. Altrove: dalla cartella condivisa,
    /// e se non raggiungibile resta la copia locale.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        #if os(macOS)
        if let root = KiCadLocalLibrary.url, KiCadLocalLibrary.isAvailable {
            await rebuildFromLocalLibrary(root: root)
            return
        }
        #endif
        do {
            let known = index == nil ? nil : UserDefaults.standard.object(forKey: Self.dateKey) as? Date
            guard let fresh = try await KiCadQueue.libraryIndex(newerThan: known) else {
                errorMessage = nil
                return
            }
            let decoded = try JSONDecoder().decode(KiCadLibraryIndexFile.self, from: fresh.data)
            try AppPaths.ensureLocalDirectory()
            try fresh.data.write(to: Self.cacheFile, options: .atomic)
            UserDefaults.standard.set(fresh.date, forKey: Self.dateKey)
            apply(decoded)
            errorMessage = nil
        } catch is DecodingError {
            errorMessage = String(localized: "Indice libreria non interpretabile.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    private func rebuildFromLocalLibrary(root: URL) async {
        let name = AppConfigIO.current().kicad.libraryName
        do {
            let (file, data) = try await Task.detached(priority: .userInitiated) {
                let file = try KiCadLocalLibrary.buildIndex(root: root, libraryName: name)
                return (file, try JSONEncoder().encode(file))
            }.value
            try AppPaths.ensureLocalDirectory()
            try data.write(to: Self.cacheFile, options: .atomic)
            apply(file)
            errorMessage = nil
            // Lo stesso indice per l'iPad, nella cartella condivisa.
            if let shared = SharedFolder.url {
                let target = shared.appendingPathComponent("kicad/library_index.json")
                try? await Task.detached { try CoordinatedFile.write(data, to: target) }.value
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func match(mpn: String, lcsc: String?) -> KiCadLibraryMatch {
        let mpnKey = Self.normalize(mpn)
        if mpnKey.isEmpty, lcsc?.isEmpty ?? true { return .noPartNumber }
        guard index != nil else { return .unknown }
        if let lcsc, let hit = byKey["lcsc:" + lcsc.uppercased()] { return .present(hit) }
        if !mpnKey.isEmpty, let hit = byKey[mpnKey] { return .present(hit) }
        return .missing
    }

    func search(_ text: String, ownOnly: Bool, limit: Int = 500) -> [KiCadLibraryEntry] {
        let all = index?.components ?? []
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [KiCadLibraryEntry] = []
        for entry in all where !ownOnly || entry.isOwnComponent {
            if query.isEmpty
                || entry.name.lowercased().contains(query)
                || (entry.mpn?.lowercased().contains(query) ?? false)
                || (entry.lcsc?.lowercased().contains(query) ?? false)
                || (entry.footprint?.lowercased().contains(query) ?? false) {
                result.append(entry)
                if result.count >= limit { break }
            }
        }
        return result
    }

    static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    private func apply(_ file: KiCadLibraryIndexFile) {
        var keys: [String: KiCadLibraryEntry] = [:]
        // Prima i simboli condivisi, poi i componenti propri: a parità di chiave vince il proprio.
        for entry in file.components.sorted(by: { !$0.isOwnComponent && $1.isOwnComponent }) {
            keys[Self.normalize(entry.name)] = entry
            if let mpn = entry.mpn { keys[Self.normalize(mpn)] = entry }
            if let lcsc = entry.lcsc { keys["lcsc:" + lcsc.uppercased()] = entry }
        }
        byKey = keys
        index = file
    }
}
