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

enum DigiKeySyntheticCode {
    static func make(from digikeyPartNumber: String) -> String {
        let upper = digikeyPartNumber.uppercased()
        let sanitized = upper
            .replacingOccurrences(of: "[^A-Z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let body = sanitized.isEmpty ? "UNKNOWN" : String(sanitized.prefix(48))
        return "DK-\(body)"
    }

    static func isDigiKeyOnly(_ code: String) -> Bool {
        code.uppercased().hasPrefix("DK-")
    }
}

enum LCSCCode {
    static func isValid(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.hasPrefix("C") && normalized.count >= 4
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
