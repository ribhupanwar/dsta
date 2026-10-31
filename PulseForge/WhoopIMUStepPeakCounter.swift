import Foundation

/// Experimental wrist-IMU peak counter. This is a comparison signal, not a
/// validated WHOOP-equivalent step total. Tune only against labelled walks/runs.
enum WhoopIMUStepPeakCounter {
    static func estimate(
        samples: [WhoopIMUSample],
        thresholdG: Double = 0.10,
        minimumInterval: TimeInterval = 0.30,
        smoothingRadius: Int = 12
    ) -> Int {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= 5 else { return 0 }
        let magnitude = ordered.map {
            sqrt($0.accelerationXG * $0.accelerationXG +
                 $0.accelerationYG * $0.accelerationYG +
                 $0.accelerationZG * $0.accelerationZG)
        }
        var signal = [Double](repeating: 0, count: magnitude.count)
        for index in magnitude.indices {
            let lower = max(0, index - smoothingRadius)
            let upper = min(magnitude.count - 1, index + smoothingRadius)
            let mean = magnitude[lower...upper].reduce(0, +) / Double(upper - lower + 1)
            signal[index] = magnitude[index] - mean
        }

        var peaks = 0
        var lastPeakTime: Date?
        for index in 1..<(signal.count - 1) {
            guard signal[index] >= thresholdG,
                  signal[index] >= signal[index - 1],
                  signal[index] > signal[index + 1] else { continue }
            let timestamp = ordered[index].timestamp
            if let lastPeakTime,
               timestamp.timeIntervalSince(lastPeakTime) < minimumInterval {
                continue
            }
            peaks += 1
            lastPeakTime = timestamp
        }
        return peaks
    }
}
