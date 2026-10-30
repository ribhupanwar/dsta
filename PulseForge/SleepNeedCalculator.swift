import Foundation

/// Transparent Sleep Need estimate with optional WHOOP-documented input categories.
/// Coefficients are PulseForge heuristics, not WHOOP's unpublished formula.
enum SleepNeedCalculator {
    struct Inputs {
        let personalBaselineHours: Double?
        let sleepDebtHours: Double?
        let napMinutes: Double?
        let strainAdjustmentHours: Double?
    }

    struct Result: Equatable {
        let targetHours: Double
        let baselineHours: Double
        let debtAdjustmentHours: Double
        let napAdjustmentHours: Double
        let strainAdjustmentHours: Double
    }

    static func calculate(_ inputs: Inputs) -> Result? {
        // A stable personal baseline must be supplied by a future learning
        // layer; do not infer physiological need from sleep duration alone.
        let baseline = inputs.personalBaselineHours.flatMap {
            $0.isFinite && (5...12).contains($0) ? $0 : nil
        } ?? nil
        guard let baseline else { return nil }

        let debt = inputs.sleepDebtHours.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        let debtAdjustment = min(2, debt * 0.5)

        let nap = inputs.napMinutes.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        let napAdjustment = min(1.5, nap / 60)

        let strain = inputs.strainAdjustmentHours.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        let boundedStrain = min(1, strain)

        let target = min(12, max(5, baseline + debtAdjustment - napAdjustment + boundedStrain))
        return Result(
            targetHours: target,
            baselineHours: baseline,
            debtAdjustmentHours: debtAdjustment,
            napAdjustmentHours: napAdjustment,
            strainAdjustmentHours: boundedStrain
        )
    }

    /// Convenience API that refuses to invent an 8-hour personal baseline.
    /// Returns nil until a valid personal baseline has been learned.
    static func calculate(baseNeedHours: Double? = nil, sleepDebtHours: Double?) -> Double? {
        calculate(Inputs(
            personalBaselineHours: baseNeedHours,
            sleepDebtHours: sleepDebtHours,
            napMinutes: nil,
            strainAdjustmentHours: nil
        ))?.targetHours
    }
}


/// Learns a personal sleep baseline from real, dated sleep sessions.
/// Requires at least 14 distinct wake-days in the trailing 28 days; debt is
/// reported only with at least 5 of the most recent 7 nights present.
enum SleepNeedHistoryCalculator {
    struct Result: Equatable {
        let baselineHours: Double?
        let sleepDebtHours: Double?
        let sleepNeedHours: Double?
        let baselineNightCount: Int
        let debtNightCount: Int
    }

    static func calculate(nights: [SleepNightCalculator.Night],
                          now: Date,
                          calendar: Calendar = .current) -> Result {
        let today = calendar.startOfDay(for: now)
        let baselineStart = calendar.date(byAdding: .day, value: -28, to: today)
            ?? today.addingTimeInterval(-28 * 86_400)
        let baselineNights = nights.filter {
            $0.wakeDate >= baselineStart && $0.wakeDate <= today &&
            $0.durationMinutes.isFinite && $0.durationMinutes > 0
        }.sorted { $0.wakeDate > $1.wakeDate }

        let baseline: Double?
        if baselineNights.count >= 14 {
            let values = baselineNights.map { $0.durationMinutes / 60 }.sorted()
            let middle = values.count / 2
            baseline = values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]
        } else {
            baseline = nil
        }

        let debtStart = calendar.date(byAdding: .day, value: -8, to: today)
            ?? today.addingTimeInterval(-8 * 86_400)
        let recentNights = nights.filter {
            $0.wakeDate >= debtStart && $0.wakeDate <= today &&
            $0.durationMinutes.isFinite && $0.durationMinutes > 0
        }.sorted { $0.wakeDate > $1.wakeDate }.prefix(7)

        let debt: Double?
        if let baseline, recentNights.count >= 5 {
            debt = recentNights.reduce(0.0) {
                $0 + max(0, baseline * 60 - $1.durationMinutes)
            } / 60
        } else {
            debt = nil
        }

        let need = baseline.flatMap {
            SleepNeedCalculator.calculate(.init(
                personalBaselineHours: $0,
                sleepDebtHours: debt,
                napMinutes: nil,
                strainAdjustmentHours: nil
            ))?.targetHours
        }
        return Result(
            baselineHours: baseline,
            sleepDebtHours: debt,
            sleepNeedHours: need,
            baselineNightCount: baselineNights.count,
            debtNightCount: recentNights.count
        )
    }
}
