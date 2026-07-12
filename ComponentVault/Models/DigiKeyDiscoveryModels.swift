import Foundation

struct DigiKeyCrossReference: Identifiable, Sendable {
    var id: String { digikeyPartNumber.isEmpty ? mpn : digikeyPartNumber }

    let digikeyPartNumber: String
    let mpn: String
    let description: String
    let manufacturer: String
    let productURL: String?
    let unitPrice: Double?
    let currency: String?
    let stock: Int?
    let record: ComponentRecord?
}

struct DigiKeyAlternatePackage: Identifiable, Sendable {
    var id: String { digikeyPartNumber }

    let digikeyPartNumber: String
    let mpn: String
    let description: String
    let packaging: String
    let unitPrice: Double?
    let stock: Int?
}

/// Codice inventario interno ComponentVault quando non esiste un codice LCSC (Cxxxxx).
/// Prefisso `CV-` — chiaramente distinto dai codici LCSC.
enum InternalComponentCode {
    static let prefix = "CV-"

    static func make(from seed: String) -> String {
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.uppercased()
            .replacingOccurrences(of: "[^A-Z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if !sanitized.isEmpty {
            return prefix + String(sanitized.prefix(40))
        }

        var hasher = Hasher()
        hasher.combine(trimmed.isEmpty ? UUID().uuidString : trimmed)
        let hash = abs(hasher.finalize())
        return String(format: "\(prefix)INT-%06X", hash % 0xFFFFFF)
    }

    static func isInternal(_ code: String) -> Bool {
        let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return upper.hasPrefix("CV-") || upper.hasPrefix("DK-")
    }

    /// Vecchi placeholder `DK-*` (pre CV-) o `DK-UNKNOWN`.
    static func isLegacyPlaceholder(_ code: String) -> Bool {
        code.uppercased().hasPrefix("DK-")
    }

    /// Converte un vecchio `DK-*` nel corrispondente `CV-*` (stesso corpo o rigenerato dal seed).
    static func migrateLegacyCode(_ code: String, seed: String) -> String {
        guard isLegacyPlaceholder(code) else { return code }
        let body = String(code.dropFirst(3))
        if body.isEmpty || body.uppercased() == "UNKNOWN" || body.uppercased() == "SEARCH" {
            return make(from: seed)
        }
        return prefix + String(body.prefix(40))
    }

    /// Placeholder per ricerche catalogo DigiKey (non va in inventario).
    static let catalogSearchPlaceholder = "CV-CATALOG-SEARCH"
}

enum DigiKeySyntheticCode {
    static func make(from digikeyPartNumber: String) -> String {
        InternalComponentCode.make(from: digikeyPartNumber)
    }

    static func isDigiKeyOnly(_ code: String) -> Bool {
        InternalComponentCode.isInternal(code) && !LCSCCode.isValid(code)
    }
}

enum LCSCCode {
    static func isValid(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.hasPrefix("C") && normalized.count >= 4
            && normalized.dropFirst().allSatisfy(\.isNumber)
    }

    static func extract(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        guard let range = urlString.range(
            of: #"product-detail/(C\d+)\.html"#,
            options: .regularExpression
        ) else { return nil }
        let match = String(urlString[range])
        let code = match
            .replacingOccurrences(of: "product-detail/", with: "")
            .replacingOccurrences(of: ".html", with: "")
        return isValid(code) ? code.uppercased() : nil
    }
}
