import XCTest
@testable import SchoolSync

/// What is allowed to switch off a school morning.
///
/// The asymmetry here is the whole point. Failing to spot a closure costs a
/// parent a moment's confusion — the day off is still printed in alert weight
/// right above the fields. Spotting one that isn't there blanks breakfast,
/// lunch and uniform on a day the school is open, and a parent reading that at
/// 7am keeps a child home. Every case below is written in that direction.
final class ClosureCollapseTests: XCTestCase {

    // MARK: - Days school really is shut

    func testNamedPeriodsAreClosures() {
        for title in [
            "Easter Break",
            "Spring Break",
            "Spring Vacation — Schools Closed",
            "Winter Recess",
            "Thanksgiving Break",
            "Christmas Vacation",
            "February Break",
            "Mid Winter Break",
            "School Holiday",
            "Holiday Break",
        ] {
            XCTAssertTrue(ClosureCollapse.isClosure(title), "\(title) should read as a day off")
        }
    }

    func testExplicitPhrasesAreClosures() {
        for title in [
            "No School - Columbus Day",
            "No School",
            "Schools Closed",
            "School Closed - Snow Day",
            "No Classes Today",
            "Indigenous Peoples' Day — No School",
        ] {
            XCTAssertTrue(ClosureCollapse.isClosure(title), "\(title) should read as a day off")
        }
    }

    // MARK: - Days school is open

    /// The case a substring rule gets wrong, and the reason matching is done on
    /// whole words.
    ///
    /// "breakfast" contains "break". A rule that searched for the substring
    /// would fire on this title, on "Holiday Breakfast", and — fatally — on
    /// "School Breakfast", which is a stored baseline this app prints on one
    /// kid's panel every single morning. That rule doesn't blank a school day
    /// occasionally; it blanks one every day of the year.
    func testBreakfastIsNotABreak() {
        for title in [
            "Christmas Breakfast with Santa",
            "Holiday Breakfast",
            "Easter Breakfast",
            "Spring Breakfast",
            "Breakfast with Santa",
            "School Breakfast",
            "Breakfast at home",
        ] {
            XCTAssertFalse(ClosureCollapse.isClosure(title), "\(title) must not blank a school day")
        }
    }

    /// An announcement about a break happens on a school day.
    func testAnnouncementsAboutAPeriodAreNotClosures() {
        for title in [
            "Spring Break Camp Registration",
            "Spring Break Camp",
            "Easter Break homework packet",
            "Spring Vacation Camp signup",
            "Spring Break packet due",
            "Winter Break Concert",
        ] {
            XCTAssertFalse(ClosureCollapse.isClosure(title), "\(title) must not blank a school day")
        }
    }

    /// A period noun needs a qualifier in front of it to name a period.
    func testUnqualifiedPeriodWordsAreNotClosures() {
        for title in ["Brain Break", "Break", "Holiday Concert", "Holiday Party", "Easter Egg Hunt"] {
            XCTAssertFalse(ClosureCollapse.isClosure(title), "\(title) must not blank a school day")
        }
    }

    /// The original follower guard: a phrase can appear inside something that
    /// means the opposite.
    func testHalfDayMentioningBusesIsNotAClosure() {
        XCTAssertFalse(ClosureCollapse.isClosure("Half day - no school buses"))
        XCTAssertFalse(ClosureCollapse.isClosure("No school lunch served today"))
    }

    // MARK: - Saying it once

    func testTwoClosuresCollapseToOneLine() {
        let items = [
            MorningItem(text: "No School - System Wide PD", isNotable: true),
            MorningItem(text: "No School - Professional Development", isNotable: true),
        ]
        let collapsed = ClosureCollapse.collapse(items)

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed.first?.text, "No school")
        XCTAssertNotNil(collapsed.first?.detail, "the reasons must survive as a sub-line")
    }

    /// A lone closure already reads correctly. Rewriting it would be churn in
    /// the one place this app is trusted.
    func testASingleClosureIsLeftAlone() {
        let items = [MorningItem(text: "No School - Columbus Day", isNotable: true)]
        XCTAssertEqual(ClosureCollapse.collapse(items), items)
    }

    func testCollapseKeepsNonClosureLines() {
        let items = [
            MorningItem(text: "No School - PD Day", isNotable: true),
            MorningItem(text: "No Classes", isNotable: true),
            MorningItem(text: "Soccer practice", isNotable: true),
        ]
        let collapsed = ClosureCollapse.collapse(items)

        XCTAssertTrue(collapsed.contains { $0.text == "Soccer practice" })
    }

    func testContainsClosureDrivesFieldSuppression() {
        XCTAssertTrue(ClosureCollapse.containsClosure([MorningItem(text: "Easter Break", isNotable: true)]))
        XCTAssertFalse(
            ClosureCollapse.containsClosure([MorningItem(text: "Christmas Breakfast with Santa", isNotable: true)])
        )
    }

    /// Detection reads `matchText`, not the displayed string, so a timed
    /// event's "3:30 PM · " prefix can't confuse it.
    func testMatchTextIsWhatGetsMatched() {
        let item = MorningItem(text: "3:30 PM · Easter Break", isNotable: true, matchText: "Easter Break")
        XCTAssertTrue(ClosureCollapse.containsClosure([item]))
    }
}
