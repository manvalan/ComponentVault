import SwiftUI

struct FilterBar: View {
    @Binding var filter: ComponentFilter
    let components: [Component]
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Cerca MPN, valore, LCSC…", text: $filter.searchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Label("Filtri", systemImage: isExpanded ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
            }

            if isExpanded {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        filterPicker("Categoria", selection: $filter.category, options: ComponentFilter.categories(from: components))
                        filterPicker("Footprint", selection: $filter.footprint, options: ComponentFilter.footprints(from: components))
                    }
                    GridRow {
                        filterPicker("Brand", selection: $filter.brand, options: ComponentFilter.brands(from: components))
                        filterPicker("Tag", selection: $filter.tag, options: ComponentFilter.tags(from: components))
                    }
                    GridRow {
                        Toggle("Solo scorte basse", isOn: $filter.showLowStockOnly)
                        Toggle("Solo esauriti", isOn: $filter.showOutOfStockOnly)
                    }
                }
                .font(.caption)
            }
        }
        .padding(8)
    }

    private func filterPicker(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        }
    }
}
