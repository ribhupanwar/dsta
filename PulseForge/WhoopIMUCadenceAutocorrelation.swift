import Foundation

/// Experimental gait-periodicity estimator using autocorrelation of the
/// gravity-removed acceleration magnitude. Output is a periodic-cycle estimate,
/// not a validated footfall count.
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

        var correlations = [Double](repeating: 0, count: maxLag + 1)
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
            if denominator > 0 {
                correlations[lag] = cross / denominator
            }
        }

        // Select the first credible local autocorrelation maximum (shortest
        // repeating period), rather than a stronger integer-multiple lag.
        // This avoids reporting half cadence when a clean gait waveform also
        // correlates strongly at two strides/steps.
        var selectedLag: Int?
        for lag in (minLag + 1)..<maxLag {
            let value = correlations[lag]
            if value >= 0.25 &&
               value >= correlations[lag - 1] &&
               value > correlations[lag + 1] {
                selectedLag = lag
                break
            }
        }
        guard let lag = selectedLag else { return 0 }
        let cadenceHz = sampleRateHz / Double(lag)
        guard cadenceHz >= minimumCadenceHz, cadenceHz <= maximumCadenceHz else { return 0 }
        return max(0, Int((duration * cadenceHz).rounded()))
    }
}
