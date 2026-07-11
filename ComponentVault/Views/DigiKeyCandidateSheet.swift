import SwiftUI

struct DigiKeyCandidateSheet: View {
    let candidates: [DigiKeyCandidate]
    let onSelect: (DigiKeyCandidate) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Più risultati DigiKey")
                .font(.title2.weight(.semibold))
            Text("Scegli il prodotto corretto per questo componente.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List(candidates) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(candidate.digikeyPartNumber.isEmpty ? candidate.mpn : candidate.digikeyPartNumber)
                                .font(.headline.monospaced())
                            Spacer()
                            if let price = candidate.unitPrice, let currency = candidate.currency {
                                Text(String(format: "%.3f %@", price, currency))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !candidate.mpn.isEmpty {
                            Text(candidate.mpn)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        if !candidate.manufacturer.isEmpty {
                            Text(candidate.manufacturer)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !candidate.description.isEmpty {
                            Text(candidate.description)
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                        if let stock = candidate.stock {
                            Text("Stock: \(stock)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)

            HStack {
                Spacer()
                Button("Annulla", action: onCancel)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 400)
    }
}
