import Foundation

/// Dati letti dall'etichetta di un sacchetto/bobina.
struct ScannedLabel: Equatable, Sendable {
    enum Kind: String, Sendable {
        case lcsc       // QR LCSC/JLCPCB: {pbn:…,pc:C25804,pm:0603WAF1002T5E,qty:100,…}
        case ecia       // DataMatrix ANSI MH10.8.2 dei distributori (MPN, quantità, produttore)
        case text       // codice a barre semplice o testo con un codice LCSC
    }

    var kind: Kind
    var lcsc: String?
    var mpn: String?
    var quantity: Int?
    var manufacturer: String?
    var raw: String

    var isUseful: Bool { lcsc != nil || mpn != nil }

    /// Titolo leggibile: MPN, altrimenti codice LCSC.
    var title: String { mpn ?? lcsc ?? raw }
}

/// Riconosce i formati di etichetta dei distributori. Il lettore USB (che "digita"
/// il codice) e la fotocamera passano entrambi da qui.
enum LabelParser {
    private static let groupSeparator: Character = "\u{1D}"
    private static let recordSeparator: Character = "\u{1E}"
    private static let endOfTransmission: Character = "\u{04}"

    static func parse(_ payload: String) -> ScannedLabel? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 4096 else { return nil }
        let label = parseLCSC(text) ?? parseECIA(text) ?? parsePlain(text)
        return label?.isUseful == true ? label : nil
    }

    // MARK: LCSC

    private static func parseLCSC(_ text: String) -> ScannedLabel? {
        guard text.hasPrefix("{"), text.hasSuffix("}"), text.contains("pc:") || text.contains("pm:") else { return nil }
        var fields: [String: String] = [:]
        for pair in text.dropFirst().dropLast().split(separator: ",") {
            guard let colon = pair.firstIndex(of: ":") else { continue }
            let key = pair[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[pair.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value != "null" { fields[key] = value }
        }
        let lcsc = fields["pc"].flatMap(normalizedLCSC)
        return ScannedLabel(
            kind: .lcsc,
            lcsc: lcsc,
            mpn: fields["pm"],
            quantity: fields["qty"].flatMap { Int($0) },
            manufacturer: nil,
            raw: text
        )
    }

    // MARK: ECIA / ANSI MH10.8.2

    private static func parseECIA(_ text: String) -> ScannedLabel? {
        guard text.hasPrefix("[)>") else { return nil }
        let body = text.dropFirst(3).filter { $0 != recordSeparator && $0 != endOfTransmission }
        let fields = body.split(separator: groupSeparator).map(String.init)
        guard fields.count > 1 else { return nil }

        var label = ScannedLabel(kind: .ecia, raw: text)
        var customerPart: String?
        for field in fields {
            // Gli identificatori più lunghi prima: "30P" e "1P" iniziano anche per "P".
            if value(of: field, identifier: "30P") != nil {
                continue  // codice del distributore: non serve
            } else if let value = value(of: field, identifier: "1P") {
                label.mpn = value
            } else if let value = value(of: field, identifier: "1V") {
                label.manufacturer = value
            } else if let value = value(of: field, identifier: "P") {
                customerPart = value
            } else if let value = value(of: field, identifier: "Q") {
                label.quantity = Int(value)
            }
        }
        if let customerPart, let lcsc = normalizedLCSC(customerPart) {
            label.lcsc = lcsc
        }
        return label
    }

    private static func value(of field: String, identifier: String) -> String? {
        guard field.hasPrefix(identifier) else { return nil }
        let value = field.dropFirst(identifier.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: Testo semplice

    private static func parsePlain(_ text: String) -> ScannedLabel? {
        if let lcsc = normalizedLCSC(text) {
            return ScannedLabel(kind: .text, lcsc: lcsc, raw: text)
        }
        if let match = text.firstMatch(of: lcscInText) {
            return ScannedLabel(kind: .text, lcsc: String(match.output.1).uppercased(), raw: text)
        }
        return nil
    }

    nonisolated(unsafe) private static let lcscInText = try! Regex<(Substring, Substring)>(#"(?:^|[^A-Za-z0-9])(C\d{3,9})(?:$|[^A-Za-z0-9])"#)

    static func normalizedLCSC(_ value: String) -> String? {
        let upper = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upper.count >= 4, upper.count <= 10, upper.first == "C",
              upper.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return upper
    }
}
