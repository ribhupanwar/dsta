import Foundation

/// Transparent, local-only healthspan calculations. This is not a medical device
/// and intentionally does not claim to reproduce WHOOP's proprietary model.
public struct HealthspanDailySample: Sendable {
    public let date: Date
    public let sleepHours: Double?
    public let sleepConsistencyPercent: Double?
    public let steps: Int?
    public let zone1To3Minutes: Double?
    public let zone4To5Minutes: Double?
    public let strengthMinutes: Double?
    public let vo2Max: Double?
    public let restingHeartRate: Double?
    public let leanBodyMassPercent: Double?

    public init(date: Date, sleepHours: Double? = nil,
                sleepConsistencyPercent: Double? = nil, steps: Int? = nil,
                zone1To3Minutes: Double? = nil, zone4To5Minutes: Double? = nil,
                strengthMinutes: Double? = nil, vo2Max: Double? = nil,
                restingHeartRate: Double? = nil, leanBodyMassPercent: Double? = nil) {
        self.date = date
        self.sleepHours = sleepHours
        self.sleepConsistencyPercent = sleepConsistencyPercent
        self.steps = steps
        self.zone1To3Minutes = zone1To3Minutes
        self.zone4To5Minutes = zone4To5Minutes
        self.strengthMinutes = strengthMinutes
        self.vo2Max = vo2Max
        self.restingHeartRate = restingHeartRate
        self.leanBodyMassPercent = leanBodyMassPercent
    }
}

public struct HealthspanContributor: Sendable {
    public let name: String
    public let score: Double
    public let sampleCount: Int
}

public struct HealthspanSnapshot: Sendable {
    /// 0...100 transparent wellness index; deliberately not labelled biological age.
    public let index: Double?
    public let coverage: Double
    public let contributors: [HealthspanContributor]
    public let sampleDays: Int
    public let windowDays: Int
}

public struct VO2EstimateCandidate: Sendable {
    public enum Source: String, Sendable { case healthKit, submaximalRun, racePerformance, laboratory }
    public let value: Double
    public let source: Source
    public let confidence: Double
    public let observedAt: Date

    public init(value: Double, source: Source, confidence: Double, observedAt: Date) {
        self.value = value
        self.source = source
        self.confidence = confidence
        self.observedAt = observedAt
    }
}

public struct VO2EstimateResult: Sendable {
    public let value: Double?
    public let confidence: Double
    public let sourceCount: Int
    public let spread: Double?
}

/// Effective-age conversion from a validated all-cause-mortality hazard ratio.
/// Age delta = ln(HR) / ln(1.10). The caller must supply a published, applicable
/// hazard ratio; no coefficients are fabricated by this engine.
public enum EffectiveAgeMath {
    public static func ageDeltaYears(validatedHazardRatio: Double,
                                     annualAgeRiskMultiplier: Double = 1.10) -> Double? {
        guard validatedHazardRatio.isFinite, validatedHazardRatio > 0,
              annualAgeRiskMultiplier.isFinite, annualAgeRiskMultiplier > 1 else { return nil }
        return log(validatedHazardRatio) / log(annualAgeRiskMultiplier)
    }
}

public enum PulseForgeHealthspanEngine {
    /// WHOOP-inspired 9-input coverage model. Missing data is excluded, never treated as zero.
    public static func healthspan(samples: [HealthspanDailySample],
                                  endingAt endDate: Date,
                                  windowDays: Int = 180) -> HealthspanSnapshot {
        let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -windowDays, to: endDate) ?? endDate
        let rows = samples.filter { $0.date >= start && $0.date <= endDate }
        guard !rows.isEmpty else {
            return HealthspanSnapshot(index: nil, coverage: 0, contributors: [],
                                      sampleDays: 0, windowDays: windowDays)
        }

        func mean(_ values: [Double]) -> Double? {
            let valid = values.filter { $0.isFinite && $0 >= 0 }
            return valid.isEmpty ? nil : valid.reduce(0, +) / Double(valid.count)
        }
        func contributor(_ name: String, _ values: [Double], _ transform: (Double) -> Double) -> HealthspanContributor? {
            guard let average = mean(values) else { return nil }
            return HealthspanContributor(name: name, score: min(100, max(0, transform(average))),
                                         sampleCount: values.filter { $0.isFinite && $0 >= 0 }.count)
        }

        var parts: [HealthspanContributor] = []
        if let c = contributor("Sleep duration", rows.compactMap { $0.sleepHours }, { v in
            v < 7 ? v / 7 * 70 : (v <= 9 ? 100 : max(70, 100 - (v - 9) * 10))
        }) { parts.append(c) }
        if let c = contributor("Sleep consistency", rows.compactMap { $0.sleepConsistencyPercent }, { min(100, $0) }) { parts.append(c) }
        if let c = contributor("Daily steps", rows.compactMap { $0.steps.map(Double.init) }, { min(100, $0 / 8000 * 100) }) { parts.append(c) }
        if let c = contributor("Zone 1–3 activity", rows.compactMap { $0.zone1To3Minutes }, { min(100, ($0 * 7) / 100 * 100) }) { parts.append(c) }
        if let c = contributor("Zone 4–5 activity", rows.compactMap { $0.zone4To5Minutes }, { min(100, ($0 * 7) / 10 * 100) }) { parts.append(c) }
        if let c = contributor("Strength activity", rows.compactMap { $0.strengthMinutes }, { min(100, ($0 * 7) / 40 * 100) }) { parts.append(c) }
        if let c = contributor("VO2 Max", rows.compactMap { $0.vo2Max }, { min(100, $0 / 45 * 100) }) { parts.append(c) }
        if let c = contributor("Resting heart rate", rows.compactMap { $0.restingHeartRate }, { max(0, min(100, (90 - $0) / 30 * 100)) }) { parts.append(c) }
        if let c = contributor("Lean body mass", rows.compactMap { $0.leanBodyMassPercent }, { min(100, $0 / 80 * 100) }) { parts.append(c) }

        let coverage = Double(parts.count) / 9.0
        let index = parts.isEmpty ? nil : parts.map(\.score).reduce(0, +) / Double(parts.count)
        return HealthspanSnapshot(index: index, coverage: coverage, contributors: parts,
                                  sampleDays: rows.count, windowDays: windowDays)
    }

    /// Robust fusion: downweights stale/low-confidence estimates and rejects implausible
    /// values. A wide source disagreement lowers confidence instead of hiding the spread.
    public static func fuseVO2(candidates: [VO2EstimateCandidate], asOf date: Date) -> VO2EstimateResult {
        let eligible = candidates.filter {
            $0.value.isFinite && (15...90).contains($0.value) &&
            $0.confidence.isFinite && $0.confidence > 0 && $0.confidence <= 1 &&
            $0.observedAt <= date &&
            date.timeIntervalSince($0.observedAt) <= 60 * 24 * 60 * 60
        }
        guard !eligible.isEmpty else {
            return VO2EstimateResult(value: nil, confidence: 0, sourceCount: 0, spread: nil)
        }
        let weighted = eligible.map { candidate -> (Double, Double) in
            let ageDays = max(0, date.timeIntervalSince(candidate.observedAt) / 86400)
            let freshness = exp(-ageDays / 45)
            let sourceWeight = candidate.source == .laboratory ? 1.0 : 1.0
            return (candidate.value, candidate.confidence * freshness * sourceWeight)
        }
        let totalWeight = weighted.map(\.1).reduce(0, +)
        guard totalWeight > 0 else {
            return VO2EstimateResult(value: nil, confidence: 0, sourceCount: 0, spread: nil)
        }
        let estimate = weighted.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight
        let values = eligible.map(\.value)
        let spread = (values.max() ?? estimate) - (values.min() ?? estimate)
        let meanConfidence = min(1, totalWeight / Double(eligible.count))
        let agreementPenalty = max(0.35, 1 - spread / 20)
        return VO2EstimateResult(value: estimate, confidence: meanConfidence * agreementPenalty,
                                 sourceCount: eligible.count, spread: spread)
    }
}
