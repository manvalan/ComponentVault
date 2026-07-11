import SwiftUI
import SwiftData

struct CatalogTypeRow: Identifiable, Hashable {
    let type: ComponentType
    let count: Int
    var id: String { type.id }
}

struct CatalogView: View {
    @Query(sort: \Component.lcscCode) private var components: [Component]

    @State private var selectedType: ComponentType?
    @State private var selectedGroupID: String?
    @State private var selectedComponent: Component?
    @State private var searchText = ""
    @State private var showSupplierLookup = false
    @State private var showDigiKeyExplorer = false
    @State private var store: ComponentStore?

    @Environment(\.modelContext) private var modelContext

    private var index: CatalogIndex {
        CatalogIndex.build(from: components)
    }

    private var typeRows: [CatalogTypeRow] {
        index.sortedTypes.map { type in
            CatalogTypeRow(type: type, count: index.typeCounts[type, default: 0])
        }
    }

    private var groups: [CatalogGroup] {
        guard let selectedType else { return [] }
        return index.groupsByType[selectedType] ?? []
    }

    private var filteredGroups: [CatalogGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.value.localizedCaseInsensitiveContains(query)
                || group.footprint.localizedCaseInsensitiveContains(query)
                || group.components.contains {
                    $0.mpn.localizedCaseInsensitiveContains(query)
                        || $0.lcscCode.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var activeGroup: CatalogGroup? {
        if let selectedGroupID, let group = filteredGroups.first(where: { $0.id == selectedGroupID }) {
            return group
        }
        return filteredGroups.first
    }

    var body: some View {
        NavigationSplitView {
            typeSidebar
        } content: {
            groupPanel
        } detail: {
            detailPanel
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
            if selectedType == nil { selectedType = typeRows.first?.type }
        }
        .onChange(of: selectedType) { _, _ in
            searchText = ""
            selectedGroupID = nil
            selectedComponent = nil
            syncSelection()
        }
        .onChange(of: searchText) { _, _ in
            syncSelection()
        }
        .onChange(of: components.count) { _, _ in
            syncSelection()
        }
        .sheet(isPresented: $showSupplierLookup) {
            NavigationStack {
                CatalogLookupView()
            }
        }
        .sheet(isPresented: $showDigiKeyExplorer) {
            NavigationStack {
                DigiKeyExplorerView()
            }
        }
    }

    private var typeSidebar: some View {
        List(typeRows, selection: $selectedType) { row in
            HStack(spacing: 10) {
                Image(systemName: row.type.icon)
                    .foregroundStyle(row.type.tint)
                    .frame(width: 20)
                Text(row.type.label)
                Spacer()
                Text("\(row.count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(row.type.tint.opacity(0.12))
                    .clipShape(Capsule())
            }
            .tag(row.type)
        }
        .listStyle(.sidebar)
        .navigationTitle("Catalogo")
        .navigationSplitViewColumnWidth(
            min: AppLayout.catalogTypeMin,
            ideal: AppLayout.catalogTypeIdeal,
            max: 220
        )
    }

    @ViewBuilder
    private var groupPanel: some View {
        if let selectedType {
            VStack(spacing: 0) {
                catalogHeader(for: selectedType)

                Table(filteredGroups, selection: $selectedGroupID) {
                    TableColumn("Valore") { group in
                        Text(group.value)
                            .font(.body.monospacedDigit().weight(.medium))
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Footprint") { group in
                        Text(group.footprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 120)

                    TableColumn("Qty") { group in
                        Text("\(group.totalQuantity)")
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(group.totalQuantity > 0 ? .primary : .tertiary)
                    }
                    .width(48)

                    TableColumn("MPN") { group in
                        Text(group.primaryMPN)
                            .lineLimit(1)
                            .help(group.components.map(\.mpn).joined(separator: ", "))
                    }

                    TableColumn("Var.") { group in
                        if group.componentCount > 1 {
                            Text("\(group.componentCount)×")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: selectedGroupID) { _, newID in
                    guard let newID,
                          let group = filteredGroups.first(where: { $0.id == newID }) else { return }
                    if selectedComponent == nil
                        || !group.components.contains(where: { $0.lcscCode == selectedComponent?.lcscCode }) {
                        selectedComponent = group.components.first
                    }
                }

                if let group = activeGroup, group.componentCount > 1 {
                    variantBar(for: group)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(
                min: AppLayout.catalogGroupMin,
                ideal: AppLayout.catalogGroupIdeal,
                max: 520
            )
            .onAppear { syncSelection() }
        } else {
            ContentUnavailableView("Nessun tipo", systemImage: "square.grid.2x2")
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let selectedComponent {
            ComponentDetailView(component: selectedComponent, store: store)
        } else {
            ContentUnavailableView(
                "Valore | Footprint",
                systemImage: "list.bullet.rectangle",
                description: Text("Seleziona un gruppo per vedere le varianti MPN.")
            )
        }
    }

    private func catalogHeader(for type: ComponentType) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: type.icon)
                    .font(.title2)
                    .foregroundStyle(type.tint)
                    .frame(width: 36, height: 36)
                    .background(type.tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.label)
                        .font(.headline)
                    Text("\(filteredGroups.count) gruppi · \(index.typeCounts[type, default: 0]) componenti")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showSupplierLookup = true
                } label: {
                    Label("Progettazione", systemImage: "magnifyingglass.circle")
                }
                .help("Cerca nei cataloghi LCSC e DigiKey per tipo, valore e footprint")

                Button {
                    showDigiKeyExplorer = true
                } label: {
                    Label("Esplora DigiKey", systemImage: "shippingbox")
                }
                .help("Ricerca keyword, barcode, sostituti e packaging alternativo DigiKey")

                TextField("Cerca valore, footprint, MPN…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 260)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func variantBar(for group: CatalogGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Varianti MPN")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.components, id: \.lcscCode) { component in
                        Button {
                            selectedComponent = component
                        } label: {
                            VariantChip(
                                component: component,
                                isSelected: selectedComponent?.lcscCode == component.lcscCode
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(.bar)
    }

    private func syncSelection() {
        guard let selectedType else { return }
        let available = index.groupsByType[selectedType] ?? []
        let visible = searchText.isEmpty
            ? available
            : available.filter { group in
                let q = searchText
                return group.value.localizedCaseInsensitiveContains(q)
                    || group.footprint.localizedCaseInsensitiveContains(q)
                    || group.components.contains {
                        $0.mpn.localizedCaseInsensitiveContains(q)
                            || $0.lcscCode.localizedCaseInsensitiveContains(q)
                    }
            }

        if selectedGroupID == nil || !visible.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = visible.first?.id
        }
        if let group = visible.first(where: { $0.id == selectedGroupID }) {
            if selectedComponent == nil
                || !group.components.contains(where: { $0.lcscCode == selectedComponent?.lcscCode }) {
                selectedComponent = group.components.first
            }
        } else {
            selectedComponent = nil
        }
    }
}

struct VariantChip: View {
    let component: Component
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(component.mpn.isEmpty ? component.lcscCode : component.mpn)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(component.lcscCode)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if !component.displayCommonName.isEmpty {
                Text(component.displayCommonName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text("qty \(component.quantity)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
