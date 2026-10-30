import Foundation

/// Computes HRV only inside an explicitly supplied sleep window.
/// It accepts exclusively verified WHOOP Type-47 revision-18 physiology.
/// RR values are never stitched across packet gaps larger than two minutes.
enum OvernightRRMetricsCalculator {
    struct Metrics: Equatable {
        let rmssdMilliseconds: Double
        let intervalCount: Int
        let packetCount: Int
        let medianHeartRateBPM: Int?
        let firstSampleAt: Date
        let lastSampleAt: Date
    }

    static func calculate(records: [HistoricalRRPacketRecord],
                          sleepStart: Date,
                          sleepEnd: Date,
                          maximumPacketGap: TimeInterval = 120,
                          minimumIntervals: Int = 30) -> Metrics? {
        guard sleepStart < sleepEnd, maximumPacketGap > 0, minimumIntervals >= 2 else {
            return nil
        }

        let eligible = records
            .filter {
                $0.recordType == 47 &&
                $0.revision == 18 &&
                $0.physiologyLayoutVerified &&
                $0.physiologicalTimestamp.map { $0 >= sleepStart && $0 < sleepEnd } == true
            }
            .sorted {
                ($0.physiologicalTimestamp ?? .distantPast) <
                ($1.physiologicalTimestamp ?? .distantPast)
            }

        guard !eligible.isEmpty else { return nil }

        var validIntervals: [Int] = []
        var acceptedPackets = 0
        var heartRates: [Int] = []
        var previousPacketAt: Date?

        for record in eligible {
            guard let timestamp = record.physiologicalTimestamp else { continue }
            if let previousPacketAt,
               timestamp.timeIntervalSince(previousPacketAt) > maximumPacketGap {
                // A long discontinuity invalidates the overnight aggregate:
                // RMSSD must not bridge an unknown section of the night.
                return nil
            }
            previousPacketAt = timestamp

            let intervals = record.intervalsMilliseconds
            guard !intervals.isEmpty,
                  intervals.allSatisfy({ (300...2000).contains($0) }) else {
                continue
            }
            validIntervals.append(contentsOf: intervals)
            acceptedPackets += 1
            if let bpm = record.heartRateBPM, (30...220).contains(bpm) {
                heartRates.append(bpm)
            }
        }

        guard validIntervals.count >= minimumIntervals else { return nil }
        let differences = zip(validIntervals, validIntervals.dropFirst()).map {
            Double($1 - $0)
        }
        guard differences.count >= minimumIntervals - 1,
              differences.allSatisfy({ abs($0) <= 300 }) else { return nil }

        let rmssd = sqrt(differences.reduce(0) { $0 + $1 * $1 } /
                         Double(differences.count))
        guard rmssd.isFinite, rmssd > 0 else { return nil }

        let sortedHR = heartRates.sorted()
        let medianHR: Int?
        if sortedHR.isEmpty {
            medianHR = nil
        } else {
            medianHR = sortedHR[sortedHR.count / 2]
        }

        return Metrics(rmssdMilliseconds: rmssd,
                       intervalCount: validIntervals.count,
                       packetCount: acceptedPackets,
                       medianHeartRateBPM: medianHR,
                       firstSampleAt: eligible.first?.physiologicalTimestamp ?? sleepStart,
                       lastSampleAt: eligible.last?.physiologicalTimestamp ?? sleepEnd)
    }
}
