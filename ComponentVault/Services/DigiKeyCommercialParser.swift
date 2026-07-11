import Foundation

struct DigiKeyCommercialData: Sendable {
    var priceBreaks: [PriceBreak]
    var minimumOrderQuantity: Int?
    var leadTimeWeeks: Int?
    var productStatus: String?
    var supplierStock: Int?
}

enum DigiKeyCommercialParser {
    private struct FlexibleStringInt: Decodable {
        let intValue: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                intValue = value
            } else if let text = try? container.decode(String.self) {
                intValue = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                intValue = nil
            }
        }
    }

    private struct PricingResponse: Decodable {
        struct ProductPricing: Decodable {
            struct StandardPrice: Decodable {
                let breakQuantity: Int?
                let unitPrice: Double?
                let totalPrice: Double?

                enum CodingKeys: String, CodingKey {
                    case breakQuantity = "BreakQuantity"
                    case unitPrice = "UnitPrice"
                    case totalPrice = "TotalPrice"
                }
            }

            let standardPricing: [StandardPrice]?

            enum CodingKeys: String, CodingKey {
                case standardPricing = "StandardPricing"
            }
        }

        let productPricings: [ProductPricing]?

        enum CodingKeys: String, CodingKey {
            case productPricings = "ProductPricings"
        }
    }

    private struct DetailsResponse: Decodable {
        let minimumOrderQuantity: Int?
        let manufacturerLeadWeeks: FlexibleStringInt?
        let productStatus: String?
        let quantityAvailable: Int?

        enum CodingKeys: String, CodingKey {
            case minimumOrderQuantity = "MinimumOrderQuantity"
            case manufacturerLeadWeeks = "ManufacturerLeadWeeks"
            case productStatus = "ProductStatus"
            case quantityAvailable = "QuantityAvailable"
        }
    }

    static func parsePricing(data: Data) throws -> [PriceBreak] {
        let response = try JSONDecoder().decode(PricingResponse.self, from: data)
        let tiers = response.productPricings?.first?.standardPricing ?? []
        return tiers.compactMap { tier in
            guard let quantity = tier.breakQuantity, let unitPrice = tier.unitPrice else { return nil }
            return PriceBreak(
                quantity: quantity,
                unitPrice: unitPrice,
                totalPrice: tier.totalPrice
            )
        }
        .sorted { $0.quantity < $1.quantity }
    }

    static func parseDetails(data: Data) throws -> DigiKeyCommercialData {
        let details = try JSONDecoder().decode(DetailsResponse.self, from: data)
        return DigiKeyCommercialData(
            priceBreaks: [],
            minimumOrderQuantity: details.minimumOrderQuantity,
            leadTimeWeeks: details.manufacturerLeadWeeks?.intValue,
            productStatus: details.productStatus,
            supplierStock: details.quantityAvailable
        )
    }

    static func merge(_ base: DigiKeyCommercialData, pricing: [PriceBreak]) -> DigiKeyCommercialData {
        var merged = base
        merged.priceBreaks = pricing
        return merged
    }
}
