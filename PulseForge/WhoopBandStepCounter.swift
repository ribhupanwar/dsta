import Foundation

/// Experimental daily step estimate from the WHOOP 5.0 Gen5 v18 on-band
/// cumulative motion counter. OpenStrap maps the same field in CRC-valid
/// historical v18 captures; interpreting every counter increment as a step
/// still needs ground-truth validation on this device/firmware. Counter deltas
/// are wrap-aware and fail closed on implausible resets/jumps. No phone or
/// Apple Health step source is used here.
struct WhoopBandStepCounter {
    struct Sample: Codable, Equatable {
        let timestamp: Date
        let counter: Int
    }

    struct Snapshot: Codable {
        let latestSample: Sample?
        let dailyTotals: [String: Int]
        let coverageStarts: [String: Date]
        let droppedBoundaries: Int
    }

    private(set) var latestSample: Sample?
    private(set) var dailyTotals: [String: Int] = [:]
    private(set) var coverageStarts: [String: Date] = [:]
    private(set) var droppedBoundaries = 0

    static let counterModulus = 65_536
    static let maximumStepsPerSecond = 5
    static let maximumGapSeconds = 3_600
    static let retentionDays = 35

    mutating func ingest(_ sample: Sample, calendar: Calendar = .current) {
        guard (0..<Self.counterModulus).contains(sample.counter) else { return }

        guard let previous = latestSample else {
            latestSample = sample
            let key = Self.dayKey(sample.timestamp, calendar: calendar)
            coverageStarts[key] = sample.timestamp
            return
        }

        // Historical sync can replay frames. Reject older samples and exact
        // duplicates, but accept a higher cumulative counter at the same
        // second: Type-47 physiological timestamps have one-second resolution.
        guard sample.timestamp >= previous.timestamp else { return }
        if sample.timestamp == previous.timestamp {
            guard sample.counter > previous.counter else { return }
            let sameSecondDelta = sample.counter - previous.counter
            guard sameSecondDelta <= Self.maximumStepsPerSecond else {
                droppedBoundaries += 1
                return
            }
            let key = Self.dayKey(sample.timestamp, calendar: calendar)
            dailyTotals[key, default: 0] += sameSecondDelta
            latestSample = sample
            return
        }

        let elapsed = max(1, Int(sample.timestamp.timeIntervalSince(previous.timestamp).rounded(.down)))
        let key = Self.dayKey(sample.timestamp, calendar: calendar)
        let dayStart = calendar.startOfDay(for: sample.timestamp)
        if coverageStarts[key] == nil {
            // A sample pair straddling midnight gives us a boundary baseline
            // for the new local day; otherwise this day is only partially seen.
            coverageStarts[key] = previous.timestamp < dayStart ? dayStart : previous.timestamp
        }
        if dailyTotals[key] == nil { dailyTotals[key] = 0 }

        var delta = sample.counter - previous.counter
        if delta < 0 { delta += Self.counterModulus } // genuine u16 wrap candidate
        let budget = min(elapsed, Self.maximumGapSeconds) * Self.maximumStepsPerSecond

        if delta <= budget {
            dailyTotals[key, default: 0] += delta
        } else {
            // A reboot/reset is indistinguishable from a u16 wrap by sign
            // alone. Reject the whole implausible boundary, then re-anchor.
            droppedBoundaries += 1
        }

        latestSample = sample
        prune(keepingSince: calendar.date(byAdding: .day, value: -Self.retentionDays, to: sample.timestamp) ?? sample.timestamp, calendar: calendar)
    }

    mutating func rebuild(from samples: [Sample], calendar: Calendar = .current) {
        self = WhoopBandStepCounter()
        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            ingest(sample, calendar: calendar)
        }
    }

    func steps(for date: Date = Date(), calendar: Calendar = .current) -> Int? {
        dailyTotals[Self.dayKey(date, calendar: calendar)]
    }

    func sourceStatus(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let key = Self.dayKey(date, calendar: calendar)
        guard dailyTotals[key] != nil, let coverage = coverageStarts[key] else {
            return "WHOOP 5.0 band · waiting for step history"
        }
        let start = calendar.startOfDay(for: date)
        let complete = coverage <= start.addingTimeInterval(60)
        if complete {
            return "WHOOP 5.0 band · experimental motion counter · day boundary covered"
        }
        return "WHOOP 5.0 band · experimental motion counter · partial history since \(coverage.formatted(date: .omitted, time: .shortened))"
    }

    func snapshot() -> Snapshot {
        Snapshot(
            latestSample: latestSample,
            dailyTotals: dailyTotals,
            coverageStarts: coverageStarts,
            droppedBoundaries: droppedBoundaries
        )
    }

    mutating func restore(_ snapshot: Snapshot) {
        latestSample = snapshot.latestSample
        dailyTotals = snapshot.dailyTotals
        coverageStarts = snapshot.coverageStarts
        droppedBoundaries = max(0, snapshot.droppedBoundaries)
    }

    private mutating func prune(keepingSince cutoff: Date, calendar: Calendar) {
        let keys = Set(dailyTotals.keys).union(coverageStarts.keys)
        for key in keys {
            guard let date = Self.date(from: key, calendar: calendar), date < calendar.startOfDay(for: cutoff) else { continue }
            dailyTotals.removeValue(forKey: key)
            coverageStarts.removeValue(forKey: key)
        }
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func date(from key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
