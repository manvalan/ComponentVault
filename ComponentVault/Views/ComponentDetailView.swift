import SwiftUI

struct ComponentDetailView: View {
    @Bindable var component: Component
    var store: ComponentStore?

    @State private var selectedImageIndex = 0
    @State private var isEnriching = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                HStack(alignment: .top, spacing: 24) {
                    imageGallery
                    inventoryCard
                }
                descriptionSection
                parametersSection
                linksSection
            }
            .padding(24)
        }
        .navigationTitle(component.displayTitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await enrich() }
                } label: {
                    if isEnriching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Aggiorna da LCSC", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isEnriching || store == nil)

                Link(destination: lcscURL) {
                    Label("Apri su LCSC", systemImage: "safari")
                }
            }
        }
        .alert("Errore", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(component.lcscCode)
                    .font(.title2.monospaced())
                SourceBadge(source: component.source)
            }
            if !component.brand.isEmpty {
                Text(component.brand)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !component.category.isEmpty {
                Text(component.category)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    private var imageGallery: some View {
        VStack(spacing: 8) {
            if component.imageURLs.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 220, height: 220)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
            } else {
                TabView(selection: $selectedImageIndex) {
                    ForEach(Array(component.imageURLs.enumerated()), id: \.offset) { index, urlString in
                        AsyncImage(url: URL(string: urlString)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            case .failure:
                                Image(systemName: "photo.badge.exclamationmark")
                            default:
                                ProgressView()
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.automatic)
                .frame(width: 220, height: 220)
            }
        }
    }

    private var inventoryCard: some View {
        GroupBox("Inventario") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Quantità") {
                    Stepper(value: Binding(
                        get: { component.quantity },
                        set: { newValue in
                            component.quantity = newValue
                            try? store?.updateQuantity(component, to: newValue)
                        }
                    ), in: 0...999_999) {
                        Text("\(component.quantity)")
                            .font(.title3.monospacedDigit())
                    }
                }
                if !component.value.isEmpty && component.value != "N/A" {
                    LabeledContent("Valore", value: component.value)
                }
                if !component.footprint.isEmpty {
                    LabeledContent("Footprint", value: component.footprint)
                }
                if !component.mpn.isEmpty {
                    LabeledContent("MPN", value: component.mpn)
                }
                if let price = component.price, let currency = component.currency {
                    LabeledContent("Prezzo LCSC") {
                        Text(String(format: "%.3f %@", price, currency))
                    }
                }
                if let stock = component.supplierStock {
                    LabeledContent("Stock fornitore", value: "\(stock)")
                }
                LabeledContent("Ultimo aggiornamento") {
                    Text(component.lastUpdated.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 360)
    }

    private var descriptionSection: some View {
        Group {
            if !component.componentDescription.isEmpty {
                GroupBox("Descrizione") {
                    Text(component.componentDescription)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var parametersSection: some View {
        Group {
            if !component.parameters.isEmpty {
                GroupBox("Parametri tecnici") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(component.parameters.sorted(by: { $0.name < $1.name }), id: \.persistentModelID) { param in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(param.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(param.value)
                                    .font(.body)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.gray.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private var linksSection: some View {
        HStack(spacing: 12) {
            if let datasheet = component.datasheetURL, let url = URL(string: datasheet) {
                Link(destination: url) {
                    Label("Datasheet PDF", systemImage: "doc.richtext")
                }
                .buttonStyle(.bordered)
            }
            Link(destination: lcscURL) {
                Label("Pagina LCSC", systemImage: "link")
            }
            .buttonStyle(.bordered)
        }
    }

    private var lcscURL: URL {
        URL(string: "https://www.lcsc.com/product-detail/\(component.lcscCode).html")!
    }

    private func enrich() async {
        guard let store else { return }
        isEnriching = true
        defer { isEnriching = false }
        do {
            try await store.enrichFromLCSC(component)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SourceBadge: View {
    let source: DataSource

    var body: some View {
        Text(source.label.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch source {
        case .manual: .gray
        case .lcsc: .orange
        case .digikey: .red
        }
    }
}

struct ComponentThumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.12)
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
        }
    }
}
