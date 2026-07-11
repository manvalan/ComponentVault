import Foundation
import SwiftData

@MainActor
@Observable
final class ProjectStore {
    private let modelContext: ModelContext
    var statusMessage: String?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func createProject(name: String, description: String = "") throws -> Project {
        let project = Project(name: name, projectDescription: description)
        modelContext.insert(project)
        try modelContext.save()
        statusMessage = "Progetto \"\(name)\" creato"
        return project
    }

    func deleteProject(_ project: Project) throws {
        modelContext.delete(project)
        try modelContext.save()
        statusMessage = "Progetto eliminato"
    }

    func addComponent(
        _ component: Component,
        to project: Project,
        quantity: Int = 1,
        designator: String = "",
        notes: String = ""
    ) throws {
        if let existing = project.items.first(where: { $0.component?.lcscCode == component.lcscCode }) {
            existing.requiredQuantity += quantity
            if !designator.isEmpty && !existing.designator.contains(designator) {
                existing.designator = [existing.designator, designator]
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            }
            if !notes.isEmpty && existing.notes.isEmpty {
                existing.notes = notes
            }
        } else {
            let item = ProjectItem(
                designator: designator,
                requiredQuantity: quantity,
                notes: notes,
                component: component
            )
            item.project = project
            project.items.append(item)
            modelContext.insert(item)
        }
        project.updatedAt = Date()
        try modelContext.save()
        statusMessage = "\(component.lcscCode) aggiunto a \(project.name)"
    }

    func removeItem(_ item: ProjectItem, from project: Project) throws {
        project.items.removeAll { $0.persistentModelID == item.persistentModelID }
        modelContext.delete(item)
        project.updatedAt = Date()
        try modelContext.save()
    }

    func reserveForProject(_ project: Project, store: ComponentStore) throws {
        var reserved = 0
        for item in project.items {
            guard let component = item.component else { continue }
            let toDeduct = min(component.quantity, item.requiredQuantity)
            if toDeduct > 0 {
                try store.adjustStock(
                    component,
                    delta: -toDeduct,
                    reason: .project,
                    note: "Riservato per \(project.name) (\(item.designator))"
                )
                reserved += 1
            }
        }
        statusMessage = "Riservati componenti per \(project.name) (\(reserved) righe)"
    }

    func importBOM(from url: URL, into project: Project, components: [Component]) throws -> BOMImportResult {
        let lines = try BOMImporter.parse(from: url)
        var imported = 0
        var skipped = 0
        var missingLCSC: [String] = []

        let byLCSC = Dictionary(uniqueKeysWithValues: components.map { ($0.lcscCode.uppercased(), $0) })
        let byMPN = Dictionary(grouping: components.filter { !$0.mpn.isEmpty }, by: { $0.mpn.uppercased() })

        for line in lines {
            let code = line.lcscCode.uppercased()
            let component = byLCSC[code] ?? (
                line.mpn.isEmpty ? nil : byMPN[line.mpn.uppercased()]?.first
            )

            guard let component else {
                missingLCSC.append(line.lcscCode)
                skipped += 1
                continue
            }

            try addComponent(
                component,
                to: project,
                quantity: line.quantity,
                designator: line.designator,
                notes: line.notes
            )

            imported += 1
        }

        project.updatedAt = Date()
        try modelContext.save()

        let missingUnique = Array(Set(missingLCSC)).sorted()
        statusMessage = "BOM importata: \(imported) righe" +
            (skipped > 0 ? ", \(skipped) non trovate in inventario" : "")

        return BOMImportResult(
            imported: imported,
            skipped: skipped,
            missingLCSC: missingUnique,
            lines: lines
        )
    }
}
