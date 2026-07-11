import Foundation

struct ComponentFilter {
    var searchText = ""
    var category = "Tutte"
    var footprint = "Tutti"
    var brand = "Tutti"
    var tag = "Tutti"
    var showLowStockOnly = false
    var showOutOfStockOnly = false
    var requireDigiKeyData = false
    var digikeyOutOfStockOnly = false

    func apply(to components: [Component]) -> [Component] {
        components.filter { component in
            matchesSearch(component) &&
            matchesCategory(component) &&
            matchesFootprint(component) &&
            matchesBrand(component) &&
            matchesTag(component) &&
            matchesStock(component) &&
            matchesDigiKey(component)
        }
    }

    static func categories(from components: [Component]) -> [String] {
        let roots = Set(components.map(\.categoryRoot).filter { !$0.isEmpty })
        return ["Tutte"] + roots.sorted()
    }

    static func footprints(from components: [Component]) -> [String] {
        let values = Set(components.map(\.footprint).filter { !$0.isEmpty })
        return ["Tutti"] + values.sorted()
    }

    static func brands(from components: [Component]) -> [String] {
        let values = Set(components.map(\.brand).filter { !$0.isEmpty })
        return ["Tutti"] + values.sorted()
    }

    static func tags(from components: [Component]) -> [String] {
        let values = Set(components.flatMap(\.tags).filter { !$0.isEmpty })
        return ["Tutti"] + values.sorted()
    }

    private func matchesSearch(_ component: Component) -> Bool {
        guard !searchText.isEmpty else { return true }
        let query = searchText.lowercased()
        let fields = [
            component.lcscCode,
            component.mpn,
            component.name,
            component.componentDescription,
            component.footprint,
            component.value,
            component.brand,
            component.category,
            component.notes
        ] + component.tags + component.parameters.map { "\($0.name) \($0.value)" }

        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func matchesCategory(_ component: Component) -> Bool {
        category == "Tutte" || component.categoryRoot == category
    }

    private func matchesFootprint(_ component: Component) -> Bool {
        footprint == "Tutti" || component.footprint == footprint
    }

    private func matchesBrand(_ component: Component) -> Bool {
        brand == "Tutti" || component.brand == brand
    }

    private func matchesTag(_ component: Component) -> Bool {
        tag == "Tutti" || component.tags.contains(tag)
    }

    private func matchesStock(_ component: Component) -> Bool {
        if showOutOfStockOnly { return component.quantity == 0 }
        if showLowStockOnly { return component.isLowStock }
        return true
    }

    private func matchesDigiKey(_ component: Component) -> Bool {
        component.migrateLegacySnapshotsIfNeeded()
        if requireDigiKeyData && !component.hasDigiKeySnapshot { return false }
        if digikeyOutOfStockOnly {
            guard let stock = component.digikeySnapshot?.supplierStock else { return false }
            return stock == 0
        }
        return true
    }
}
