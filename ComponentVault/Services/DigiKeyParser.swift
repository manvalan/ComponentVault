import Foundation

enum DigiKeyParser {
    struct SearchResponse: Decodable {
        struct Product: Decodable {
            struct Description: Decodable { let productDescription: String? }
            struct Manufacturer: Decodable { let name: String? }
            struct Category: Decodable { let name: String? }
            struct Parameter: Decodable {
                let parameterText: String?
                let valueText: String?
            }

            let manufacturerProductNumber: String?
            let description: Description?
            let manufacturer: Manufacturer?
            let category: Category?
            let productUrl: String?
            let datasheetUrl: String?
            let photoUrl: String?
            let quantityAvailable: Int?
            let unitPrice: Double?
            let parameters: [Parameter]?
        }

        let products: [Product]?

        enum CodingKeys: String, CodingKey {
            case products = "Products"
        }
    }

    static func parse(data: Data, mpn: String, lcscCode: String, currency: String) throws -> ComponentRecord {
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let product = response.products?.first else {
            throw ProviderError.notFound(mpn)
        }

        let parameters = Dictionary(
            uniqueKeysWithValues: (product.parameters ?? []).compactMap { param -> (String, String)? in
                guard let key = param.parameterText, let value = param.valueText else { return nil }
                return (key, value)
            }
        )

        return ComponentRecord(
            lcscCode: lcscCode,
            mpn: product.manufacturerProductNumber ?? mpn,
            name: product.manufacturerProductNumber ?? mpn,
            description: product.description?.productDescription ?? "",
            footprint: parameters["Package / Case"] ?? parameters["Package"] ?? "",
            category: product.category?.name ?? "",
            value: inferValue(from: parameters),
            brand: product.manufacturer?.name ?? "",
            datasheetURL: product.datasheetUrl,
            imageURLs: product.photoUrl.map { [$0] } ?? [],
            price: product.unitPrice,
            currency: currency,
            supplierStock: product.quantityAvailable,
            dataSource: .digikey,
            parameters: parameters
        )
    }

    private static func inferValue(from parameters: [String: String]) -> String {
        for key in ["Resistance", "Capacitance", "Inductance", "Voltage - Rated"] {
            if let value = parameters[key], !value.isEmpty { return value }
        }
        return "N/A"
    }
}
