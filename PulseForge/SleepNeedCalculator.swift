import Foundation

/// Conservative, transparent sleep-target estimate.
/// The 8-hour base is retained; up to half of accumulated sleep debt (capped
/// at 2 hours) is added to tonight's target to avoid demanding full repayment
/// in one night. This is a PulseForge heuristic, not WHOOP's proprietary model.
enum SleepNeedCalculator {
    static func calculate(baseNeedHours: Double = 8,
                          sleepDebtHours: Double?) -> Double {
        guard baseNeedHours.isFinite, baseNeedHours > 0 else { return 8 }
        let debt = sleepDebtHours.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let repayment = min(2, debt * 0.5)
        return baseNeedHours + repayment
    }
}
