import Foundation

/// Computes HRV only inside an explicitly supplied sleep window.
/// It accepts exclusively verified WHOOP Type-47 revision-18 physiology.
/// RR differences are calculated within each packet only; packet boundaries
/// are not assumed to contain a contiguous pair of beats.
enum OvernightRRMetricsCalculator {
    struct Metrics: Equatable {
        let rmssdMilliseconds: Double
        let intervalCount: Int
        let differenceCount: Int
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

        let eligible = records.filter {
            $0.recordType == 47 &&
            $0.revision == 18 &&
            $0.physiologyLayoutVerified &&
            $0.physiologicalTimestamp.map { $0 >= sleepStart && $0 < sleepEnd } == true
        }

        // Multiple archive writes/reconnects can contain the same physiological
        // second. Keep one deterministic record per timestamp, preferring the
        // record with the most validated RR intervals.
        let deduplicated = Dictionary(grouping: eligible) {
            $0.physiologicalTimestamp!.timeIntervalSince1970
        }.compactMap { _, candidates in
            candidates.sorted {
                if $0.intervalsMilliseconds.count != $1.intervalsMilliseconds.count {
                    return $0.intervalsMilliseconds.count > $1.intervalsMilliseconds.count
                }
                return $0.rawFrameHex < $1.rawFrameHex
            }.first
        }.sorted {
            $0.physiologicalTimestamp! < $1.physiologicalTimestamp!
        }

        guard !deduplicated.isEmpty else { return nil }

        var intervalCount = 0
        var squaredDifferenceSum = 0.0
        var differenceCount = 0
        var acceptedPackets = 0
        var heartRates: [Int] = []
        var previousPacketAt: Date?

        for record in deduplicated {
            guard let timestamp = record.physiologicalTimestamp else { continue }
            if let previousPacketAt,
               timestamp.timeIntervalSince(previousPacketAt) > maximumPacketGap {
                // Do not aggregate across an unknown section of the night.
                return nil
            }
            previousPacketAt = timestamp

            let intervals = record.intervalsMilliseconds
            guard !intervals.isEmpty,
                  intervals.allSatisfy({ (300...2000).contains($0) }) else {
                continue
            }

            intervalCount += intervals.count
            acceptedPackets += 1

            // Never calculate a synthetic RR pair between separate packets.
            for (left, right) in zip(intervals, intervals.dropFirst()) {
                let difference = right - left
                guard abs(difference) <= 300 else { return nil }
                squaredDifferenceSum += Double(difference * difference)
                differenceCount += 1
            }

            if let bpm = record.heartRateBPM, (30...220).contains(bpm) {
                heartRates.append(bpm)
            }
        }

        guard intervalCount >= minimumIntervals,
              differenceCount >= minimumIntervals - 1 else { return nil }

        let rmssd = sqrt(squaredDifferenceSum / Double(differenceCount))
        guard rmssd.isFinite, rmssd > 0 else { return nil }

        let sortedHR = heartRates.sorted()
        let medianHR: Int?
        if sortedHR.isEmpty {
            medianHR = nil
        } else if sortedHR.count.isMultiple(of: 2) {
            medianHR = Int((Double(sortedHR[sortedHR.count / 2 - 1] +
                                   sortedHR[sortedHR.count / 2]) / 2).rounded())
        } else {
            medianHR = sortedHR[sortedHR.count / 2]
        }

        return Metrics(rmssdMilliseconds: rmssd,
                       intervalCount: intervalCount,
                       differenceCount: differenceCount,
                       packetCount: acceptedPackets,
                       medianHeartRateBPM: medianHR,
                       firstSampleAt: deduplicated.first?.physiologicalTimestamp ?? sleepStart,
                       lastSampleAt: deduplicated.last?.physiologicalTimestamp ?? sleepEnd)
    }
}
