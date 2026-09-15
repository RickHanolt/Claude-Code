import XCTest
import SwiftData

/// What gets emphasised on a morning panel.
///
/// The lunch rule is the interesting one and it came from the user: emphasis
/// tracks whether somebody at home has to act, not whether the day departs from
/// the usual. The usual moves — a kid packs every day until the month somebody
/// orders twenty hot lunches — and a rule anchored to his habit inverts with
/// it, silently, in the direction that sends him to school with nothing.
final class DayPlanResolverTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let kidID = UUID()

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private lazy var theDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))!

    override func setUpWithError() throws {
        // In memory: these models are only ever read back in the same test, and
        // a container on disk would leak state between them.
        container = try ModelContainer(
            for: KidDayDefaults.self, DayException.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func defaults(lunch: String, breakfast: String = "", clothing: String = "") -> KidDayDefaults {
        let record = KidDayDefaults(
            kidID: kidID, breakfast: breakfast, lunch: lunch, clothing: clothing
        )
        context.insert(record)
        return record
    }

    private func exception(
        _ field: DayField,
        _ value: String,
        source: DayExceptionSource = .email,
        isNotable: Bool = true,
        lunchProvided: Bool? = nil
    ) -> DayException {
        let record = DayException(
            kidID: kidID, day: calendar.startOfDay(for: theDay), field: field, value: value,
            source: source, provenance: nil, isNotable: isNotable, lunchProvided: lunchProvided
        )
        context.insert(record)
        return record
    }

    private func resolve(_ exceptions: [DayException], defaults: KidDayDefaults?) -> DayPlan {
        DayPlanResolver.resolve(
            kidID: kidID, day: theDay, defaults: defaults, exceptions: exceptions, calendar: calendar
        )
    }

    // MARK: - Lunch is decided by whether anyone has to act

    func testADayWithNoMealIsAnException() {
        let plan = resolve(
            [exception(.lunch, "Pack a lunch", lunchProvided: false)],
            defaults: defaults(lunch: "Packs a lunch")
        )
        XCTAssertTrue(plan.lunch.isException, "somebody has to make a lunch, so it must draw the eye")
    }

    func testADayWithAMealProvidedIsNot() {
        let plan = resolve(
            [exception(.lunch, "Lunch ordered", isNotable: false, lunchProvided: true)],
            defaults: defaults(lunch: "Packs a lunch")
        )
        XCTAssertFalse(plan.lunch.isException, "nothing to do, so it must not compete for attention")
        XCTAssertEqual(plan.lunch.value, "Lunch ordered", "the detail is still worth showing")
    }

    /// The silent failure the rule was rewritten to remove.
    ///
    /// The old rule ANDed in `value != baseline`. A baseline worded as the same
    /// words extraction emits cancelled the alert outright, so whether a kid
    /// was told to pack depended on how somebody once typed a free-text field.
    func testTheWordingOfTheBaselineCannotSilenceAPackDay() {
        let plan = resolve(
            [exception(.lunch, "Pack a lunch", lunchProvided: false)],
            defaults: defaults(lunch: "Pack a lunch")
        )
        XCTAssertTrue(plan.lunch.isException, "identical wording must not cancel the alert")
    }

    /// The noise in the other direction.
    func testAProvidedDayDoesNotNagEvenIfItLooksExciting() {
        let plan = resolve(
            [exception(.lunch, "Pizza day", isNotable: true, lunchProvided: true)],
            defaults: defaults(lunch: "Packs a lunch")
        )
        XCTAssertFalse(plan.lunch.isException, "lunch is handled; there is nothing to do")
    }

    /// A flagged day the document never explained. Deferring to the source's
    /// own judgement is the only safe reading — this is the one path that can
    /// otherwise go quiet on a day a lunch is genuinely needed.
    func testAnUnresolvedLunchStaysLoudWhenTheSourceThinksItMatters() {
        let plan = resolve(
            [exception(.lunch, "Lunch flagged on the calendar", isNotable: true, lunchProvided: nil)],
            defaults: defaults(lunch: "Packs a lunch")
        )
        XCTAssertTrue(plan.lunch.isException, "a flagged day the document never explained is worth a look")
    }

    /// Split from the test above rather than sharing one: `KidDayDefaults.kidID`
    /// and `DayException.id` are both unique attributes, and building two of
    /// either for one kid inside a single context is a constraint violation
    /// waiting to surprise somebody long after the assertion it broke.
    func testAnUnresolvedLunchStaysQuietWhenTheSourceSaysItIsDetail() {
        let plan = resolve(
            [exception(.lunch, "Uncured Hot Dog", isNotable: false, lunchProvided: nil)],
            defaults: defaults(lunch: "Hot lunch at school")
        )
        XCTAssertFalse(plan.lunch.isException, "a menu naming today's dish is detail, not news")
    }

    // MARK: - The baseline

    func testAnUncoveredDayReadsTheBaselineQuietly() {
        let plan = resolve([], defaults: defaults(lunch: "Packs a lunch", breakfast: "Breakfast at home"))

        XCTAssertEqual(plan.lunch.value, "Packs a lunch")
        XCTAssertFalse(plan.lunch.isException, "a standing habit is not news")
        XCTAssertEqual(plan.breakfast.value, "Breakfast at home")
    }

    // MARK: - Precedence

    /// A correction the user typed must survive the next sync re-reading the
    /// same menu.
    func testAManualEntryBeatsAnEmailOne() {
        let plan = resolve(
            [
                exception(.clothing, "Uniform", source: .email),
                exception(.clothing, "Jeans day", source: .manual),
            ],
            defaults: defaults(lunch: "", clothing: "Uniform")
        )
        XCTAssertEqual(plan.clothing.value, "Jeans day")
    }

    func testAScheduleBeatsAnEmail() {
        let plan = resolve(
            [
                exception(.clothing, "From a newsletter", source: .email),
                exception(.clothing, "From the calendar", source: .schedule),
            ],
            defaults: defaults(lunch: "", clothing: "Uniform")
        )
        XCTAssertEqual(plan.clothing.value, "From the calendar")
    }

    // MARK: - Reminders accumulate

    /// The one field where last-writer-wins would lose something true.
    func testTwoRemindersOnOneDayBothSurvive() {
        let plan = resolve(
            [exception(.reminder, "Jeans day"), exception(.reminder, "Field trip", source: .schedule)],
            defaults: defaults(lunch: "")
        )
        XCTAssertEqual(plan.reminders.count, 2)
    }

    func testTheSameReminderFromTwoSourcesReadsOnce() {
        let plan = resolve(
            [exception(.reminder, "Jeans day"), exception(.reminder, "jeans day", source: .schedule)],
            defaults: defaults(lunch: "")
        )
        XCTAssertEqual(plan.reminders.count, 1)
    }
}
