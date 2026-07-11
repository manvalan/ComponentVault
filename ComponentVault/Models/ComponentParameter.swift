import Foundation
import SwiftData

@Model
final class ComponentParameter {
    var name: String
    var value: String
    var component: Component?

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}
