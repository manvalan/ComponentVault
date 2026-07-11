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
