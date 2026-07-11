import Foundation

/// Risultato ricerca DigiKey mostrato nella sheet di disambiguazione.
struct DigiKeyCandidate: Identifiable, Sendable {
    var id: String { digikeyPartNumber.isEmpty ? mpn : digikeyPartNumber }

    let digikeyPartNumber: String
    let mpn: String
    let description: String
    let manufacturer: String
    let productURL: String?
    let unitPrice: Double?
    let currency: String?
    let stock: Int?
    let record: ComponentRecord
}
