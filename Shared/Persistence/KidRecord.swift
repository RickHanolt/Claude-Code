import Foundation
import SwiftData

@Model
final class KidRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Hex color (e.g. "#4A90D9") used for the kid's calendar and UI accents.
    var colorHex: String

    init(id: UUID = UUID(), name: String, colorHex: String = "#4A90D9") {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}
