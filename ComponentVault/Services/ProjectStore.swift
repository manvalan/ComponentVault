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

    func pushToRemote(config: RemoteAPIConfig) async throws -> Int {
        guard await RemoteAPIClient.projectsAPIAvailable(config: config) else {
            statusMessage = "Server senza API progetti (serve deploy v0.4)"
            return 0
        }

        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
        let projects = try modelContext.fetch(descriptor)
        let records = projects.map { $0.toRecord() }
        let upserted = try await RemoteAPIClient.pushProjects(records, config: config)
        statusMessage = "Caricati \(upserted) progetti sul server"
        return upserted
    }

    func pullFromRemote(config: RemoteAPIConfig, components: [Component]) async throws -> Int {
        guard await RemoteAPIClient.projectsAPIAvailable(config: config) else {
            statusMessage = "Server senza API progetti (serve deploy v0.4)"
            return 0
        }

        let records = try await RemoteAPIClient.fetchProjects(config: config)
        try upsert(records: records, components: components)
        statusMessage = "Scaricati \(records.count) progetti dal server"
        return records.count
    }

    func syncBidirectional(config: RemoteAPIConfig, components: [Component]) async throws -> SyncBidirectionalResult {
        guard await RemoteAPIClient.projectsAPIAvailable(config: config) else {
            let result = SyncBidirectionalResult(pushed: 0, pulled: 0, unchanged: 0)
            statusMessage = "Progetti: server v0.3 (solo componenti sincronizzati)"
            return result
        }

        let remoteRecords = try await RemoteAPIClient.fetchProjects(config: config)
        let remoteByName = Dictionary(uniqueKeysWithValues: remoteRecords.map { ($0.name, $0) })

        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
        let localProjects = try modelContext.fetch(descriptor)
        let localByName = Dictionary(uniqueKeysWithValues: localProjects.map { ($0.name, $0) })
        let componentsByCode = Dictionary(uniqueKeysWithValues: components.map { ($0.lcscCode.uppercased(), $0) })

        var toPush: [ProjectRecord] = []
        var pulled = 0
        var unchanged = 0

        for (name, local) in localByName {
            let localRecord = local.toRecord()
            if let remote = remoteByName[name] {
                let localDate = local.updatedAt
                let remoteDate = SyncDateParser.parse(remote.updatedAt)
                if localDate > remoteDate.addingTimeInterval(1) {
                    toPush.append(localRecord)
                } else if remoteDate > localDate.addingTimeInterval(1) {
                    try applyRecord(remote, to: local, componentsByCode: componentsByCode)
                    pulled += 1
                } else {
                    unchanged += 1
                }
            } else {
                toPush.append(localRecord)
            }
        }

        for (name, remote) in remoteByName where localByName[name] == nil {
            let project = Project(name: name, projectDescription: remote.description)
            modelContext.insert(project)
            try applyRecord(remote, to: project, componentsByCode: componentsByCode)
            pulled += 1
        }

        let pushed = toPush.isEmpty ? 0 : try await RemoteAPIClient.pushProjects(toPush, config: config)
        try modelContext.save()

        let result = SyncBidirectionalResult(pushed: pushed, pulled: pulled, unchanged: unchanged)
        statusMessage = result.summary
        return result
    }

    private func upsert(records: [ProjectRecord], components: [Component]) throws {
        let componentsByCode = Dictionary(uniqueKeysWithValues: components.map { ($0.lcscCode.uppercased(), $0) })
        for record in records {
            let descriptor = FetchDescriptor<Project>(
                predicate: #Predicate { $0.name == record.name }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                try applyRecord(record, to: existing, componentsByCode: componentsByCode)
            } else {
                let project = Project(name: record.name, projectDescription: record.description)
                modelContext.insert(project)
                try applyRecord(record, to: project, componentsByCode: componentsByCode)
            }
        }
        try modelContext.save()
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
