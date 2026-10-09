import Foundation

/// Cartella scelta dall'utente (iCloud Drive, cartella sincronizzata, disco di rete)
/// condivisa tra i dispositivi: configurazione, scambio dati e richieste KiCad.
/// Nessun server: due dispositivi che vedono la stessa cartella lavorano insieme.
///
///     <cartella>/componentvault_config.yml     configurazione (anche il percorso KiCad, dal Mac)
///     <cartella>/sync/components.json           inventario per lo scambio tra dispositivi
///     <cartella>/sync/projects.json             progetti
///     <cartella>/kicad/jobs/<uuid>/…            richieste per il worker KiCad sul Mac
///     <cartella>/kicad/library_index.json       indice della libreria KiCad
///     <cartella>/kicad/worker.json              heartbeat del Mac con KiCad
enum SharedFolder {
    private static let bookmarkKey = "ComponentVault.sharedFolderBookmark"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved: URL?
    nonisolated(unsafe) private static var didResolve = false

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// Cartella condivisa con accesso già aperto, o `nil` se non scelta / non risolvibile.
    static var url: URL? {
        lock.withLock { resolveIfNeeded() }
    }

    static var isConfigured: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// Scelta e raggiungibile adesso (disco montato, iCloud attivo…).
    static var isReachable: Bool {
        guard let url else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static var displayPath: String {
        guard let url else { return "" }
        let path = url.path
        if let range = path.range(of: "/Mobile Documents/com~apple~CloudDocs") {
            return "iCloud Drive" + path[range.upperBound...]
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// Memorizza la cartella scelta da `fileImporter` (bookmark con security scope).
    static func set(_ newURL: URL) throws {
        let accessing = newURL.startAccessingSecurityScopedResource()
        defer { if accessing { newURL.stopAccessingSecurityScopedResource() } }
        let data = try newURL.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        lock.withLock {
            releaseCurrent()
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        _ = url
        NotificationCenter.default.post(name: .sharedFolderChanged, object: nil)
    }

    static func clear() {
        lock.withLock {
            releaseCurrent()
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
        NotificationCenter.default.post(name: .sharedFolderChanged, object: nil)
    }

    private static func releaseCurrent() {
        resolved?.stopAccessingSecurityScopedResource()
        resolved = nil
        didResolve = false
    }

    private static func resolveIfNeeded() -> URL? {
        if didResolve { return resolved }
        didResolve = true
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        resolved = url
        return url
    }
}

/// Lettura/scrittura coordinate: con iCloud Drive o altri file provider il file
/// viene scaricato se serve e nessun altro processo lo vede scritto a metà.
enum CoordinatedFile {
    static func read(_ url: URL) throws -> Data {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            result = Result { try data.write(to: writeURL, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    static func exists(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        // File iCloud non ancora scaricato: compare come ".nome.icloud".
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

extension Notification.Name {
    static let sharedFolderChanged = Notification.Name("ComponentVault.sharedFolderChanged")
}
