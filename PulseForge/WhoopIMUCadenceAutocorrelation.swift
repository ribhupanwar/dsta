import Foundation

/// Experimental gait-periodicity estimator using autocorrelation of the
/// gravity-removed acceleration magnitude. Unlike local peak counting, it
/// estimates a dominant repeating interval over the complete window.
/// Output is a periodic-cycle estimate, not validated footfall count.
enum WhoopIMUCadenceAutocorrelation {
    static func estimate(
        samples: [WhoopIMUSample],
        sampleRateHz: Double = 100,
        minimumCadenceHz: Double = 0.65,
        maximumCadenceHz: Double = 2.8
    ) -> Int {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= 200,
              let first = ordered.first, let last = ordered.last else { return 0 }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration >= 1.5 else { return 0 }

        let raw = ordered.map {
            sqrt($0.accelerationXG * $0.accelerationXG +
                 $0.accelerationYG * $0.accelerationYG +
                 $0.accelerationZG * $0.accelerationZG)
        }
        let mean = raw.reduce(0, +) / Double(raw.count)
        let signal = raw.map { $0 - mean }
        let energy = signal.reduce(0) { $0 + $1 * $1 }
        guard energy / Double(signal.count) > 0.00005 else { return 0 }

        let minLag = max(2, Int((sampleRateHz / maximumCadenceHz).rounded()))
        let maxLag = min(signal.count / 2, Int((sampleRateHz / minimumCadenceHz).rounded()))
        guard minLag <= maxLag else { return 0 }

        var bestLag: Int?
        var bestCorrelation = -Double.infinity
        for lag in minLag...maxLag {
            var cross = 0.0
            var leftEnergy = 0.0
            var rightEnergy = 0.0
            for index in 0..<(signal.count - lag) {
                let a = signal[index]
                let b = signal[index + lag]
                cross += a * b
                leftEnergy += a * a
                rightEnergy += b * b
            }
            let denominator = sqrt(leftEnergy * rightEnergy)
            guard denominator > 0 else { continue }
            let correlation = cross / denominator
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        // Reject weakly periodic signals: random arm movement should not
        // become a confident cadence estimate.
        guard let lag = bestLag, bestCorrelation >= 0.25 else { return 0 }
        let cadenceHz = sampleRateHz / Double(lag)
        guard cadenceHz >= minimumCadenceHz, cadenceHz <= maximumCadenceHz else { return 0 }
        return max(0, Int((duration * cadenceHz).rounded()))
    }
}
