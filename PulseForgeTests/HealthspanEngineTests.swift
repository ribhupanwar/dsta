import XCTest
@testable import PulseForge

final class HealthspanEngineTests: XCTestCase {
    func testCooper12MinuteEquationAndInputValidation() {
        XCTAssertEqual(Cooper12MinuteVO2.estimate(distanceMeters: 3000) ?? -1,
                       (3000 - 504.9) / 44.73, accuracy: 0.001)
        XCTAssertNil(Cooper12MinuteVO2.estimate(distanceMeters: 900))
        XCTAssertNil(Cooper12MinuteVO2.estimate(distanceMeters: .infinity))
    }

    func testEffectiveAgeUsesLogHazardRatio() {
        let delta = EffectiveAgeMath.ageDeltaYears(validatedHazardRatio: 1.10)
        XCTAssertEqual(delta ?? .nan, 1.0, accuracy: 0.0001)
    }

    func testMissingDataDoesNotBecomeZeroScore() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = HealthspanDailySample(date: date, sleepHours: 8)
        let result = PulseForgeHealthspanEngine.healthspan(samples: [sample], endingAt: date)
        XCTAssertEqual(result.coverage, 1.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(result.index ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(result.contributors.count, 1)
    }

    func testEmptyHistoryReturnsNoInventedAgeOrScore() {
        let result = PulseForgeHealthspanEngine.healthspan(samples: [],
            endingAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(result.index)
        XCTAssertEqual(result.coverage, 0)
    }

    func testVO2FusionRejectsStaleAndImplausibleValues() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let candidates = [
            VO2EstimateCandidate(value: 51, source: .healthKit, confidence: 0.8, observedAt: now),
            VO2EstimateCandidate(value: 52, source: .submaximalRun, confidence: 0.7, observedAt: now),
            VO2EstimateCandidate(value: 200, source: .racePerformance, confidence: 1, observedAt: now),
            VO2EstimateCandidate(value: 48, source: .healthKit, confidence: 1,
                                 observedAt: now.addingTimeInterval(-90 * 86400))
        ]
        let result = PulseForgeHealthspanEngine.fuseVO2(candidates: candidates, asOf: now)
        XCTAssertEqual(result.sourceCount, 2)
        XCTAssertEqual(result.value ?? -1, 51.47, accuracy: 0.1)
        XCTAssertGreaterThan(result.confidence, 0)
    }
}
