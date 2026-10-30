import XCTest
@testable import PulseForge

final class SleepNeedCalculatorTests: XCTestCase {
    func testDoesNotInventEightHourPersonalBaseline() {
        XCTAssertNil(SleepNeedCalculator.calculate(sleepDebtHours: nil))
        XCTAssertNil(SleepNeedCalculator.calculate(sleepDebtHours: 0))
        XCTAssertNil(SleepNeedCalculator.calculate(baseNeedHours: nil, sleepDebtHours: 2))
    }

    func testUsesValidPersonalBaselineAndAddsHalfOfDebt() throws {
        let result = try XCTUnwrap(SleepNeedCalculator.calculate(.init(
            personalBaselineHours: 7.5,
            sleepDebtHours: 2,
            napMinutes: nil,
            strainAdjustmentHours: nil
        )))
        XCTAssertEqual(result.baselineHours, 7.5, accuracy: 0.001)
        XCTAssertEqual(result.debtAdjustmentHours, 1, accuracy: 0.001)
        XCTAssertEqual(result.targetHours, 8.5, accuracy: 0.001)
    }

    func testCapsDebtRepaymentNapAndStrainAdjustments() throws {
        let result = try XCTUnwrap(SleepNeedCalculator.calculate(.init(
            personalBaselineHours: 8,
            sleepDebtHours: 20,
            napMinutes: 500,
            strainAdjustmentHours: 5
        )))
        XCTAssertEqual(result.debtAdjustmentHours, 2, accuracy: 0.001)
        XCTAssertEqual(result.napAdjustmentHours, 1.5, accuracy: 0.001)
        XCTAssertEqual(result.strainAdjustmentHours, 1, accuracy: 0.001)
        XCTAssertEqual(result.targetHours, 9.5, accuracy: 0.001)
    }

    func testRejectsInvalidPersonalBaseline() {
        XCTAssertNil(SleepNeedCalculator.calculate(.init(
            personalBaselineHours: .nan,
            sleepDebtHours: 2,
            napMinutes: nil,
            strainAdjustmentHours: nil
        )))
        XCTAssertNil(SleepNeedCalculator.calculate(baseNeedHours: 4, sleepDebtHours: 0))
    }

    func testIgnoresInvalidOptionalAdjustmentsWhenBaselineExists() throws {
        let result = try XCTUnwrap(SleepNeedCalculator.calculate(.init(
            personalBaselineHours: 8,
            sleepDebtHours: .nan,
            napMinutes: -20,
            strainAdjustmentHours: .infinity
        )))
        XCTAssertEqual(result.targetHours, 8, accuracy: 0.001)
    }
}


final class SleepNeedHistoryCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func night(wakeDaysAgo: Int, hours: Double, now: Date) -> SleepNightCalculator.Night {
        let wake = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -wakeDaysAgo, to: now)!)
        let end = wake.addingTimeInterval(7 * 3600)
        return SleepNightCalculator.Night(
            wakeDate: wake,
            durationMinutes: hours * 60,
            startDate: end.addingTimeInterval(-hours * 3600),
            endDate: end
        )
    }

    func testLearnsBaselineAndDebtOnlyFromSufficientDatedHistory() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nights = (1...14).map { day in
            night(wakeDaysAgo: day, hours: day <= 5 ? 7 : 8, now: now)
        }
        let result = SleepNeedHistoryCalculator.calculate(nights: nights, now: now, calendar: calendar)
        XCTAssertEqual(result.baselineNightCount, 14)
        XCTAssertEqual(result.baselineHours ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(result.debtNightCount, 7)
        XCTAssertEqual(result.sleepDebtHours ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(result.sleepNeedHours ?? 0, 10, accuracy: 0.001)
    }

    func testDoesNotInventBaselineOrDebtWhenHistoryIsInsufficient() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let thirteenNights = (1...13).map { night(wakeDaysAgo: $0, hours: 8, now: now) }
        let noBaseline = SleepNeedHistoryCalculator.calculate(
            nights: thirteenNights, now: now, calendar: calendar
        )
        XCTAssertNil(noBaseline.baselineHours)
        XCTAssertNil(noBaseline.sleepNeedHours)
        XCTAssertNil(noBaseline.sleepDebtHours)

        let olderHistory = (9...22).map { night(wakeDaysAgo: $0, hours: 8, now: now) }
        let noRecentDebt = SleepNeedHistoryCalculator.calculate(
            nights: olderHistory, now: now, calendar: calendar
        )
        XCTAssertEqual(noRecentDebt.baselineHours ?? 0, 8, accuracy: 0.001)
        XCTAssertNil(noRecentDebt.sleepDebtHours)
        XCTAssertEqual(noRecentDebt.sleepNeedHours ?? 0, 8, accuracy: 0.001)
    }
}
