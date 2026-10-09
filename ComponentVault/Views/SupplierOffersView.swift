import SwiftUI

/// Prezzi e disponibilità dai distributori autorizzati (Mouser, DigiKey) per l'MPN
/// del componente. Richiesta al momento, nulla viene salvato.
struct SupplierOffersSection: View {
    let mpn: String
    let quantity: Int

    @State private var outcome: SupplierOfferService.Outcome?
    @State private var isLoading = false

    private var suppliers: [String] { SupplierOfferService.configuredSuppliers }

    var body: some View {
        GroupBox("Prezzi e disponibilità") {
            VStack(alignment: .leading, spacing: 10) {
                if suppliers.isEmpty {
                    Text("Nessun distributore configurato. Inserisci la tua chiave Mouser o le credenziali DigiKey in Impostazioni → Fornitori.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if mpn.isEmpty {
                    Text("Serve un MPN per cercare prezzi e disponibilità.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button {
                            Task { await load() }
                        } label: {
                            Label(outcome == nil ? "Cerca su \(suppliers.joined(separator: ", "))" : "Aggiorna",
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                    if let outcome {
                        ForEach(outcome.errors, id: \.self) { error in
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                        if outcome.offers.isEmpty, outcome.errors.isEmpty {
                            Text("Nessuna offerta trovata.").foregroundStyle(.secondary)
                        }
                        ForEach(outcome.offers) { offer in
                            offerRow(offer)
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func offerRow(_ offer: SupplierOffer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(offer.supplier).font(.headline)
                Text(offer.supplierPartNumber.isEmpty ? offer.mpn : offer.supplierPartNumber)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let lifecycle = offer.lifecycle {
                    Text(lifecycle).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let price = offer.unitPrice(for: quantity) {
                    Text(String(format: "%.4f %@", price, offer.currency ?? ""))
                        .font(.body.monospacedDigit())
                    Text("a qty \(max(quantity, 1))").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Prezzo n/d").foregroundStyle(.secondary)
                }
                Text(offer.stock.map { String(localized: "Stock: \($0)") } ?? String(localized: "Stock n/d"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle((offer.stock ?? 0) > 0 ? .green : .secondary)
                if let lead = offer.leadTime {
                    Text(lead).font(.caption2).foregroundStyle(.secondary)
                }
                if let url = offer.productURL {
                    Link(destination: url) {
                        Label("Apri", systemImage: "arrow.up.right")
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let result = await SupplierOfferService.offers(forMPN: mpn)
        outcome = result
    }
}
