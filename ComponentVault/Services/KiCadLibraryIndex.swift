import Foundation
import Observation

/// Un simbolo della libreria KiCad MIKILAB (da mikylab_kikad_library/scripts/library_index.py).
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

/// Indice della libreria KiCad: scaricato dal server (pubblicato dal worker sul Mac)
/// e conservato in locale, così la verifica delle BOM funziona anche offline.
@MainActor
@Observable
final class KiCadLibraryStore {
    static let shared = KiCadLibraryStore()

    private(set) var index: KiCadLibraryIndexFile?
    private(set) var isRefreshing = false
    var errorMessage: String?

    @ObservationIgnored private var byKey: [String: KiCadLibraryEntry] = [:]
    @ObservationIgnored private static let etagKey = "ComponentVault.kicadLibraryIndexETag"

    static var cacheFile: URL {
        AppPaths.lcscDataRoot.appendingPathComponent("kicad_library_index.json")
    }

    private init() {
        loadCached()
    }

    var ownComponentsCount: Int {
        index?.components.filter(\.isOwnComponent).count ?? 0
    }

    func loadCached() {
        guard let data = try? Data(contentsOf: Self.cacheFile),
              let decoded = try? JSONDecoder().decode(KiCadLibraryIndexFile.self, from: data) else { return }
        apply(decoded)
    }

    /// Aggiorna dal server; se offline o non configurato resta la copia locale.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let config = try SyncSettings.remoteConfig()
            let etag = index == nil ? nil : UserDefaults.standard.string(forKey: Self.etagKey)
            guard let fresh = try await RemoteAPIClient.fetchKiCadLibraryIndex(etag: etag, config: config) else {
                errorMessage = nil
                return
            }
            let decoded = try JSONDecoder().decode(KiCadLibraryIndexFile.self, from: fresh.data)
            try AppPaths.ensureLCSCDirectory()
            try fresh.data.write(to: Self.cacheFile, options: .atomic)
            UserDefaults.standard.set(fresh.etag, forKey: Self.etagKey)
            apply(decoded)
            errorMessage = nil
        } catch is DecodingError {
            errorMessage = "Indice libreria non interpretabile."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
