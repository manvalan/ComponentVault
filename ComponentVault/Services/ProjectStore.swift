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
        statusMessage = String(localized: "Progetto eliminato")
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
                    note: String(localized: "Riservato per \(project.name) (\(item.designator))")
                )
                reserved += 1
            }
        }
        statusMessage = String(localized: "Riservati componenti per \(project.name) (\(reserved) righe)")
    }

    func importBOM(
        from url: URL,
        into project: Project,
        components: [Component],
        replaceExisting: Bool = false
    ) throws -> BOMImportResult {
        if replaceExisting {
            try clearProjectItems(project)
        }
        return try importBOMLines(into: project, lines: try BOMImporter.parse(from: url), components: components)
    }

    /// Import BOM EasyEDA: crea un progetto nuovo o aggiorna uno esistente con lo stesso nome.
    func importBOMCreatingProject(
        from url: URL,
        projectName: String,
        components: [Component],
        replaceExisting: Bool = true
    ) throws -> (project: Project, result: BOMImportResult) {
        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BOMImportError.emptyProjectName
        }

        let project = try findProject(named: trimmedName) ?? createProject(name: trimmedName)
        let result = try importBOM(from: url, into: project, components: components, replaceExisting: replaceExisting)
        return (project, result)
    }

    func findProject(named name: String) throws -> Project? {
        let descriptor = FetchDescriptor<Project>()
        let projects = try modelContext.fetch(descriptor)
        return projects.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    func clearProjectItems(_ project: Project) throws {
        for item in project.items {
            modelContext.delete(item)
        }
        project.items.removeAll()
        project.updatedAt = Date()
        try modelContext.save()
    }

    private func importBOMLines(
        into project: Project,
        lines: [BOMImportLine],
        components: [Component]
    ) throws -> BOMImportResult {
        var imported = 0
        var skipped = 0
        var missingLCSC: [String] = []

        let byLCSC = Dictionary(uniqueKeysWithValues: components.map { ($0.lcscCode.uppercased(), $0) })
        let bySupplierLCSC = Dictionary(uniqueKeysWithValues: components.compactMap { component -> (String, Component)? in
            guard let code = component.supplierLCSCCode else { return nil }
            return (code.uppercased(), component)
        })
        let byMPN = Dictionary(grouping: components.filter { !$0.mpn.isEmpty }, by: { $0.mpn.uppercased() })

        for line in lines {
            let code = line.lcscCode.uppercased()
            let component = byLCSC[code]
                ?? bySupplierLCSC[code]
                ?? (line.mpn.isEmpty ? nil : byMPN[line.mpn.uppercased()]?.first)

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
        statusMessage = String(localized: "BOM importata: \(imported) righe") +
            (skipped > 0 ? String(localized: ", \(skipped) non trovate in inventario") : "")

        return BOMImportResult(
            imported: imported,
            skipped: skipped,
            missingLCSC: missingUnique,
            lines: lines
        )
    }

    func allRecords() throws -> [ProjectRecord] {
        try modelContext.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)]))
            .map { $0.toRecord() }
    }

    /// Fonde i progetti di un altro dispositivo: per nome, vince la modifica più recente.
    func merge(remote remoteRecords: [ProjectRecord], components: [Component]) throws -> SyncBidirectionalResult {
        var remoteByName: [String: ProjectRecord] = [:]
        for record in remoteRecords { remoteByName[record.name] = record }

        let localProjects = try modelContext.fetch(FetchDescriptor<Project>())
        var localByName: [String: Project] = [:]
        for project in localProjects { localByName[project.name] = project }
        var componentsByCode: [String: Component] = [:]
        for component in components { componentsByCode[component.lcscCode.uppercased()] = component }

        var pushed = 0
        var pulled = 0
        var unchanged = 0

        for (name, local) in localByName {
            if let remote = remoteByName[name] {
                let localDate = local.updatedAt
                let remoteDate = SyncDateParser.parse(remote.updatedAt)
                if localDate > remoteDate.addingTimeInterval(1) {
                    pushed += 1
                } else if remoteDate > localDate.addingTimeInterval(1) {
                    try applyRecord(remote, to: local, componentsByCode: componentsByCode)
                    pulled += 1
                } else {
                    unchanged += 1
                }
            } else {
                pushed += 1
            }
        }

        for (name, remote) in remoteByName where localByName[name] == nil {
            let project = Project(name: name, projectDescription: remote.description)
            modelContext.insert(project)
            try applyRecord(remote, to: project, componentsByCode: componentsByCode)
            pulled += 1
        }

        try modelContext.save()

        let result = SyncBidirectionalResult(pushed: pushed, pulled: pulled, unchanged: unchanged)
        statusMessage = result.summary
        return result
    }

    private func applyRecord(
        _ record: ProjectRecord,
        to project: Project,
        componentsByCode: [String: Component]
    ) throws {
        project.projectDescription = record.description
        if let updatedAt = record.updatedAt {
            project.updatedAt = SyncDateParser.parse(updatedAt)
        }

        for item in project.items {
            modelContext.delete(item)
        }
        project.items.removeAll()

        for itemRecord in record.items {
            let item = ProjectItem(
                designator: itemRecord.designator,
                requiredQuantity: itemRecord.requiredQuantity,
                notes: itemRecord.notes,
                component: componentsByCode[itemRecord.lcscCode.uppercased()]
            )
            item.project = project
            project.items.append(item)
            modelContext.insert(item)
        }
    }
}

enum BOMImportError: LocalizedError {
    case emptyProjectName

    var errorDescription: String? {
        switch self {
        case .emptyProjectName: String(localized: "Il nome del progetto non può essere vuoto.")
        }
    }
}
