import SwiftUI

struct SupplierComparisonView: View {
    let component: Component

    var body: some View {
        GroupBox("Confronto fornitori") {
            VStack(alignment: .leading, spacing: 14) {
                if let comparison = component.supplierComparison {
                    Label(comparison.summary, systemImage: "scale.3d")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(comparison.cheaper == .lcsc ? .orange : .red)
                }

                HStack(alignment: .top, spacing: 16) {
                    supplierCard(
                        title: "LCSC",
                        tint: .orange,
                        snapshot: component.lcscSnapshot,
                        unitPrice: component.supplierComparison?.lcscUnitPrice,
                        currency: component.supplierComparison?.lcscCurrency,
                        isCheaper: component.supplierComparison?.cheaper == .lcsc
                    )
                    supplierCard(
                        title: "DigiKey",
                        tint: .red,
                        snapshot: component.digikeySnapshot,
                        unitPrice: component.supplierComparison?.digikeyUnitPrice,
                        currency: component.supplierComparison?.digikeyCurrency,
                        isCheaper: component.supplierComparison?.cheaper == .digikey
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func supplierCard(
        title: String,
        tint: Color,
        snapshot: SupplierSnapshot?,
        unitPrice: Double?,
        currency: String?,
        isCheaper: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                if isCheaper {
                    Text("migliore")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.15))
                        .foregroundStyle(tint)
                        .clipShape(Capsule())
                }
            }

            if let snapshot {
                if let unitPrice, let currency {
                    Text(String(format: "%.4f %@", unitPrice, currency))
                        .font(.body.monospacedDigit().weight(.semibold))
                    Text("a qty \(max(component.quantity, 1))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let price = snapshot.price, let currency = snapshot.currency {
                    Text(String(format: "%.4f %@", price, currency))
                        .font(.body.monospacedDigit())
                } else {
                    Text("Prezzo n/d")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let stock = snapshot.supplierStock {
                    Text("Stock: \(stock)")
                        .font(.caption)
                        .foregroundStyle(stock == 0 ? .red : .secondary)
                }

                if let weeks = snapshot.leadTimeWeeks {
                    Text("Lead: \(weeks) sett.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let fetched = snapshot.fetchedDate {
                    Text(fetched.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Non arricchito")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCheaper ? tint.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
