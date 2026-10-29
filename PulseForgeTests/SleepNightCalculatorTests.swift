import XCTest
@testable import PulseForge

final class SleepNightCalculatorTests: XCTestCase {
    func testOverlappingSamplesAreCountedOnlyOnce() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-29T08:00:00Z")
        let intervals = [
            DateInterval(start: date("2026-10-28T23:00:00Z"), end: date("2026-10-29T02:00:00Z")),
            DateInterval(start: date("2026-10-29T01:00:00Z"), end: date("2026-10-29T06:00:00Z"))
        ]
        let result = SleepNightCalculator.summarize(
            intervals: intervals, now: now, calendar: calendar
        )
        XCTAssertEqual(result.latestNight?.durationMinutes, 420, accuracy: 0.001)
        XCTAssertEqual(result.nights.count, 1)
    }

    func testShortAwakeningFragmentsRemainOneNight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-29T08:00:00Z")
        let intervals = [
            DateInterval(start: date("2026-10-28T23:00:00Z"), end: date("2026-10-29T02:00:00Z")),
            DateInterval(start: date("2026-10-29T02:30:00Z"), end: date("2026-10-29T06:00:00Z"))
        ]
        let result = SleepNightCalculator.summarize(
            intervals: intervals, now: now, calendar: calendar
        )
        XCTAssertEqual(result.nights.count, 1)
        XCTAssertEqual(result.latestNight?.durationMinutes, 330, accuracy: 0.001)
    }

    func testLongGapCreatesSeparateSessionsAndDebtUsesRecordedNightsOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-29T12:00:00Z")
        let intervals = [
            DateInterval(start: date("2026-10-27T23:00:00Z"), end: date("2026-10-28T05:00:00Z")),
            DateInterval(start: date("2026-10-28T23:00:00Z"), end: date("2026-10-29T05:00:00Z"))
        ]
        let result = SleepNightCalculator.summarize(
            intervals: intervals, now: now, calendar: calendar,
            targetMinutes: 480, debtWindowNights: 7
        )
        XCTAssertEqual(result.nights.count, 2)
        XCTAssertEqual(result.sleepDebtHours, 4, accuracy: 0.001)
        XCTAssertEqual(result.latestNight?.wakeDate, calendar.startOfDay(for: date("2026-10-29T05:00:00Z")))
    }

    func testIgnoresFutureOrInvalidIntervals() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-29T08:00:00Z")
        let intervals = [
            DateInterval(start: date("2026-10-29T09:00:00Z"), end: date("2026-10-29T10:00:00Z")),
            DateInterval(start: date("2026-10-28T23:00:00Z"), end: date("2026-10-29T06:00:00Z"))
        ]
        let result = SleepNightCalculator.summarize(
            intervals: intervals, now: now, calendar: calendar
        )
        XCTAssertEqual(result.nights.count, 1)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
