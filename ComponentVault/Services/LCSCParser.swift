import Foundation

/// Estrae i dati da una pagina prodotto LCSC (JSON-LD + __NEXT_DATA__).
struct LCSCParser {
    private struct JSONLD: Decodable {
        struct Brand: Decodable { let name: String }
        struct Property: Decodable {
            let name: String
            let value: String
        }
        struct Offer: Decodable {
            let price: Double?
            let priceCurrency: String?
            let inventoryLevel: FlexibleInt?
        }
        struct Document: Decodable { let url: String? }

        let type: String?
        let sku: String?
        let mpn: String?
        let name: String?
        let brand: Brand?
        let description: String?
        let category: String?
        let image: FlexibleImages?
        let additionalProperty: [Property]?
        let offers: Offer?
        let subjectOf: Document?

        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case sku, mpn, name, brand, description, category, image
            case additionalProperty, offers, subjectOf
        }
    }

    private struct FlexibleImages: Decodable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                values = [single]
            } else if let many = try? container.decode([String].self) {
                values = many
            } else {
                values = []
            }
        }
    }

    private struct FlexibleInt: Decodable {
        let value: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                value = intValue
            } else if let text = try? container.decode(String.self) {
                value = Int(text)
            } else if let doubleValue = try? container.decode(Double.self) {
                value = Int(doubleValue)
            } else {
                value = nil
            }
        }
    }

    private struct NextData: Decodable {
        struct Props: Decodable {
            struct PageProps: Decodable {
                struct WebData: Decodable {
                    let encapStandard: String?
                    let catalogName: String?
                    let parentCatalogName: String?
                }
                let webData: WebData?
            }
            let pageProps: PageProps?
        }
        let props: Props?
    }

    /// Decodifica un singolo blocco JSON-LD `Product`.
    private static func parseProductJSON(_ json: String, lcscCode: String) throws -> ComponentRecord {
        guard let ld = try? JSONDecoder().decode(JSONLD.self, from: Data(json.utf8)),
              ld.type == "Product" else {
            throw ProviderError.parseFailure
        }
        return record(from: ld, lcscCode: lcscCode, webData: nil)
    }

    static func parse(html: String, lcscCode: String) throws -> ComponentRecord {
        let productJSON = extractProductJSONLD(html: html)
        guard let productJSON else {
            throw ProviderError.parseFailure
        }

        guard let ld = try? JSONDecoder().decode(JSONLD.self, from: Data(productJSON.utf8)) else {
            throw ProviderError.parseFailure
        }

        let nextJSON = extractScriptContent(html: html, marker: "id=\"__NEXT_DATA__\"")
        let webData = nextJSON.flatMap { json in
            try? JSONDecoder().decode(NextData.self, from: Data(json.utf8))
        }?.props?.pageProps?.webData

        return record(from: ld, lcscCode: lcscCode, webData: webData)
    }

    private static func record(
        from ld: JSONLD,
        lcscCode: String,
        webData: NextData.Props.PageProps.WebData?
    ) -> ComponentRecord {
        let parameters = Dictionary(
            uniqueKeysWithValues: (ld.additionalProperty ?? []).map { ($0.name, $0.value) }
        )

        let value = inferValue(from: parameters, category: ld.category ?? "")

        return ComponentRecord(
            lcscCode: ld.sku ?? lcscCode,
            mpn: ld.mpn ?? "",
            name: ld.name ?? "",
            description: ld.description ?? "",
            footprint: webData?.encapStandard ?? parameters["Package"] ?? "",
            category: ld.category ?? webData?.catalogName ?? "",
            value: value,
            brand: ld.brand?.name ?? "",
            datasheetURL: ld.subjectOf?.url,
            imageURLs: ld.image?.values ?? [],
            price: ld.offers?.price,
            currency: ld.offers?.priceCurrency,
            supplierStock: ld.offers?.inventoryLevel?.value,
            dataSource: .lcsc,
            parameters: parameters,
            supplierProductURL: "https://www.lcsc.com/product-detail/\(ld.sku ?? lcscCode).html"
        )
    }

    private static func extractProductJSONLD(html: String) -> String? {
        var searchRange = html.startIndex..<html.endIndex
        let marker = "application/ld+json"

        while let markerRange = html.range(of: marker, range: searchRange) {
            let tail = html[markerRange.lowerBound...]
            if let open = tail.range(of: ">"), let close = tail.range(of: "</script>") {
                let json = String(tail[open.upperBound..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if json.contains("\"@type\":\"Product\"") || json.contains("\"@type\": \"Product\"") {
                    return json
                }
            }
            searchRange = markerRange.upperBound..<html.endIndex
        }

        return nil
    }

    private static func extractScriptContent(html: String, marker: String) -> String? {
        guard let markerRange = html.range(of: marker) else { return nil }
        let tail = html[markerRange.upperBound...]
        guard let open = tail.range(of: ">"), let close = tail.range(of: "</script>") else { return nil }
        return String(tail[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inferValue(from parameters: [String: String], category: String) -> String {
        let keys = [
            "Resistance", "Capacitance", "Inductance", "Voltage - Rated",
            "Voltage - Supply", "Frequency", "Tolerance"
        ]
        for key in keys {
            if let value = parameters[key], !value.isEmpty, value != "-" {
                return value
            }
        }
        if category.lowercased().contains("resistor"), let r = parameters["Resistance"] {
            return r
        }
        return "N/A"
    }
}
