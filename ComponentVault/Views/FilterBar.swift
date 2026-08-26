import SwiftUI

// MARK: - Barra filtri: tab in alto + opzioni sempre visibili sotto

struct TopFilterTab: View {
    let title: String
    let value: String
    let isOpen: Bool
    var isHighlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isHighlighted || isOpen ? Color.accentColor : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isOpen ? Color.accentColor.opacity(0.14) : Color.clear)
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isOpen ? Color.accentColor : (isHighlighted ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.4)),
                        lineWidth: isOpen ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct TopFilterOptionStrip<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    let isSelected: (Option) -> Bool
    let onSelect: (Option) -> Void
    var clearLabel: String? = nil
    var onClear: (() -> Void)? = nil
    var isClearSelected: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                if let clearLabel, let onClear {
                    clearChip(clearLabel, selected: isClearSelected, action: onClear)
                }
                ForEach(options, id: \.self) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        optionLabel(label(option), selected: isSelected(option))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.primary.opacity(0.04))
    }

    private func clearChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            optionLabel(title, selected: selected)
        }
        .buttonStyle(.plain)
    }

    private func optionLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(selected ? .bold : .regular))
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            .background(.background, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        selected ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: selected ? 2 : 1
                    )
            )
    }
}

struct TopFilterPanel<TopRow: View, Options: View>: View {
    @ViewBuilder let topRow: TopRow
    @ViewBuilder let options: Options

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 10) {
                    topRow
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.bar)

            options

            Divider()
        }
    }
}

// MARK: - Inventario

private enum InventoryFilterZone: String, CaseIterable {
    case category, footprint, brand, tag, more
}

struct FilterBar: View {
    @Binding var filter: ComponentFilter
    let components: [Component]

    @State private var activeZone: InventoryFilterZone? = .category
    @State private var categoryOptions: [String] = ["Tutte"]
    @State private var footprintOptions: [String] = ["Tutti"]
    @State private var brandOptions: [String] = ["Tutti"]
    @State private var tagOptions: [String] = ["Tutti"]

    var body: some View {
        TopFilterPanel {
            searchField
            zoneTab(.category, value: filter.category)
            zoneTab(.footprint, value: filter.footprint)
            zoneTab(.brand, value: filter.brand)
            zoneTab(.tag, value: filter.tag)
            zoneTab(.more, value: moreSummary)
            if hasActiveFilters {
                Button("Reset") { resetFilters() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } options: {
            if let activeZone {
                activeOptions(for: activeZone)
            }
        }
        .onAppear { rebuildFilterOptions() }
        .onChange(of: components.count) { _, _ in rebuildFilterOptions() }
        .onChange(of: categoryOptions) { _, options in
            if !options.contains(filter.category) { filter.category = "Tutte" }
        }
    }

    private func zoneTab(_ zone: InventoryFilterZone, value: String) -> some View {
        TopFilterTab(
            title: zoneTitle(zone),
            value: value,
            isOpen: activeZone == zone,
            isHighlighted: isZoneHighlighted(zone, value: value)
        ) {
            withAnimation(.easeInOut(duration: 0.2)) {
                activeZone = zone
            }
        }
    }

    private func isZoneHighlighted(_ zone: InventoryFilterZone, value: String) -> Bool {
        switch zone {
        case .category: value != "Tutte"
        case .footprint: value != "Tutti"
        case .brand: value != "Tutti"
        case .tag: value != "Tutti"
        case .more: moreSummary != "—"
        }
    }

    private func zoneTitle(_ zone: InventoryFilterZone) -> String {
        switch zone {
        case .category: "Categoria"
        case .footprint: "Footprint"
        case .brand: "Brand"
        case .tag: "Tag"
        case .more: "Altro"
        }
    }

    @ViewBuilder
    private func activeOptions(for zone: InventoryFilterZone) -> some View {
        switch zone {
        case .category:
            TopFilterOptionStrip(options: categoryOptions, label: { $0 }, isSelected: { $0 == filter.category }) {
                filter.category = $0
            }
        case .footprint:
            TopFilterOptionStrip(options: footprintOptions, label: { $0 }, isSelected: { $0 == filter.footprint }) {
                filter.footprint = $0
            }
        case .brand:
            TopFilterOptionStrip(options: brandOptions, label: { $0 }, isSelected: { $0 == filter.brand }) {
                filter.brand = $0
            }
        case .tag:
            TopFilterOptionStrip(options: tagOptions, label: { $0 }, isSelected: { $0 == filter.tag }) {
                filter.tag = $0
            }
        case .more:
            moreOptionsStrip
        }
    }

    private var moreOptionsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                toggleChip("Avvisi attivi", isOn: $filter.showLowStockOnly)
                toggleChip("Esauriti", isOn: $filter.showOutOfStockOnly)
                toggleChip("DigiKey", isOn: $filter.requireDigiKeyData)
                toggleChip("DK stock 0", isOn: $filter.digikeyOutOfStockOnly)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.primary.opacity(0.04))
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.subheadline.weight(isOn.wrappedValue ? .bold : .regular))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isOn.wrappedValue ? Color.accentColor.opacity(0.16) : Color.clear
                )
                .background(.background, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isOn.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: isOn.wrappedValue ? 2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var hasActiveFilters: Bool {
        filter.category != "Tutte"
            || filter.footprint != "Tutti"
            || filter.brand != "Tutti"
            || filter.tag != "Tutti"
            || filter.showLowStockOnly
            || filter.showOutOfStockOnly
            || filter.requireDigiKeyData
            || filter.digikeyOutOfStockOnly
            || !filter.searchText.isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Cerca…", text: $filter.searchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 100, maxWidth: 160)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
    }

    private var moreSummary: String {
        var parts: [String] = []
        if filter.showLowStockOnly { parts.append("Avvisi") }
        if filter.showOutOfStockOnly { parts.append("Esauriti") }
        if filter.requireDigiKeyData { parts.append("DigiKey") }
        if filter.digikeyOutOfStockOnly { parts.append("DK=0") }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    private func resetFilters() {
        filter = ComponentFilter()
        activeZone = .category
    }

    private func rebuildFilterOptions() {
        categoryOptions = ComponentFilter.categories(from: components)
        footprintOptions = ComponentFilter.footprints(from: components)
        brandOptions = ComponentFilter.brands(from: components)
        tagOptions = ComponentFilter.tags(from: components)
    }
}

// MARK: - Ricerca LCSC (progettazione)

private enum CatalogSearchZone: String, CaseIterable {
    case type, value, footprint, brand
}

struct CatalogDesignFilterBar: View {
    @Binding var query: CatalogSearchQuery
    let inventory: [Component]
    let isSearching: Bool
    var searchProvider: CatalogSearchProvider = AppConfigIO.current().catalog.searchProvider
    let onSearch: () -> Void

    @State private var activeZone: CatalogSearchZone? = .type

    private var footprintOptions: [String] {
        CatalogFilterOptions.footprints(in: inventory, for: query.resolvedType)
    }

    private var brandOptions: [String] {
        CatalogFilterOptions.brands(
            in: inventory,
            type: query.resolvedType,
            value: query.value,
            footprint: query.footprint
        )
    }

    var body: some View {
        TopFilterPanel {
            zoneTab(.type, value: query.typeSelectionLabel)
            zoneTab(.value, value: query.valueDisplayLabel)
            zoneTab(.footprint, value: query.footprint.isEmpty ? "—" : query.footprint)
            zoneTab(.brand, value: query.brand.isEmpty ? "—" : query.brand)
            searchButton
        } options: {
            if let activeZone {
                activeOptions(for: activeZone)
            }
        }
        .onChange(of: query.type) { _, newType in
            if let newType {
                query.valueUnit = ComponentValueUnit.defaultUnit(for: newType)
            }
            sanitizeSelections()
            persistSelections()
        }
        .onChange(of: query.valueAmount) { _, _ in
            if !canPickBrand { query.brand = "" }
            sanitizeSelections()
            persistSelections()
        }
        .onChange(of: query.valueUnit) { _, _ in
            if !canPickBrand { query.brand = "" }
            sanitizeSelections()
            persistSelections()
        }
        .onChange(of: query.footprint) { _, _ in
            if !canPickBrand { query.brand = "" }
            sanitizeSelections()
            persistSelections()
        }
        .onChange(of: query.brand) { _, _ in
            persistSelections()
        }
    }

    private var canPickBrand: Bool {
        query.hasValueAndFootprint && !brandOptions.isEmpty
    }

    private func zoneTab(_ zone: CatalogSearchZone, value: String) -> some View {
        TopFilterTab(
            title: zoneTitle(zone),
            value: value,
            isOpen: activeZone == zone,
            isHighlighted: isZoneHighlighted(zone, value: value)
        ) {
            withAnimation(.easeInOut(duration: 0.2)) {
                activeZone = zone
            }
        }
    }

    private func isZoneHighlighted(_ zone: CatalogSearchZone, value: String) -> Bool {
        switch zone {
        case .type: query.type != nil
        case .value: query.hasValue
        case .footprint: !query.footprint.isEmpty
        case .brand: !query.brand.isEmpty
        }
    }

    private func zoneTitle(_ zone: CatalogSearchZone) -> String {
        switch zone {
        case .type: "Tipo"
        case .value: "Valore"
        case .footprint: "Footprint"
        case .brand: "Produttore"
        }
    }

    @ViewBuilder
    private func activeOptions(for zone: CatalogSearchZone) -> some View {
        switch zone {
        case .type:
            TopFilterOptionStrip(
                options: Array(ComponentType.allCases),
                label: { $0.label },
                isSelected: { query.type == $0 },
                onSelect: { type in
                    query.type = type
                    query.valueUnit = ComponentValueUnit.defaultUnit(for: type)
                },
                clearLabel: "Tutti",
                onClear: { query.type = nil },
                isClearSelected: query.type == nil
            )
        case .value:
            valueOptionsStrip
        case .footprint:
            if footprintOptions.isEmpty {
                emptyOptionsHint("Nessun footprint in inventario per questo tipo")
            } else {
                TopFilterOptionStrip(
                    options: footprintOptions,
                    label: { $0 },
                    isSelected: { $0 == query.footprint },
                    onSelect: { fp in query.footprint = fp },
                    clearLabel: "Nessuno",
                    onClear: { query.footprint = "" },
                    isClearSelected: query.footprint.isEmpty
                )
            }
        case .brand:
            if !query.hasValueAndFootprint {
                emptyOptionsHint("Imposta valore e footprint")
            } else if brandOptions.isEmpty {
                emptyOptionsHint("Nessun produttore in inventario per questa combinazione")
            } else {
                TopFilterOptionStrip(
                    options: brandOptions,
                    label: { $0 },
                    isSelected: { $0 == query.brand },
                    onSelect: { brand in query.brand = brand },
                    clearLabel: "Nessuno",
                    onClear: { query.brand = "" },
                    isClearSelected: query.brand.isEmpty
                )
            }
        }
    }

    private var valueOptionsStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField(
                    query.resolvedType.usesStructuredValue ? "Quantità (es. 10)" : "MPN o keyword",
                    text: $query.valueAmount
                )
                #if os(iOS)
                .keyboardType(query.resolvedType.usesStructuredValue ? .decimalPad : .default)
                #endif
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)

                if query.hasValue {
                    Button("Azzera") { query.clearValue() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if query.resolvedType.usesStructuredValue {
                TopFilterOptionStrip(
                    options: ComponentValueUnit.units(for: query.resolvedType),
                    label: { $0.shortLabel },
                    isSelected: { $0 == query.valueUnit },
                    onSelect: { query.valueUnit = $0 }
                )
            }
        }
        .padding(.bottom, 4)
        .background(Color.primary.opacity(0.04))
    }

    private func emptyOptionsHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.04))
    }

    private var searchButton: some View {
        Button(action: onSearch) {
            if isSearching {
                ProgressView().controlSize(.small)
            } else {
                Label(searchProvider.searchButtonTitle, systemImage: "magnifyingglass")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSearching)
    }

    private func sanitizeSelections() {
        if !query.footprint.isEmpty, !footprintOptions.contains(query.footprint) {
            query.footprint = ""
        }
        if !query.brand.isEmpty, !brandOptions.contains(query.brand) {
            query.brand = ""
        }
    }

    private func persistSelections() {
        let defaults = UserDefaults.standard
        if let type = query.type {
            defaults.set(type.rawValue, forKey: CatalogSearchDefaults.typeKey)
            defaults.set(false, forKey: CatalogSearchDefaults.typeClearedKey)
        } else {
            defaults.set(true, forKey: CatalogSearchDefaults.typeClearedKey)
        }
        defaults.set(query.valueAmount, forKey: CatalogSearchDefaults.valueAmountKey)
        defaults.set(query.valueUnit.rawValue, forKey: CatalogSearchDefaults.valueUnitKey)
        defaults.set(query.footprint, forKey: CatalogSearchDefaults.footprintKey)
        defaults.set(query.brand, forKey: CatalogSearchDefaults.brandKey)
    }
}

// MARK: - Catalogo (tipo componente)

struct CatalogTypeFilterBar: View {
    @Binding var selectedType: ComponentType?
    let typeRows: [CatalogTypeRow]

    var body: some View {
        TopFilterPanel {
            HStack(spacing: 6) {
                Text("Tipo")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(selectedType?.label ?? "Scegli…")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(selectedType == nil ? .primary : Color.accentColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.14))
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            )

            if let selectedType {
                Text("\(typeRows.first(where: { $0.type == selectedType })?.count ?? 0) in inventario")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } options: {
            TopFilterOptionStrip(
                options: typeRows.map(\.type),
                label: { type in
                    let count = typeRows.first(where: { $0.type == type })?.count ?? 0
                    return "\(type.label) (\(count))"
                },
                isSelected: { $0 == selectedType }
            ) { type in
                selectedType = type
            }
        }
    }
}
