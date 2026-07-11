import Foundation

/// Estrae i dati da una pagina prodotto LCSC (JSON-LD + __NEXT_DATA__).
struct LCSCParser {
    struct JSONLD: Decodable {
        struct Brand: Decodable { let name: String }
        struct Property: Decodable { let name: String; let value: String }
        struct Offer: Decodable {
            let price: Double?
            let priceCurrency: String?
            let inventoryLevel: Int?
        }
        struct Document: Decodable { let url: String? }

        let sku: String?
        let mpn: String?
        let name: String?
        let brand: Brand?
        let description: String?
        let category: String?
        let image: [String]?
        let additionalProperty: [Property]?
        let offers: Offer?
        let subjectOf: Document?
    }

    struct NextData: Decodable {
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

    static func parse(html: String, lcscCode: String) throws -> ComponentRecord {
        guard let ldJSON = extractScriptContent(html: html, marker: #"type="application/ld\+json""#),
              let ld = try? JSONDecoder().decode(JSONLD.self, from: Data(ldJSON.utf8))
        else {
            throw ProviderError.parseFailure
        }

        let nextJSON = extractScriptContent(html: html, marker: #"id="__NEXT_DATA__""#)
        let webData = nextJSON.flatMap { json in
            try? JSONDecoder().decode(NextData.self, from: Data(json.utf8))
        }?.props?.pageProps?.webData

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
            imageURLs: ld.image ?? [],
            price: ld.offers?.price,
            currency: ld.offers?.priceCurrency,
            supplierStock: ld.offers?.inventoryLevel,
            dataSource: .lcsc,
            parameters: parameters
        )
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
