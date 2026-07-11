import Foundation
import SwiftData

@Model
final class Project {
    var name: String
    var projectDescription: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ProjectItem.project)
    var items: [ProjectItem]

    init(name: String, projectDescription: String = "", items: [ProjectItem] = []) {
        self.name = name
        self.projectDescription = projectDescription
        self.createdAt = Date()
        self.updatedAt = Date()
        self.items = items
    }

    var totalItems: Int { items.count }

    var missingCount: Int {
        items.filter { !$0.isAvailable }.count
    }

    var lowStockCount: Int {
        items.filter { $0.isLowStock }.count
    }
}

@Model
final class ProjectItem {
    var designator: String
    var requiredQuantity: Int
    var notes: String
    var project: Project?
    var component: Component?

    init(
        designator: String = "",
        requiredQuantity: Int = 1,
        notes: String = "",
        component: Component? = nil
    ) {
        self.designator = designator
        self.requiredQuantity = requiredQuantity
        self.notes = notes
        self.component = component
    }

    var availableQuantity: Int { component?.quantity ?? 0 }

    var isAvailable: Bool {
        guard let component else { return false }
        return component.quantity >= requiredQuantity
    }

    var isLowStock: Bool {
        guard let component else { return true }
        return component.quantity > 0 && component.quantity < requiredQuantity
    }

    var shortage: Int {
        max(0, requiredQuantity - availableQuantity)
    }
}
