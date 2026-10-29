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

    func testUsesFinalSampleDurationWhenAvailable() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sample = CardioLoadCalculator.Sample(timestamp: start,
                                                 endDate: start.addingTimeInterval(30), bpm: 100)
        let result = try XCTUnwrap(CardioLoadCalculator.calculate(samples: [sample], measuredMaxHeartRate: 200))
        XCTAssertEqual(result, 25, accuracy: 0.001)
    }
}
