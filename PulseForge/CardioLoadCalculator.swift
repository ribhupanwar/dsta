import Foundation

/// Transparent cardio-load estimate from timestamped workout heart-rate samples.
/// This is not WHOOP Strain; it is an auditable intensity-weighted duration metric.
enum CardioLoadCalculator {
    struct Sample: Equatable {
        let timestamp: Date
        let endDate: Date
        let bpm: Double
    }

    /// Sums HR-derived load from saved WHOOP workout recordings on a local calendar day.
    /// This is a PulseForge cardio-load estimate, not WHOOP's proprietary 0–21 Strain.
    static func dailyWorkoutLoad(sessions: [WorkoutSessionRecord],
                                  dayStart: Date,
                                  nextDay: Date,
                                  measuredMaxHeartRate: Int) -> Double? {
        guard dayStart < nextDay, (100...240).contains(measuredMaxHeartRate) else { return nil }
        let todaysSessions = sessions.filter {
            $0.startedAt >= dayStart && $0.startedAt < nextDay && !$0.heartRateSamples.isEmpty
        }
        guard !todaysSessions.isEmpty else { return nil }

        let loads = todaysSessions.compactMap { session -> Double? in
            let samples = session.heartRateSamples.sorted { $0.timestamp < $1.timestamp }
            let sessionEnd = session.startedAt.addingTimeInterval(max(0, session.durationSeconds))
            let points = samples.enumerated().map { index, sample -> Sample in
                let nextTimestamp = index + 1 < samples.count ? samples[index + 1].timestamp : sessionEnd
                let end = min(sessionEnd, max(sample.timestamp, min(nextTimestamp, sample.timestamp.addingTimeInterval(60))))
                return Sample(timestamp: sample.timestamp, endDate: end, bpm: Double(sample.bpm))
            }
            return calculate(samples: points, measuredMaxHeartRate: measuredMaxHeartRate)
        }
        guard !loads.isEmpty else { return nil }
        let total = loads.reduce(0, +)
        return total.isFinite && total > 0 ? total : nil
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
