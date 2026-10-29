import Foundation

/// Transparent readiness estimate. Requires at least three prior daily baseline
/// observations for both metrics and uses medians to reduce single-day outliers.
enum RecoveryScoreCalculator {
    struct Result: Equatable {
        let score: Int
        let hrvComponent: Double
        let restingHeartRateComponent: Double
        let hrvBaseline: Double
        let restingHeartRateBaseline: Double
    }

    static func calculate(currentHRV: Double,
                          currentRestingHeartRate: Double,
                          baselineHRV: [Double],
                          baselineRestingHeartRate: [Double],
                          minimumBaselineDays: Int = 3) -> Result? {
        guard currentHRV.isFinite, currentRestingHeartRate.isFinite,
              currentHRV > 0, currentRestingHeartRate > 0,
              minimumBaselineDays >= 1,
              baselineHRV.count >= minimumBaselineDays,
              baselineRestingHeartRate.count >= minimumBaselineDays,
              baselineHRV.allSatisfy({ $0.isFinite && $0 > 0 }),
              baselineRestingHeartRate.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }

        let hrvBaseline = median(baselineHRV)
        let rhrBaseline = median(baselineRestingHeartRate)
        guard hrvBaseline > 0, rhrBaseline > 0 else { return nil }

        let hrv = clamp(50 + 50 * ((currentHRV / hrvBaseline) - 1) / 0.30, 0...100)
        let rhr = clamp(50 + 5 * (rhrBaseline - currentRestingHeartRate), 0...100)
        let score = Int((0.60 * hrv + 0.40 * rhr).rounded())
        return Result(score: score, hrvComponent: hrv,
                      restingHeartRateComponent: rhr,
                      hrvBaseline: hrvBaseline,
                      restingHeartRateBaseline: rhrBaseline)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
