import XCTest
@testable import PulseForge

final class CardioLoadCalculatorTests: XCTestCase {
    func testWeightsCreditedDurationByHeartRateIntensity() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [
            CardioLoadCalculator.Sample(timestamp: start, endDate: start, bpm: 150),
            CardioLoadCalculator.Sample(timestamp: start.addingTimeInterval(60),
                                        endDate: start.addingTimeInterval(120), bpm: 180)
        ]
        let result = try XCTUnwrap(CardioLoadCalculator.calculate(samples: samples, measuredMaxHeartRate: 200))
        XCTAssertEqual(result, 165, accuracy: 0.001)
    }

    func testCapsLongGapsInsteadOfCreditingMissingMinutes() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [
            CardioLoadCalculator.Sample(timestamp: start, endDate: start, bpm: 160),
            CardioLoadCalculator.Sample(timestamp: start.addingTimeInterval(600),
                                        endDate: start.addingTimeInterval(600), bpm: 160)
        ]
        let result = try XCTUnwrap(CardioLoadCalculator.calculate(samples: samples, measuredMaxHeartRate: 200))
        XCTAssertEqual(result, 80, accuracy: 0.001)
    }

    func testDeduplicatesTimestampsAndRejectsInvalidInputs() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let duplicate = CardioLoadCalculator.Sample(timestamp: start, endDate: start, bpm: 150)
        let next = CardioLoadCalculator.Sample(timestamp: start.addingTimeInterval(60),
                                               endDate: start.addingTimeInterval(60), bpm: 150)
        let result = try XCTUnwrap(CardioLoadCalculator.calculate(samples: [duplicate, duplicate, next],
                                                                  measuredMaxHeartRate: 200))
        XCTAssertEqual(result, 75, accuracy: 0.001)
        XCTAssertNil(CardioLoadCalculator.calculate(samples: [duplicate], measuredMaxHeartRate: 99))
        XCTAssertNil(CardioLoadCalculator.calculate(samples: [
            .init(timestamp: start, endDate: start, bpm: .nan)
        ], measuredMaxHeartRate: 200))
    }

    func testDailyWorkoutLoadUsesOnlySessionsWithinDayAndNeedsMeasuredMaxHR() throws {
        let dayStart = Date(timeIntervalSince1970: 1_000)
        let nextDay = dayStart.addingTimeInterval(86_400)
        let session = WorkoutSessionRecord(
            startedAt: dayStart.addingTimeInterval(60),
            durationSeconds: 120,
            wasAutomatic: false,
            wasInterrupted: false,
            heartRateSamples: [
                LiveHeartRateSample(timestamp: dayStart.addingTimeInterval(60), bpm: 150),
                LiveHeartRateSample(timestamp: dayStart.addingTimeInterval(120), bpm: 150)
            ],
            imuSamples: []
        )
        let outside = WorkoutSessionRecord(
            startedAt: nextDay,
            durationSeconds: 120,
            wasAutomatic: false,
            wasInterrupted: false,
            heartRateSamples: [LiveHeartRateSample(timestamp: nextDay, bpm: 150)],
            imuSamples: []
        )
        let load = try XCTUnwrap(CardioLoadCalculator.dailyWorkoutLoad(
            sessions: [session, outside], dayStart: dayStart, nextDay: nextDay,
            measuredMaxHeartRate: 200
        ))
        XCTAssertEqual(load, 75, accuracy: 0.001)
        XCTAssertNil(CardioLoadCalculator.dailyWorkoutLoad(
            sessions: [session], dayStart: dayStart, nextDay: nextDay,
            measuredMaxHeartRate: 0
        ))
    }

    func testUsesFinalSampleDurationWhenAvailable() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sample = CardioLoadCalculator.Sample(timestamp: start,
                                                 endDate: start.addingTimeInterval(30), bpm: 100)
        let result = try XCTUnwrap(CardioLoadCalculator.calculate(samples: [sample], measuredMaxHeartRate: 200))
        XCTAssertEqual(result, 25, accuracy: 0.001)
    }
}
