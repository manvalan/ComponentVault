import Foundation

struct BOMImportLine: Identifiable {
    let id = UUID()
    let designator: String
    let lcscCode: String
    let mpn: String
    let quantity: Int
    let notes: String
}

struct BOMImportResult {
    let imported: Int
    let skipped: Int
    let missingLCSC: [String]
    let lines: [BOMImportLine]
}

enum BOMImporter {
    /// Formati supportati:
    /// - `Designator;LCSC;Quantità`
    /// - BOM DigiRadio: `No.;Quantity;Comment;Designator;MPN;...;LCSC;...`
    /// - `LCSC;MPN;...;Qty` (bom_riepilogo)
    static func parse(from url: URL) throws -> [BOMImportLine] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let header = lines.first else { return [] }

        let delimiter = header.contains(";") ? ";" : ","
        let columns = parseRow(header, delimiter: delimiter).map { $0.lowercased() }

        func index(of candidates: [String]) -> Int? {
            for candidate in candidates {
                if let idx = columns.firstIndex(where: { $0 == candidate || $0.contains(candidate) }) {
                    return idx
                }
            }
            return nil
        }

        let designatorIdx = index(of: ["designator", "ref", "reference"])
        let lcscIdx = index(of: ["lcsc", "codice"])
        let qtyIdx = index(of: ["quantity", "quantità", "quantita", "qty", "q.ty"])
        let mpnIdx = index(of: ["mpn", "part name", "partname"])
        let notesIdx = index(of: ["comment", "notes", "descrizione", "description", "value"])

        return lines.dropFirst().compactMap { line in
            let fields = parseRow(line, delimiter: delimiter)
            guard !fields.isEmpty else { return nil }

            let lcsc = lcscIdx.flatMap { fields[safe: $0] }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
            let mpn = mpnIdx.flatMap { fields[safe: $0] }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let designator = designatorIdx.flatMap { fields[safe: $0] }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let notes = notesIdx.flatMap { fields[safe: $0] }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let quantity: Int
            if let qtyIdx, let raw = fields[safe: qtyIdx], let parsed = Int(raw.trimmingCharacters(in: .whitespaces)) {
                quantity = max(1, parsed)
            } else {
                quantity = 1
            }

            guard !lcsc.isEmpty && lcsc.hasPrefix("C") else { return nil }

            return BOMImportLine(
                designator: designator,
                lcscCode: lcsc,
                mpn: mpn,
                quantity: quantity,
                notes: notes
            )
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
