import Foundation
import SwiftData

@Model
final class ForwardedEmailRecord {
    @Attribute(.unique) var externalID: String
    var subject: String
    var bodyText: String
    var sharedDate: Date
    var kidID: UUID
    var schoolID: UUID

    init(dto: ForwardedEmailDTO) {
        self.externalID = dto.id
        self.subject = dto.subject
        self.bodyText = dto.bodyText
        self.sharedDate = dto.sharedDate
        self.kidID = dto.kidID
        self.schoolID = dto.schoolID
    }
}
