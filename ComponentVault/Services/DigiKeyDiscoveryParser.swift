import Foundation

enum DigiKeyDiscoveryParser {
    private struct ProductList: Decodable {
        struct Item: Decodable {
            let digiKeyPartNumber: String?
            let manufacturerProductNumber: String?
            let description: ProductDescription?
            let manufacturer: Named?
            let productUrl: String?
            let quantityAvailable: Int?
            let unitPrice: Double?

            enum CodingKeys: String, CodingKey {
                case digiKeyPartNumber = "DigiKeyPartNumber"
                case manufacturerProductNumber = "ManufacturerProductNumber"
                case description = "Description"
                case manufacturer = "Manufacturer"
                case productUrl = "ProductUrl"
                case quantityAvailable = "QuantityAvailable"
                case unitPrice = "UnitPrice"
            }
        }

        struct ProductDescription: Decodable {
            let productDescription: String?

            enum CodingKeys: String, CodingKey {
                case productDescription = "ProductDescription"
            }
        }

        struct Named: Decodable {
            let name: String?

            enum CodingKeys: String, CodingKey {
                case name = "Name"
            }
        }

        let products: [Item]?

        enum CodingKeys: String, CodingKey {
            case products = "Products"
        }
    }

    static func parseCrossReferences(
        data: Data,
        currency: String,
        referenceMPN: String
    ) throws -> [DigiKeyCrossReference] {
        try decodeProducts(data).map { item in
            let mpn = item.manufacturerProductNumber ?? referenceMPN
            return DigiKeyCrossReference(
                digikeyPartNumber: item.digiKeyPartNumber ?? "",
                mpn: mpn,
                description: item.description?.productDescription ?? "",
                manufacturer: item.manufacturer?.name ?? "",
                productURL: item.productUrl,
                unitPrice: item.unitPrice,
                currency: currency,
                stock: item.quantityAvailable,
                record: recordIfPossible(from: item, mpn: mpn, currency: currency)
            )
        }
    }

    static func parseAlternatePackaging(data: Data) throws -> [DigiKeyAlternatePackage] {
        try decodeProducts(data).map { item in
            DigiKeyAlternatePackage(
                digikeyPartNumber: item.digiKeyPartNumber ?? "",
                mpn: item.manufacturerProductNumber ?? "",
                description: item.description?.productDescription ?? "",
                packaging: item.manufacturer?.name ?? "Alternate",
                unitPrice: item.unitPrice,
                stock: item.quantityAvailable
            )
        }
    }

    private static func decodeProducts(_ data: Data) throws -> [ProductList.Item] {
        let response = try JSONDecoder().decode(ProductList.self, from: data)
        return response.products ?? []
    }

    private static func recordIfPossible(
        from item: ProductList.Item,
        mpn: String,
        currency: String
    ) -> ComponentRecord? {
        guard let partNumber = item.digiKeyPartNumber, !partNumber.isEmpty else { return nil }
        return ComponentRecord(
            lcscCode: DigiKeySyntheticCode.make(from: partNumber),
            mpn: mpn.isEmpty ? partNumber : mpn,
            name: mpn.isEmpty ? partNumber : mpn,
            description: item.description?.productDescription ?? "",
            brand: item.manufacturer?.name ?? "",
            price: item.unitPrice,
            currency: currency,
            supplierStock: item.quantityAvailable,
            dataSource: .digikey,
            digikeyPartNumber: partNumber,
            supplierProductURL: item.productUrl
        )
    }
}
