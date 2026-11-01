import Foundation

/// Diagnostic-only aggregation for decoded WHOOP Gen5 R21 accelerometer samples.
///
/// This deliberately does not produce steps. It reports acceleration-vector
/// variation and sample coverage so real device captures can be evaluated
/// before any proprietary step-estimation formula is implemented.
struct DailyIMUMotionDiagnostic: Identifiable, Equatable {
    let dayStart: Date
    let sampleCount: Int
    let motionIntensity: Double
    let coveredSeconds: TimeInterval
    let maximumGapSeconds: TimeInterval
    let gapCount: Int
    let duplicateTimestampCount: Int

    var id: Date { dayStart }
}

enum DailyIMUMotionAggregator {
    /// Aggregate samples by the supplied calendar's local day boundaries.
    /// A gap larger than `maximumContinuousGap` is recorded and is not bridged
    /// when calculating motion intensity or covered time.
    static func aggregate(
        _ samples: [WhoopIMUSample],
        calendar: Calendar = .current,
        maximumContinuousGap: TimeInterval = 0.25
    ) -> [DailyIMUMotionDiagnostic] {
        guard maximumContinuousGap > 0 else { return [] }

        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let grouped = Dictionary(grouping: ordered) {
            calendar.startOfDay(for: $0.timestamp)
        }

        return grouped.keys.sorted().compactMap { day in
            guard let daySamples = grouped[day], !daySamples.isEmpty else { return nil }

            var intensity = 0.0
            var covered: TimeInterval = 0
            var maximumGap = 0.0
            var gaps = 0
            var duplicates = 0

            for pair in zip(daySamples, daySamples.dropFirst()) {
                let elapsed = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
                if elapsed <= 0 {
                    duplicates += 1
                    continue
                }
                maximumGap = max(maximumGap, elapsed)
                guard elapsed <= maximumContinuousGap else {
                    gaps += 1
                    continue
                }

                covered += elapsed
                let dx = pair.1.accelerationXG - pair.0.accelerationXG
                let dy = pair.1.accelerationYG - pair.0.accelerationYG
                let dz = pair.1.accelerationZG - pair.0.accelerationZG
                intensity += (dx * dx + dy * dy + dz * dz).squareRoot()
            }

            return DailyIMUMotionDiagnostic(
                dayStart: day,
                sampleCount: daySamples.count,
                motionIntensity: intensity,
                coveredSeconds: covered,
                maximumGapSeconds: maximumGap,
                gapCount: gaps,
                duplicateTimestampCount: duplicates
            )
        }
    }
}
