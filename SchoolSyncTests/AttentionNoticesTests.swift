import XCTest

/// Whether a warning should be raised, given what is on screen and what the
/// user has already dealt with.
///
/// The rule looks trivial and was wrong in a way that made a working button
/// look broken: dismissal removed the notice, and the next sync — foreground,
/// background refresh, or a pull — put it straight back, because "absent from
/// the list" was being read as "never seen".
final class AttentionNoticesTests: XCTestCase {

    func testANewWarningIsRecorded() {
        XCTAssertTrue(AttentionNotices.shouldRecord("email-1", existing: [], dismissed: []))
    }

    /// The same email arrives on every sync until somebody reviews it. Two
    /// copies of one warning teaches the parent to ignore all of them.
    func testAWarningAlreadyOnScreenIsNotRecordedTwice() {
        XCTAssertFalse(AttentionNotices.shouldRecord("email-1", existing: ["email-1"], dismissed: []))
    }

    /// The bug, stated so it can't come back. Dismissing empties `existing`,
    /// which is exactly when the old rule decided the warning was new.
    func testADismissedWarningStaysDismissed() {
        XCTAssertFalse(
            AttentionNotices.shouldRecord("email-1", existing: [], dismissed: ["email-1"]),
            "dismissing must survive the next sync, or the button appears to do nothing"
        )
    }

    /// Dismiss all has to cover every id it cleared, not just the last one.
    func testDismissAllCoversEveryWarningItCleared() {
        let dismissed = ["email-1", "email-2", "email-3"]

        for id in dismissed {
            XCTAssertFalse(AttentionNotices.shouldRecord(id, existing: [], dismissed: dismissed))
        }
    }

    /// Dismissing one email must not silence the next one. The whole point of
    /// the screen is to say *which* newsletter lost a picture.
    func testADifferentEmailStillRaisesAWarning() {
        XCTAssertTrue(
            AttentionNotices.shouldRecord("email-2", existing: ["email-1"], dismissed: ["email-1"]),
            "a new email is new regardless of what was dismissed before it"
        )
    }

    func testDecodingEmptyStorageYieldsNothing() {
        XCTAssertTrue(AttentionNotices.decode(Data()).isEmpty)
    }

    /// Stored notices survive a round trip, and the newest reads first — the
    /// screen exists to point at a specific recent email.
    func testNoticesDecodeNewestFirst() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let older = AttentionNotice(
            id: "a", subject: "Older", note: "n", receivedAt: .now.addingTimeInterval(-7200)
        )
        let newer = AttentionNotice(
            id: "b", subject: "Newer", note: "n", receivedAt: .now.addingTimeInterval(-60)
        )

        let decoded = AttentionNotices.decode(try encoder.encode([older, newer]))

        XCTAssertEqual(decoded.map(\.id), ["b", "a"])
    }

    /// A warning about a calendar picture missed two months ago is history, not
    /// a task, and must not reappear on a fresh install's first sync.
    func testWarningsOlderThanThirtyDaysAgeOut() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let ancient = AttentionNotice(
            id: "old", subject: "Ancient", note: "n",
            receivedAt: .now.addingTimeInterval(-31 * 24 * 60 * 60)
        )

        XCTAssertTrue(AttentionNotices.decode(try encoder.encode([ancient])).isEmpty)
    }
}
