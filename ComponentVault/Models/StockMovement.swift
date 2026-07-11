import Foundation
import SwiftData

enum StockMovementReason: String, Codable, CaseIterable {
    case manual
    case project
    case importAction = "import"
    case correction

    var label: String {
        switch self {
        case .manual: "Manuale"
        case .project: "Progetto"
        case .importAction: "Import"
        case .correction: "Correzione"
        }
    }
}

@Model
final class StockMovement {
    var date: Date
    var delta: Int
    var quantityAfter: Int
    var reason: String
    var note: String
    var component: Component?

    init(
        delta: Int,
        quantityAfter: Int,
        reason: StockMovementReason = .manual,
        note: String = "",
        component: Component? = nil
    ) {
        self.date = Date()
        self.delta = delta
        self.quantityAfter = quantityAfter
        self.reason = reason.rawValue
        self.note = note
        self.component = component
    }

    var movementReason: StockMovementReason {
        StockMovementReason(rawValue: reason) ?? .manual
    }
}
