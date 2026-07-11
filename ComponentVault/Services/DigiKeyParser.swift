import Foundation

enum DigiKeyParser {
    struct SearchResponse: Decodable {
        struct Product: Decodable {
            struct Description: Decodable {
                let productDescription: String?

                enum CodingKeys: String, CodingKey {
                    case productDescription = "ProductDescription"
                }
            }

            struct Manufacturer: Decodable {
                let name: String?

                enum CodingKeys: String, CodingKey {
                    case name = "Name"
                }
            }

            struct Category: Decodable {
                let name: String?

                enum CodingKeys: String, CodingKey {
                    case name = "Name"
                }
            }

            struct Parameter: Decodable {
                let parameterText: String?
                let valueText: String?

                enum CodingKeys: String, CodingKey {
                    case parameterText = "ParameterText"
                    case valueText = "ValueText"
                }
            }

            let digiKeyPartNumber: String?
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

            enum CodingKeys: String, CodingKey {
                case digiKeyPartNumber = "DigiKeyPartNumber"
                case manufacturerProductNumber = "ManufacturerProductNumber"
                case description = "Description"
                case manufacturer = "Manufacturer"
                case category = "Category"
                case productUrl = "ProductUrl"
                case datasheetUrl = "DatasheetUrl"
                case photoUrl = "PhotoUrl"
                case quantityAvailable = "QuantityAvailable"
                case unitPrice = "UnitPrice"
                case parameters = "Parameters"
            }
        }

        let products: [Product]?

        enum CodingKeys: String, CodingKey {
            case products = "Products"
        }
    }

    static func parseCandidates(
        data: Data,
        mpn: String,
        lcscCode: String,
        currency: String
    ) throws -> [DigiKeyCandidate] {
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let products = response.products, !products.isEmpty else {
            throw ProviderError.notFound(mpn)
        }

        return products.map { product in
            let record = record(from: product, mpn: mpn, lcscCode: lcscCode, currency: currency)
            return DigiKeyCandidate(
                digikeyPartNumber: product.digiKeyPartNumber ?? "",
                mpn: product.manufacturerProductNumber ?? mpn,
                description: product.description?.productDescription ?? "",
                manufacturer: product.manufacturer?.name ?? "",
                productURL: product.productUrl,
                unitPrice: product.unitPrice,
                currency: currency,
                stock: product.quantityAvailable,
                record: record
            )
        }
    }

    static func parse(data: Data, mpn: String, lcscCode: String, currency: String) throws -> ComponentRecord {
        let candidates = try parseCandidates(data: data, mpn: mpn, lcscCode: lcscCode, currency: currency)
        return candidates[0].record
    }

    private static func record(
        from product: SearchResponse.Product,
        mpn: String,
        lcscCode: String,
        currency: String
    ) -> ComponentRecord {
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
            parameters: parameters,
            digikeyPartNumber: product.digiKeyPartNumber,
            supplierProductURL: product.productUrl
        )
    }

    private static func inferValue(from parameters: [String: String]) -> String {
        for key in ["Resistance", "Capacitance", "Inductance", "Voltage - Rated"] {
            if let value = parameters[key], !value.isEmpty { return value }
        }
        return "N/A"
    }
}
