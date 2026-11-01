import Foundation

/// Transparent estimates derived from WHOOP Gen5 historical v18 records.
/// These are not WHOOP's proprietary HRV/RHR outputs or Recovery score.
enum HistoricalRecoveryMetrics {
    struct Result: Equatable {
        /// Median of qualifying 5-minute RMSSD windows, in milliseconds.
        let overnightRMSSDMilliseconds: Double?
        let qualifyingHRVWindows: Int
        let acceptedRRIntervals: Int
        let rejectedRRIntervals: Int
        /// Lowest qualifying rolling 30-minute mean HR, in bpm.
        let restingHeartRateBPM: Double?
        let restingHeartRateWindowCoverage: Double
        let validHeartRateSamples: Int
    }

    private static let hrvWindowSeconds: TimeInterval = 300
    private static let rhrWindowSeconds: TimeInterval = 30 * 60
    private static let minimumRRIntervals = 30
    private static let maximumArtifactFraction = 0.05
    private static let minimumRHRWindowCoverage = 0.80

    static func calculate(from records: [HistoricalRRPacketRecord]) -> Result {
        let ordered = uniquePhysiologicalRecords(records)
        let hrv = calculateHRV(from: ordered)
        let rhr = calculateRHR(from: ordered)
        return Result(
            overnightRMSSDMilliseconds: median(hrv.values),
            qualifyingHRVWindows: hrv.values.count,
            acceptedRRIntervals: hrv.accepted,
            rejectedRRIntervals: hrv.rejected,
            restingHeartRateBPM: rhr.value,
            restingHeartRateWindowCoverage: rhr.coverage,
            validHeartRateSamples: rhr.samples
        )
    }

    /// Ignore malformed/unsupported records and deduplicate by physiological
    /// timestamp. Receipt time is never used as a substitute for sensor time.
    private static func uniquePhysiologicalRecords(
        _ records: [HistoricalRRPacketRecord]
    ) -> [HistoricalRRPacketRecord] {
        let candidates = records.filter {
            $0.recordType == 47 && $0.revision == 18 &&
            $0.decodeError == nil && $0.physiologicalTimestamp != nil
        }.sorted {
            $0.physiologicalTimestamp! < $1.physiologicalTimestamp!
        }

        var result: [HistoricalRRPacketRecord] = []
        var previousTimestamp: TimeInterval?
        for record in candidates {
            guard let timestamp = record.physiologicalTimestamp?.timeIntervalSince1970 else { continue }
            if let previousTimestamp, abs(timestamp - previousTimestamp) < 0.001 {
                // Keep the first CRC-valid record at a timestamp; do not double-count it.
                continue
            }
            result.append(record)
            previousTimestamp = timestamp
        }
        return result
    }

    private static func calculateHRV(
        from records: [HistoricalRRPacketRecord]
    ) -> (values: [Double], accepted: Int, rejected: Int) {
        var windows: [Double] = []
        var acceptedTotal = 0
        var rejectedTotal = 0
        var run: [HistoricalRRPacketRecord] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            var buckets: [Int: [Int]] = [:]
            for record in run {
                guard let timestamp = record.physiologicalTimestamp?.timeIntervalSince1970 else { continue }
                let bucket = Int(floor(timestamp / hrvWindowSeconds))
                buckets[bucket, default: []].append(contentsOf: record.intervalsMilliseconds)
            }

            for key in buckets.keys.sorted() {
                guard let rawIntervals = buckets[key] else { continue }
                let cleaned = cleanRRIntervals(rawIntervals)
                acceptedTotal += cleaned.accepted.count
                rejectedTotal += cleaned.rejected
                guard rawIntervals.count >= minimumRRIntervals,
                      cleaned.accepted.count >= minimumRRIntervals,
                      Double(cleaned.rejected) / Double(rawIntervals.count) <= maximumArtifactFraction,
                      let value = rmssd(cleaned.accepted) else { continue }
                windows.append(value)
            }
            run.removeAll(keepingCapacity: true)
        }

        var previousTimestamp: TimeInterval?
        for record in records {
            guard let timestamp = record.physiologicalTimestamp?.timeIntervalSince1970 else { continue }
            let hasRR = !record.intervalsMilliseconds.isEmpty
            let isContinuous = previousTimestamp.map { timestamp - $0 <= 1.5 && timestamp > $0 } ?? false

            if !hasRR {
                flushRun()
                previousTimestamp = timestamp
                continue
            }
            if !run.isEmpty && !isContinuous {
                flushRun()
            }
            run.append(record)
            previousTimestamp = timestamp
        }
        flushRun()
        return (windows, acceptedTotal, rejectedTotal)
    }

    /// Conservative local-neighbour artifact rejection. No interpolation is
    /// performed: rejected beats are excluded and the artifact rate is reported.
    private static func cleanRRIntervals(_ values: [Int]) -> (accepted: [Int], rejected: Int) {
        var accepted: [Int] = []
        var rejected = 0
        for index in values.indices {
            let value = values[index]
            guard (300...2000).contains(value) else {
                rejected += 1
                continue
            }

            let lower = max(values.startIndex, index - 2)
            let upper = min(values.endIndex - 1, index + 2)
            let neighbours = values[lower...upper].enumerated()
                .filter { lower + $0.offset != index && (300...2000).contains($0.element) }
                .map(\.element)
            if neighbours.count >= 2, let localMedian = median(neighbours) {
                let threshold = max(200.0, Double(localMedian) * 0.20)
                if abs(Double(value - localMedian)) > threshold {
                    rejected += 1
                    continue
                }
            }
            accepted.append(value)
        }
        return (accepted, rejected)
    }

    private static func rmssd(_ intervals: [Int]) -> Double? {
        guard intervals.count >= minimumRRIntervals else { return nil }
        let squaredDifferences = zip(intervals, intervals.dropFirst()).map { pair -> Double in
            let delta = Double(pair.1 - pair.0)
            return delta * delta
        }
        guard !squaredDifferences.isEmpty else { return nil }
        let value = sqrt(squaredDifferences.reduce(0, +) / Double(squaredDifferences.count))
        return value.isFinite ? value : nil
    }

    private static func calculateRHR(
        from records: [HistoricalRRPacketRecord]
    ) -> (value: Double?, coverage: Double, samples: Int) {
        let samples = records.compactMap { record -> (time: TimeInterval, bpm: Int)? in
            guard let time = record.physiologicalTimestamp?.timeIntervalSince1970,
                  let bpm = record.heartRateBpm, (30...220).contains(bpm) else { return nil }
            return (time, bpm)
        }
        guard samples.count >= Int(rhrWindowSeconds * minimumRHRWindowCoverage) else {
            return (nil, 0, samples.count)
        }

        var bestMean: Double?
        var bestCoverage = 0.0
        var right = 0
        var sum = 0
        for left in samples.indices {
            let end = samples[left].time + rhrWindowSeconds
            while right < samples.count && samples[right].time < end {
                sum += samples[right].bpm
                right += 1
            }
            let count = right - left
            let coverage = min(1.0, Double(count) / rhrWindowSeconds)
            if coverage >= minimumRHRWindowCoverage {
                let mean = Double(sum) / Double(count)
                if bestMean == nil || mean < bestMean! {
                    bestMean = mean
                    bestCoverage = coverage
                }
            }
            sum -= samples[left].bpm
        }
        return (bestMean, bestCoverage, samples.count)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func median(_ values: [Int]) -> Double? {
        median(values.map(Double.init))
    }
}
