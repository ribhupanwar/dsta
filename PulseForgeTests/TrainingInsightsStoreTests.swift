import XCTest
@testable import PulseForge

@MainActor
final class TrainingInsightsStoreTests: XCTestCase {
    func testDailyWorkoutSummaryIncludesPreviousDaySessionOverlap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = Date(timeIntervalSince1970: 86_400)
        let session = WorkoutSessionRecord(
            startedAt: dayStart.addingTimeInterval(-30),
            durationSeconds: 150,
            wasAutomatic: false,
            wasInterrupted: false,
            heartRateSamples: [
                LiveHeartRateSample(timestamp: dayStart.addingTimeInterval(-30), bpm: 150),
                LiveHeartRateSample(timestamp: dayStart.addingTimeInterval(30), bpm: 180),
                LiveHeartRateSample(timestamp: dayStart.addingTimeInterval(90), bpm: 160)
            ],
            imuSamples: []
        )
        let store = TrainingInsightsStore()

        store.refreshWorkoutLoad(
            sessions: [session],
            measuredMaxHeartRate: 200,
            now: dayStart.addingTimeInterval(3_600),
            calendar: calendar
        )

        XCTAssertEqual(store.workoutCountToday, 1)
        XCTAssertEqual(store.workoutMinutesToday ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(store.cardioLoadPoints ?? -1, 167.5, accuracy: 0.001)
        XCTAssertTrue(store.strainSourceStatus.contains("PulseForge cardio-load estimate"))
    }

    func testNoOverlappingWorkoutReportsNoSavedSession() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = Date(timeIntervalSince1970: 86_400)
        let store = TrainingInsightsStore()

        store.refreshWorkoutLoad(
            sessions: [],
            measuredMaxHeartRate: 200,
            now: dayStart.addingTimeInterval(3_600),
            calendar: calendar
        )

        XCTAssertEqual(store.workoutCountToday, 0)
        XCTAssertNil(store.workoutMinutesToday)
        XCTAssertNil(store.cardioLoadPoints)
        XCTAssertTrue(store.strainSourceStatus.contains("No saved WHOOP workout HR session today"))
    }

    func testInvalidMeasuredMaximumHeartRateIsReportedSeparatelyFromMissingWorkout() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = Date(timeIntervalSince1970: 86_400)
        let session = WorkoutSessionRecord(
            startedAt: dayStart.addingTimeInterval(60),
            durationSeconds: 120,
            wasAutomatic: false,
            wasInterrupted: false,
            heartRateSamples: [
                LiveHeartRateSample(timestamp: dayStart.addingTimeInterval(60), bpm: 150)
            ],
            imuSamples: []
        )
        let store = TrainingInsightsStore()

        store.refreshWorkoutLoad(
            sessions: [session],
            measuredMaxHeartRate: 99,
            now: dayStart.addingTimeInterval(3_600),
            calendar: calendar
        )

        XCTAssertEqual(store.workoutCountToday, 1)
        XCTAssertEqual(store.workoutMinutesToday ?? -1, 2.0, accuracy: 0.001)
        XCTAssertNil(store.cardioLoadPoints)
        XCTAssertTrue(store.strainSourceStatus.contains("Set a valid measured maximum HR"))
    }

    func testWorkoutWithoutHeartRateSamplesIsNotReportedAsNoWorkout() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = Date(timeIntervalSince1970: 86_400)
        let session = WorkoutSessionRecord(
            startedAt: dayStart.addingTimeInterval(60),
            durationSeconds: 120,
            wasAutomatic: false,
            wasInterrupted: false,
            heartRateSamples: [],
            imuSamples: []
        )
        let store = TrainingInsightsStore()

        store.refreshWorkoutLoad(
            sessions: [session],
            measuredMaxHeartRate: 200,
            now: dayStart.addingTimeInterval(3_600),
            calendar: calendar
        )

        XCTAssertEqual(store.workoutCountToday, 1)
        XCTAssertEqual(store.workoutMinutesToday ?? -1, 2.0, accuracy: 0.001)
        XCTAssertNil(store.cardioLoadPoints)
        XCTAssertTrue(store.strainSourceStatus.contains("No valid timestamped WHOOP workout HR samples"))
    }

}
