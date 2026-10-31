import Foundation

/// Experimental gyroscope swing-peak counter. Kept independent from the
/// acceleration-magnitude detector so the user can compare sensor modalities.
/// This is not a validated step counter; peak-to-step mapping needs real walks.
enum WhoopIMUGyroStepCounter {
    static func estimate(
        samples: [WhoopIMUSample],
        thresholdDPS: Double = 6.0,
        minimumInterval: TimeInterval = 0.30,
        smoothingRadius: Int = 12
    ) -> Int {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= 5 else { return 0 }

        let magnitude = ordered.map {
            sqrt($0.rotationXDPS * $0.rotationXDPS +
                 $0.rotationYDPS * $0.rotationYDPS +
                 $0.rotationZDPS * $0.rotationZDPS)
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
            guard signal[index] >= thresholdDPS,
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
