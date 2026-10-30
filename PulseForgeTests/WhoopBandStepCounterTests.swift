import XCTest
@testable import PulseForge

final class WhoopBandStepCounterTests: XCTestCase {
    func testAccumulatesBandCounterDeltasForLocalDay() {
        var counter = WhoopBandStepCounter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        counter.ingest(.init(timestamp: start, counter: 100), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(1), counter: 103), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(2), counter: 108), calendar: calendar)
        XCTAssertEqual(counter.steps(for: start, calendar: calendar), 8)
    }

    func testRecoversUInt16Wrap() {
        var counter = WhoopBandStepCounter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        counter.ingest(.init(timestamp: start, counter: 65_530), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(2), counter: 3), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(3), counter: 6), calendar: calendar)
        XCTAssertEqual(counter.steps(for: start, calendar: calendar), 12)
    }

    func testRejectsCounterResetAndContinuesAfterReanchor() {
        var counter = WhoopBandStepCounter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        counter.ingest(.init(timestamp: start, counter: 40_000), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(1), counter: 0), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(2), counter: 5), calendar: calendar)
        XCTAssertEqual(counter.steps(for: start, calendar: calendar), 5)
        XCTAssertEqual(counter.droppedBoundaries, 1)
    }

    func testIgnoresDuplicateAndOutOfOrderHistoricalFrames() {
        var counter = WhoopBandStepCounter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        counter.ingest(.init(timestamp: start, counter: 100), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(2), counter: 105), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(1), counter: 103), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(2), counter: 105), calendar: calendar)
        XCTAssertEqual(counter.steps(for: start, calendar: calendar), 5)
    }

    func testAttributesMidnightCrossingDeltaToNewLocalDay() {
        var counter = WhoopBandStepCounter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))!
        let previousDay = midnight.addingTimeInterval(-1)
        counter.ingest(.init(timestamp: previousDay, counter: 500), calendar: calendar)
        counter.ingest(.init(timestamp: midnight.addingTimeInterval(1), counter: 503), calendar: calendar)
        XCTAssertEqual(counter.steps(for: midnight, calendar: calendar), 3)
        XCTAssertEqual(counter.steps(for: previousDay, calendar: calendar), nil)
    }

    func testFirstCounterSampleDoesNotInventDailySteps() {
        var counter = WhoopBandStepCounter()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        counter.ingest(.init(timestamp: date, counter: 900))
        XCTAssertNil(counter.steps(for: date))
    }

    func testSnapshotRestoresDailyCountAndCounterWatermark() throws {
        var counter = WhoopBandStepCounter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        counter.ingest(.init(timestamp: start, counter: 20))
        counter.ingest(.init(timestamp: start.addingTimeInterval(1), counter: 25))
        let data = try JSONEncoder().encode(counter.snapshot())
        var restored = WhoopBandStepCounter()
        restored.restore(try JSONDecoder().decode(WhoopBandStepCounter.Snapshot.self, from: data))
        restored.ingest(.init(timestamp: start.addingTimeInterval(2), counter: 29))
        XCTAssertEqual(restored.steps(for: start), 9)
    }
    func testAcceptsIncreasingCounterSamplesWithinSameSecond() {
        var counter = WhoopBandStepCounter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        counter.ingest(.init(timestamp: start, counter: 100), calendar: calendar)
        counter.ingest(.init(timestamp: start, counter: 102), calendar: calendar)
        counter.ingest(.init(timestamp: start, counter: 102), calendar: calendar)
        counter.ingest(.init(timestamp: start, counter: 101), calendar: calendar)
        counter.ingest(.init(timestamp: start.addingTimeInterval(1), counter: 105), calendar: calendar)
        XCTAssertEqual(counter.steps(for: start, calendar: calendar), 5)
        XCTAssertEqual(counter.latestSample?.counter, 105)
    }

    func testRejectsImplausibleSameSecondCounterJumpWithoutReanchoring() {
        var counter = WhoopBandStepCounter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        counter.ingest(.init(timestamp: start, counter: 100), calendar: calendar)
        counter.ingest(.init(timestamp: start, counter: 120), calendar: calendar)
        XCTAssertNil(counter.steps(for: start, calendar: calendar))
        XCTAssertEqual(counter.latestSample?.counter, 100)
        XCTAssertEqual(counter.droppedBoundaries, 1)
    }

}
