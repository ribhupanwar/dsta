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
    static func calculate(baseNeedHours: Double?, sleepDebtHours: Double?) -> Double? {
        calculate(Inputs(
            personalBaselineHours: baseNeedHours,
            sleepDebtHours: sleepDebtHours,
            napMinutes: nil,
            strainAdjustmentHours: nil
        ))?.targetHours
    }
}
