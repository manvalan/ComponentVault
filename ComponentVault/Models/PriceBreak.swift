import Foundation

struct PriceBreak: Codable, Hashable, Sendable, Identifiable {
    var id: Int { quantity }

    let quantity: Int
    let unitPrice: Double
    let totalPrice: Double?

    init(quantity: Int, unitPrice: Double, totalPrice: Double? = nil) {
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.totalPrice = totalPrice
    }
}

enum PriceBreakCodec {
    static func encode(_ breaks: [PriceBreak]) -> String {
        guard let data = try? JSONEncoder().encode(breaks),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    static func decode(_ json: String) -> [PriceBreak] {
        guard let data = json.data(using: .utf8),
              let breaks = try? JSONDecoder().decode([PriceBreak].self, from: data) else {
            return []
        }
        return breaks.sorted { $0.quantity < $1.quantity }
    }

    static func unitPrice(for quantity: Int, in breaks: [PriceBreak]) -> Double? {
        let sorted = breaks.sorted { $0.quantity < $1.quantity }
        guard !sorted.isEmpty else { return nil }

        var selected = sorted[0]
        for item in sorted where quantity >= item.quantity {
            selected = item
        }
        return selected.unitPrice
    }
}
