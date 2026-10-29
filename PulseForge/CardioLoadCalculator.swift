import Foundation

/// Transparent cardio-load estimate from timestamped workout heart-rate samples.
/// This is not WHOOP Strain; it is an auditable intensity-weighted duration metric.
enum CardioLoadCalculator {
    struct Sample: Equatable {
        let timestamp: Date
        let endDate: Date
        let bpm: Double
    }

    static func calculate(samples: [Sample], measuredMaxHeartRate: Int,
                          maximumCreditedGapSeconds: TimeInterval = 60) -> Double? {
        guard (100...240).contains(measuredMaxHeartRate),
              maximumCreditedGapSeconds.isFinite,
              maximumCreditedGapSeconds > 0 else { return nil }

        let valid = samples
            .filter { $0.timestamp <= $0.endDate && $0.bpm.isFinite && (30...240).contains($0.bpm) }
            .sorted { $0.timestamp < $1.timestamp }

        var unique: [Sample] = []
        for sample in valid where unique.last?.timestamp != sample.timestamp {
            unique.append(sample)
        }
        guard !unique.isEmpty else { return nil }

        var points = 0.0
        for index in unique.indices {
            let sample = unique[index]
            let duration = unique.indices.contains(index + 1)
                ? unique[index + 1].timestamp.timeIntervalSince(sample.timestamp)
                : sample.endDate.timeIntervalSince(sample.timestamp)
            let creditedMinutes = min(maximumCreditedGapSeconds, max(0, duration)) / 60
            let intensity = min(1, max(0, sample.bpm / Double(measuredMaxHeartRate)))
            points += creditedMinutes * intensity * 100
        }
        return points.isFinite && points > 0 ? points : nil
    }
}
