import XCTest

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

    private func isFirstDay(_ target: Date, from start: Date) -> Bool {
        EventDayMatching.isFirstDay(on: target, start: start, calendar: calendar)
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

    // MARK: - News on the first day, context afterwards

    /// The regression that came with rendering spans on every day they cover.
    ///
    /// Hispanic Heritage Month runs mid-September to mid-October. Emphasising
    /// every event on every day it spans put that line in alert weight on
    /// thirty consecutive mornings, which spends the one signal the screen has
    /// on something that changed once, a month ago.
    func testALongObservanceIsNewsOnlyOnItsFirstDay() {
        let start = day(2026, 9, 15)

        XCTAssertTrue(isFirstDay(start, from: start), "the day it starts is worth saying loudly")

        for target in [day(2026, 9, 16), day(2026, 9, 17), day(2026, 10, 14)] {
            XCTAssertFalse(isFirstDay(target, from: start), "every later morning is context, not news")
        }
    }

    /// Closures are the exception the caller layers on top, and they have to
    /// stay loud for the whole span — school being shut is acted on every
    /// morning of it, not announced once.
    func testAClosureStaysLoudEveryDayOfItsSpan() {
        let start = day(2027, 3, 22)

        for dayOfMonth in 23...26 {
            let target = day(2027, 3, dayOfMonth)
            XCTAssertFalse(isFirstDay(target, from: start), "precondition: not the first day")
            XCTAssertTrue(
                ClosureCollapse.isClosure("Spring Vacation — Schools Closed"),
                "so the closure check is what has to keep it emphasised"
            )
        }
    }

    func testASingleDayEventIsAlwaysItsOwnFirstDay() {
        let start = day(2026, 10, 21)
        XCTAssertTrue(isFirstDay(start, from: start))
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
