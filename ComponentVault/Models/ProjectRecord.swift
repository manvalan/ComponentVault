import Foundation

struct ProjectItemRecord: Codable, Hashable, Sendable {
    var designator: String
    var lcscCode: String
    var requiredQuantity: Int
    var notes: String
}

struct ProjectRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var description: String
    var updatedAt: String?
    var items: [ProjectItemRecord]
}

extension Project {
    func toRecord() -> ProjectRecord {
        ProjectRecord(
            name: name,
            description: projectDescription,
            updatedAt: ISO8601DateFormatter().string(from: updatedAt),
            items: items.map {
                ProjectItemRecord(
                    designator: $0.designator,
                    lcscCode: $0.component?.lcscCode ?? "",
                    requiredQuantity: $0.requiredQuantity,
                    notes: $0.notes
                )
            }
        )
    }
}
