import SwiftUI

struct FilterBar: View {
    @Binding var filter: ComponentFilter
    let components: [Component]
    @State private var isExpanded = false
    @State private var categoryOptions: [String] = ["Tutte"]
    @State private var footprintOptions: [String] = ["Tutti"]
    @State private var brandOptions: [String] = ["Tutti"]
    @State private var tagOptions: [String] = ["Tutti"]

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
                        filterPicker("Categoria", selection: $filter.category, options: categoryOptions)
                        filterPicker("Footprint", selection: $filter.footprint, options: footprintOptions)
                    }
                    GridRow {
                        filterPicker("Brand", selection: $filter.brand, options: brandOptions)
                        filterPicker("Tag", selection: $filter.tag, options: tagOptions)
                    }
                    GridRow {
                        Toggle("Solo scorte basse", isOn: $filter.showLowStockOnly)
                        Toggle("Solo esauriti", isOn: $filter.showOutOfStockOnly)
                    }
                    GridRow {
                        Toggle("Con dati DigiKey", isOn: $filter.requireDigiKeyData)
                        Toggle("DigiKey stock 0", isOn: $filter.digikeyOutOfStockOnly)
                    }
                }
                .font(.caption)
            }
        }
        .padding(8)
        .onAppear { rebuildFilterOptions() }
        .onChange(of: components.count) { _, _ in rebuildFilterOptions() }
    }

    private func rebuildFilterOptions() {
        categoryOptions = ComponentFilter.categories(from: components)
        footprintOptions = ComponentFilter.footprints(from: components)
        brandOptions = ComponentFilter.brands(from: components)
        tagOptions = ComponentFilter.tags(from: components)
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
