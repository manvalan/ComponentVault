import SwiftUI

/// Filtro della BOM scelto toccando uno degli anelli di stato.
enum BOMFocus: String, CaseIterable, Identifiable {
    case stock, kicad, price

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stock: String(localized: "Magazzino")
        case .kicad: "KiCad"
        case .price: String(localized: "Prezzi")
        }
    }

    var icon: String {
        switch self {
        case .stock: "shippingbox"
        case .kicad: "books.vertical"
        case .price: "eurosign"
        }
    }

    var tint: Color {
        switch self {
        case .stock: .green
        case .kicad: .blue
        case .price: .purple
        }
    }
}

/// Anello di avanzamento in stile Fitness: tocca per filtrare ciò che manca.
struct HealthRing: View {
    let focus: BOMFocus
    let done: Int
    let total: Int
    let isSelected: Bool
    let action: () -> Void

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(focus.tint.opacity(0.15), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(focus.tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(duration: 0.6), value: fraction)
                    if total > 0 && done == total {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(focus.tint)
                    } else {
                        Text("\(done)")
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .frame(width: 62, height: 62)

                VStack(spacing: 1) {
                    Text(focus.title).font(.subheadline.weight(.medium))
                    Text(total - done == 0 ? "completo" : "\(total - done) da fare")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? focus.tint.opacity(0.12) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(focus.title): \(done) di \(total)")
        .accessibilityHint("Mostra solo le righe da completare")
    }
}

/// Pallino di stato con icona, usato nelle righe BOM.
struct StatusDot: View {
    let systemImage: String
    let ok: Bool?
    let help: String

    var body: some View {
        Image(systemName: systemImage)
            .symbolVariant(ok == true ? .fill : .none)
            .font(.caption)
            .foregroundStyle(ok == true ? Color.green : ok == false ? Color.orange : Color.secondary.opacity(0.5))
            .frame(width: 18)
            .platformHelp(help)
            .accessibilityLabel(help)
    }
}

/// Riga BOM essenziale: cosa è, quanti ne servono, cosa manca.
struct BOMRow: View {
    let item: ProjectItem
    let kicad: KiCadLibraryMatch
    let price: String?

    private var title: String {
        guard let component = item.component else { return String(localized: "Componente non in inventario") }
        if !component.value.isEmpty { return component.value }
        return component.displayTitle
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(item.designator.isEmpty ? "—" : item.designator)
                .font(.callout.monospaced().weight(.semibold))
                .frame(minWidth: 44, alignment: .leading)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                Text(item.component?.mpn.isEmpty == false ? item.component!.mpn : (item.component?.inventoryCode ?? "—"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let price {
                Text(price)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(item.requiredQuantity)")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("disp. \(item.availableQuantity)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(item.isAvailable ? Color.secondary : Color.orange)
            }
            .frame(minWidth: 52, alignment: .trailing)

            HStack(spacing: 4) {
                StatusDot(
                    systemImage: "shippingbox",
                    ok: item.isAvailable,
                    help: item.isAvailable ? String(localized: "Disponibile in magazzino") : String(localized: "Da ordinare: mancano \(item.shortage)")
                )
                StatusDot(systemImage: "books.vertical", ok: kicadOK, help: kicadHelp)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var kicadOK: Bool? {
        switch kicad {
        case .present: true
        case .missing: false
        case .noPartNumber, .unknown: nil
        }
    }

    private var kicadHelp: String {
        switch kicad {
        case .present(let entry): String(localized: "In libreria KiCad: \(entry.lib)")
        case .missing: String(localized: "Non in libreria KiCad")
        case .noPartNumber: String(localized: "Senza MPN: non verificabile")
        case .unknown: String(localized: "Indice libreria KiCad non ancora disponibile")
        }
    }
}

/// Pulsante principale in fondo allo schermo: una sola azione, quella che serve adesso.
struct PrimaryActionBar: View {
    let title: String
    let systemImage: String
    var subtitle: String? = nil
    var isWorking = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 10) {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: systemImage)
                    }
                    Text(title).fontWeight(.semibold)
                }
                .frame(maxWidth: 420)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(disabled || isWorking)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.bar)
    }
}
