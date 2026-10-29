import Foundation

/// Short-window RMSSD from validated beat-to-beat intervals.
/// This is a live trend estimate, not a substitute for overnight HRV/WHOOP Recovery.
enum RRVariabilityCalculator {
    static let minimumIntervalCount = 30

    static func rmssdMilliseconds(from intervals: [Int]) -> Double? {
        guard intervals.count >= minimumIntervalCount,
              intervals.allSatisfy({ (250...3000).contains($0) }) else {
            return nil
        }
        let squaredDifferences = zip(intervals, intervals.dropFirst()).map { pair -> Double in
            let difference = Double(pair.1 - pair.0)
            return difference * difference
        }
        guard !squaredDifferences.isEmpty else { return nil }
        let meanSquaredDifference = squaredDifferences.reduce(0, +) / Double(squaredDifferences.count)
        let result = sqrt(meanSquaredDifference)
        return result.isFinite ? result : nil
    }
}
