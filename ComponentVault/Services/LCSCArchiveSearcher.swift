import Foundation

enum LCSCArchiveSearcher {
    private static var archivePath: String { AppPaths.jsonArchivePath }

    static func search(
        query: CatalogSearchQuery,
        inventory: [Component],
        limit: Int = 30
    ) -> [ComponentRecord] {
        var results: [ComponentRecord] = []
        var seen = Set<String>()

        for component in inventory where CatalogMatchNormalizer.matches(
            recordType: component.componentType,
            recordValue: component.displayValue,
            recordFootprint: component.displayFootprint,
            query: query
        ) {
            let record = component.toRecord()
            guard seen.insert(record.lcscCode).inserted else { continue }
            results.append(record)
            if results.count >= limit { return results }
        }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: archivePath) else {
            return results
        }

        for filename in files where filename.hasSuffix(".json") {
            let code = String(filename.dropLast(5))
            guard code.hasPrefix("C"), seen.insert(code).inserted else { continue }

            let path = "\(archivePath)/\(filename)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let record = try? JSONDecoder().decode(ComponentRecord.self, from: data) else {
                continue
            }

            let type = ComponentType.from(category: record.category)
            let value = record.value.isEmpty || record.value == "N/A"
                ? inferValue(from: record.parameters)
                : record.value
            let footprint = record.footprint.isEmpty
                ? (record.parameters["Package"] ?? record.parameters["Package / Case"] ?? "")
                : record.footprint

            guard CatalogMatchNormalizer.matches(
                recordType: type,
                recordValue: value,
                recordFootprint: footprint,
                query: query
            ) else { continue }

            results.append(record)
            if results.count >= limit { break }
        }

        return results
    }

    static func findByMPN(_ mpn: String, inventory: [Component]) -> ComponentRecord? {
        searchByMPN(mpn, inventory: inventory, limit: 1).first
    }

    static func searchByMPN(
        _ mpn: String,
        inventory: [Component] = [],
        limit: Int = 10
    ) -> [ComponentRecord] {
        let target = CatalogMatchNormalizer.mpn(mpn)
        guard !target.isEmpty else { return [] }

        var results: [ComponentRecord] = []
        var seen = Set<String>()

        for component in inventory where CatalogMatchNormalizer.mpn(component.mpn) == target {
            guard LCSCCode.isValid(component.lcscCode) else { continue }
            let record = component.toRecord()
            guard seen.insert(record.lcscCode).inserted else { continue }
            results.append(record)
            if results.count >= limit { return results }
        }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: archivePath) else {
            return results
        }

        for filename in files where filename.hasSuffix(".json") {
            let code = String(filename.dropLast(5))
            guard code.hasPrefix("C"), seen.insert(code).inserted else { continue }

            let path = "\(archivePath)/\(filename)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let record = try? JSONDecoder().decode(ComponentRecord.self, from: data),
                  CatalogMatchNormalizer.mpn(record.mpn) == target else {
                continue
            }

            results.append(record)
            if results.count >= limit { break }
        }

        return results
    }

    private static func inferValue(from parameters: [String: String]) -> String {
        for key in ["Resistance", "Capacitance", "Inductance", "Voltage - Rated"] {
            if let value = parameters[key], !value.isEmpty, value != "-" { return value }
        }
        return "N/A"
    }
}
