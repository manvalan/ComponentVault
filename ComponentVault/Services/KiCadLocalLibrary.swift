import Foundation

/// La libreria KiCad sul Mac: cartella scelta dall'utente (bookmark), letta
/// direttamente dall'app. Costruisce lo stesso indice di scripts/library_index.py
/// e lo pubblica nella cartella condivisa per l'iPad.
enum KiCadLocalLibrary {
    private static let bookmarkKey = "ComponentVault.kicadLibraryBookmark"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved: URL?
    nonisolated(unsafe) private static var didResolve = false

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    static var url: URL? {
        #if os(macOS)
        lock.withLock { resolveIfNeeded() }
        #else
        nil
        #endif
    }

    static var isAvailable: Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("symbols").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("sym-lib-table").path)
    }

    static func set(_ newURL: URL) throws {
        let accessing = newURL.startAccessingSecurityScopedResource()
        defer { if accessing { newURL.stopAccessingSecurityScopedResource() } }
        let data = try newURL.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        lock.withLock {
            resolved?.stopAccessingSecurityScopedResource()
            resolved = nil
            didResolve = false
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    private static func resolveIfNeeded() -> URL? {
        if didResolve { return resolved }
        didResolve = true
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        resolved = url
        return url
    }

    // MARK: Indice

    private static let lcscKeys: Set<String> = ["lcsc", "lcsc part", "lcsc_part", "lcsc part #", "jlcpcb part"]
    private static let mpnKeys: Set<String> = ["mpn", "mp", "manufacturer_part_number", "manufacturer part number", "mfr part", "mfr. part #"]

    /// Simboli della libreria: nickname dalle sym-lib-table (o dal nome del file),
    /// proprietà MPN/LCSC/Footprint e presenza del modello 3D.
    static func buildIndex(root: URL, libraryName: String) throws -> KiCadLibraryIndexFile {
        let symbolLibs = libraryTable(root: root, file: "sym-lib-table")
            ?? enumerate(root: root.appendingPathComponent("symbols"), suffix: ".kicad_sym")
                .map { (nickname: defaultNickname(libraryName, $0.deletingPathExtension().lastPathComponent), url: $0) }
        let footprintLibs = Dictionary(
            (libraryTable(root: root, file: "fp-lib-table") ?? []).map { ($0.nickname, $0.url) },
            uniquingKeysWith: { first, _ in first }
        )
        var modelCache: [String: Bool] = [:]
        var components: [KiCadLibraryEntry] = []

        for lib in symbolLibs {
            guard let text = try? String(contentsOf: lib.url, encoding: .utf8) else { continue }
            let nsText = text as NSString
            let symbols = topLevelSymbols(in: nsText)
            let own = symbols.count == 1
            for (index, symbol) in symbols.enumerated() {
                let end = index + 1 < symbols.count ? symbols[index + 1].offset : nsText.length
                let length = min(end, symbol.offset + 20000) - symbol.offset
                let block = nsText.substring(with: NSRange(location: symbol.offset, length: max(0, length)))
                let props = properties(in: block)
                let footprint = props["footprint"] ?? ""
                let lcsc = lcscKeys.lazy.compactMap { props[$0] }.first { !$0.isEmpty } ?? ""
                let mpn = mpnKeys.lazy.compactMap { props[$0] }.first { !$0.isEmpty } ?? ""

                var model3d: Bool?
                if let footprintLib = footprintLibs[footprintNickname(footprint)] {
                    if let cached = modelCache[footprint] {
                        model3d = cached
                    } else {
                        let file = footprintLib.appendingPathComponent(footprintName(footprint) + ".kicad_mod")
                        let has = (try? String(contentsOf: file, encoding: .utf8))?.contains("(model ") ?? false
                        modelCache[footprint] = has
                        model3d = has
                    }
                }

                components.append(KiCadLibraryEntry(
                    name: symbol.name,
                    lib: lib.nickname,
                    category: lib.url.deletingLastPathComponent().lastPathComponent,
                    footprint: footprint.isEmpty ? nil : footprint,
                    lcsc: lcsc.range(of: #"^[Cc]\d+$"#, options: .regularExpression) != nil ? lcsc.uppercased() : nil,
                    mpn: mpn.isEmpty || mpn == symbol.name ? nil : mpn,
                    own: own ? true : nil,
                    model3d: model3d
                ))
            }
        }
        return KiCadLibraryIndexFile(
            format: 1,
            library: commonPrefix(symbolLibs.map(\.nickname)) ?? libraryName,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            count: components.count,
            components: components
        )
    }

    /// Nome della libreria dai nickname: "MIKILAB_TLV62569…" → "MIKILAB" se lo condividono quasi tutti.
    private static func commonPrefix(_ nicknames: [String]) -> String? {
        let prefixes = nicknames.compactMap { $0.split(separator: "_", maxSplits: 1).first.map(String.init) }
        let counts = Dictionary(prefixes.map { ($0, 1) }, uniquingKeysWith: +)
        guard let best = counts.max(by: { $0.value < $1.value }),
              nicknames.count > 1, Double(best.value) >= Double(nicknames.count) * 0.8 else { return nil }
        return best.key
    }

    private static func defaultNickname(_ library: String, _ stem: String) -> String {
        let prefix = library.isEmpty ? "" : library.uppercased() + "_"
        return prefix + stem.replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func footprintNickname(_ ref: String) -> String {
        ref.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    }

    private static func footprintName(_ ref: String) -> String {
        let parts = ref.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : ref
    }

    /// `(lib (name "X")(type "KiCad")(uri "${KIPRJMOD}/…"))` → nickname e percorso.
    private static func libraryTable(root: URL, file: String) -> [(nickname: String, url: URL)]? {
        guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else { return nil }
        let regex = try! NSRegularExpression(pattern: #"\(lib\s+\(name\s+"([^"]+)"\).*?\(uri\s+"([^"]+)"\)"#)
        let range = NSRange(text.startIndex..., in: text)
        let result: [(nickname: String, url: URL)] = regex.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let uriRange = Range(match.range(at: 2), in: text) else { return nil }
            var uri = String(text[uriRange])
            for variable in ["${KIPRJMOD}", "${MIKILAB}"] where uri.hasPrefix(variable) {
                uri = root.path + uri.dropFirst(variable.count)
            }
            guard uri.hasPrefix("/") else { return nil }
            return (String(text[nameRange]), URL(fileURLWithPath: uri))
        }
        return result.isEmpty ? nil : result
    }

    private static func enumerate(root: URL, suffix: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.path < $1.path }
    }

    /// Simboli di primo livello (esclusi i sotto-simboli delle unità "NOME_1_1").
    private static let symbolRegex = try! NSRegularExpression(pattern: #"(?m)^\s{0,2}\(symbol\s+"([^"]+)""#)
    private static let unitRegex = try! NSRegularExpression(pattern: #"_\d+_\d+$"#)
    private static let propertyRegex = try! NSRegularExpression(pattern: #"\(property\s+"([^"]+)"\s+"([^"]*)""#)

    /// Simboli di primo livello (esclusi i sotto-simboli delle unità "NOME_1_1"), con offset UTF-16.
    private static func topLevelSymbols(in nsText: NSString) -> [(name: String, offset: Int)] {
        symbolRegex.matches(in: nsText as String, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            let name = nsText.substring(with: match.range(at: 1))
            guard unitRegex.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) == nil else { return nil }
            return (name, match.range.location)
        }
    }

    private static func properties(in block: String) -> [String: String] {
        let nsBlock = block as NSString
        var result: [String: String] = [:]
        // Come library_index.py: a parità di chiave vale l'ultima.
        for match in propertyRegex.matches(in: block, range: NSRange(location: 0, length: nsBlock.length)) {
            let key = nsBlock.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
            result[key] = nsBlock.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
