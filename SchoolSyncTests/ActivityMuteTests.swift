import XCTest
import SwiftData

/// What a parent hides, and — far more importantly — what they don't.
///
/// The risk here runs opposite to the rest of the app. Everywhere else the
/// danger is an event that fails to appear. Here the parent is deliberately
/// making events disappear, so the danger is that the app takes that
/// instruction wider than they meant it and silences something they were
/// relying on. Exact matching is the guard, and these say so.
final class ActivityMuteTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let jonah = UUID()
    private let teddy = UUID()

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: MutedActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func mute(_ title: String, for kidID: UUID) -> MutedActivity {
        let record = MutedActivity(kidID: kidID, title: title)
        context.insert(record)
        return record
    }

    // MARK: - What it hides

    func testTheMutedActivityIsHiddenForThatKid() {
        let mutes = [mute("Cross Country Practice", for: jonah)]
        XCTAssertTrue(ActivityMute.isMuted(title: "Cross Country Practice", kidID: jonah, in: mutes))
    }

    /// Every session of a season is a separate stored row with the same title,
    /// which is the whole reason this exists rather than a delete.
    func testEverySessionOfTheSeasonMatches() {
        let mutes = [mute("Cross Country Practice", for: jonah)]

        for title in ["Cross Country Practice", "cross country practice", "Cross-Country Practice"] {
            XCTAssertTrue(
                ActivityMute.isMuted(title: title, kidID: jonah, in: mutes),
                "\(title) is the same activity written differently"
            )
        }
    }

    // MARK: - What it must not hide

    /// The reason matching is exact instead of fuzzy. A meet is a race a parent
    /// may well be driving to; silencing practice must not silence it.
    func testASimilarActivityIsNotHidden() {
        let mutes = [mute("Cross Country Practice", for: jonah)]

        for title in [
            "Cross Country Meet",
            "Cross Country Practice Cancelled",
            "Cross Country Banquet",
            "Country Fair",
        ] {
            XCTAssertFalse(
                ActivityMute.isMuted(title: title, kidID: jonah, in: mutes),
                "\(title) is a different thing and must still appear"
            )
        }
    }

    /// One kid's decision is not the other's. Both attend the same school and
    /// see many of the same events.
    func testMutingForOneKidLeavesTheOtherAlone() {
        let mutes = [mute("Cross Country Practice", for: jonah)]

        XCTAssertTrue(ActivityMute.isMuted(title: "Cross Country Practice", kidID: jonah, in: mutes))
        XCTAssertFalse(
            ActivityMute.isMuted(title: "Cross Country Practice", kidID: teddy, in: mutes),
            "Teddy never opted out of this"
        )
    }

    func testNothingIsHiddenWhenNothingIsMuted() {
        XCTAssertFalse(ActivityMute.isMuted(title: "Cross Country Practice", kidID: jonah, in: []))
    }

    // MARK: - Identity

    /// Swiping the same activity twice must be one row, not a uniqueness crash.
    func testTheSameActivityFoldsToOneIdentity() {
        XCTAssertEqual(
            MutedActivity.identity(kidID: jonah, title: "Cross Country Practice"),
            MutedActivity.identity(kidID: jonah, title: "cross-country  practice")
        )
    }

    func testDifferentKidsGetDifferentIdentities() {
        XCTAssertNotEqual(
            MutedActivity.identity(kidID: jonah, title: "Cross Country Practice"),
            MutedActivity.identity(kidID: teddy, title: "Cross Country Practice")
        )
    }

    func testTheDisplayTitleKeepsItsOriginalWording() {
        let record = mute("Cross Country Practice", for: jonah)
        XCTAssertEqual(record.title, "Cross Country Practice", "the undo list has to be readable")
        XCTAssertEqual(record.matchKey, "cross country practice")
    }
}
