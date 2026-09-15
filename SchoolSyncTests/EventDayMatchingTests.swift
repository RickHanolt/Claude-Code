import XCTest
@testable import SchoolSync

/// Whether a break that spans days shows up on all of them.
///
/// Fixed calendar and time zone throughout: a rule about which day something
/// lands on must not depend on where the machine running it happens to be, and
/// a CI runner is somewhere else by default.
final class EventDayMatchingTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    private func occurs(_ target: Date, from start: Date, to end: Date?) -> Bool {
        EventDayMatching.occurs(on: target, start: start, end: end, calendar: calendar)
    }

    /// Teddy's, exactly as stored: Monday through Friday.
    func testSpringVacationShowsOnEveryDayOfTheWeek() {
        let start = day(2027, 3, 22)
        let end = day(2027, 3, 26)

        for dayOfMonth in 22...26 {
            XCTAssertTrue(
                occurs(day(2027, 3, dayOfMonth), from: start, to: end),
                "March \(dayOfMonth) is inside the break and must show the closure"
            )
        }
    }

    /// Jonah's, which crosses a month boundary.
    func testEasterBreakSpansIntoApril() {
        let start = day(2027, 3, 25)
        let end = day(2027, 4, 2)

        for target in [day(2027, 3, 25), day(2027, 3, 31), day(2027, 4, 1), day(2027, 4, 2)] {
            XCTAssertTrue(occurs(target, from: start, to: end))
        }
    }

    func testDaysOutsideTheRangeAreExcluded() {
        let start = day(2027, 3, 22)
        let end = day(2027, 3, 26)

        XCTAssertFalse(occurs(day(2027, 3, 21), from: start, to: end), "the day before is not the break")
        XCTAssertFalse(occurs(day(2027, 3, 27), from: start, to: end), "the day after is not the break")
    }

    /// Both ends belong to the event. A break listed as ending Friday includes
    /// Friday — that is how the school wrote it and how the edit screen shows it.
    func testBothBoundariesAreInclusive() {
        let start = day(2027, 3, 22)
        let end = day(2027, 3, 26)

        XCTAssertTrue(occurs(start, from: start, to: end))
        XCTAssertTrue(occurs(end, from: start, to: end))
    }

    func testAnEventWithNoEndIsASingleDay() {
        let start = day(2026, 10, 9)

        XCTAssertTrue(occurs(start, from: start, to: nil))
        XCTAssertFalse(occurs(day(2026, 10, 10), from: start, to: nil))
    }

    /// A timed event starts and ends within one day and must not leak into the
    /// next one.
    func testATimedEventStaysOnItsOwnDay() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15, minute: 30))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 16, minute: 30))!

        XCTAssertTrue(occurs(day(2026, 10, 21), from: start, to: end))
        XCTAssertFalse(occurs(day(2026, 10, 22), from: start, to: end))
    }

    /// Bad data must degrade to one visible day rather than to none. Hiding a
    /// row from every day at once is the failure nobody would notice.
    func testAnEndBeforeItsStartFallsBackToTheStartDay() {
        let start = day(2027, 3, 22)
        let end = day(2027, 3, 20)

        XCTAssertTrue(occurs(start, from: start, to: end))
        XCTAssertFalse(occurs(day(2027, 3, 21), from: start, to: end))
    }

    /// The rule this replaced, stated as a test so it can't come back: matching
    /// the start date alone.
    func testTheOldStartDateOnlyRuleWouldFailThis() {
        let start = day(2027, 3, 22)
        let end = day(2027, 3, 26)
        let wednesday = day(2027, 3, 24)

        XCTAssertNotEqual(
            calendar.startOfDay(for: start), calendar.startOfDay(for: wednesday),
            "precondition: the Wednesday is not the start date"
        )
        XCTAssertTrue(occurs(wednesday, from: start, to: end), "and it still has to show the break")
    }
}
