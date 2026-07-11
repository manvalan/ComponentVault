import Foundation

enum LCSCCatalogProvider {
    private static let scriptCandidates = [
        "/Users/michelebigi/Documents/Develop/ComponentVault/Tools/lcsc_catalog_search.py",
        Bundle.main.bundlePath + "/Contents/Resources/lcsc_catalog_search.py",
    ]

    struct CatalogHit: Decodable {
        let lcscCode: String
        let mpn: String
        let name: String?
        let description: String?
        let footprint: String?
        let brand: String?
        let category: String?
        let price: Double?
        let currency: String?
        let supplierStock: Int?
        let productURL: String?
    }

    static func searchByMPN(_ mpn: String, limit: Int = 3) async throws -> [ComponentRecord] {
        let keyword = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return try await searchCatalog(keyword: keyword, limit: limit)
    }

    static func searchCatalog(keyword: String, limit: Int = 5) async throws -> [ComponentRecord] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let data = try await runScript(keyword: trimmed, limit: limit)
        if let errorObject = try? JSONDecoder().decode([String: String].self, from: data),
           let error = errorObject["error"] {
            throw ProviderError.networkFailure("LCSC catalogo: \(error)")
        }

        let hits = try JSONDecoder().decode([CatalogHit].self, from: data)
        return hits.map { hit in
            ComponentRecord(
                lcscCode: hit.lcscCode,
                mpn: hit.mpn,
                name: hit.name ?? hit.mpn,
                description: hit.description ?? "",
                footprint: hit.footprint ?? "",
                category: hit.category ?? "",
                brand: hit.brand ?? "",
                price: hit.price,
                currency: hit.currency,
                supplierStock: hit.supplierStock,
                dataSource: .lcsc,
                supplierProductURL: hit.productURL
            )
        }
    }

    private static func runScript(keyword: String, limit: Int) async throws -> Data {
        guard let scriptPath = scriptCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw ProviderError.networkFailure(
                "Script LCSC non trovato. Installa Tools/lcsc_catalog_search.py e pip3 install gmssl requests"
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                scriptPath,
                "--keyword", keyword,
                "--limit", "\(limit)",
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                } else {
                    let err = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                    continuation.resume(throwing: ProviderError.networkFailure("LCSC search: \(err)"))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProviderError.networkFailure(error.localizedDescription))
            }
        }
    }
}
