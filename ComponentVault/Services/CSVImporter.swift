import Foundation

enum CSVImporter {
    /// Importa il CSV inventario (`Codice (LCSC);MPN;Descrizione;Footprint;Quantità`).
    static func importInventory(from url: URL) throws -> [ComponentRecord] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return [] }

        let delimiter = header.contains(";") ? ";" : ","
        let columns = parseRow(header, delimiter: delimiter).map { $0.lowercased() }

        func index(of candidates: [String]) -> Int? {
            columns.firstIndex { col in candidates.contains { col.contains($0) } }
        }

        let lcscIdx = index(of: ["codice", "lcsc"]) ?? 0
        let mpnIdx = index(of: ["mpn"])
        let descIdx = index(of: ["descrizione", "description"])
        let footprintIdx = index(of: ["footprint", "package"])
        let qtyIdx = index(of: ["quantità", "quantita", "qty", "quantity"])

        return lines.dropFirst().compactMap { line in
            let fields = parseRow(line, delimiter: delimiter)
            guard fields.count > lcscIdx else { return nil }

            let lcsc = fields[lcscIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lcsc.isEmpty, lcsc.hasPrefix("C") else { return nil }

            let qty = qtyIdx.flatMap { idx in
                Int(fields[safe: idx]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            } ?? 0

            return ComponentRecord(
                lcscCode: lcsc,
                mpn: fields[safe: mpnIdx ?? -1] ?? "",
                description: fields[safe: descIdx ?? -1] ?? "",
                footprint: fields[safe: footprintIdx ?? -1] ?? "",
                quantity: qty,
                dataSource: .manual
            )
        }
    }

    /// Importa `bom_riepilogo.csv` arricchito (con categoria e valore).
    static func importEnrichedBOM(from url: URL) throws -> [ComponentRecord] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else { return [] }

        return lines.dropFirst().compactMap { line in
            let fields = parseRow(line, delimiter: ";")
            guard fields.count >= 7 else { return nil }
            let lcsc = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard lcsc.hasPrefix("C") else { return nil }

            return ComponentRecord(
                lcscCode: lcsc,
                mpn: fields[1],
                description: fields[5],
                footprint: fields[4],
                quantity: Int(fields[6]) ?? 0,
                category: fields[2],
                value: fields[3],
                dataSource: .lcsc
            )
        }
    }

    /// Carica JSON pre-generati da `json_full_data/{LCSC}.json`.
    static func importJSONArchive(from directory: URL) throws -> [ComponentRecord] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var records: [ComponentRecord] = []
        var failures: [String] = []

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let record = try JSONDecoder().decode(ComponentRecord.self, from: data)
                records.append(record)
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        guard !records.isEmpty else {
            if let first = failures.first {
                throw ImportError.invalidJSON(first)
            }
            throw ImportError.emptyArchive
        }

        return records
    }

    enum ImportError: LocalizedError {
        case emptyArchive
        case invalidJSON(String)

        var errorDescription: String? {
            switch self {
            case .emptyArchive:
                "Nessun file JSON valido trovato nell'archivio."
            case .invalidJSON(let detail):
                "Errore lettura JSON: \(detail)"
            }
        }
    }

    private static func parseRow(_ line: String, delimiter: String) -> [String] {
        line.components(separatedBy: delimiter).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
