import Foundation

/// WHOOP 5.0 Type-47 / historical v18 step-counter evidence.
///
/// Offsets are from the independently documented NOOP v18 layout. They are
/// deliberately isolated from Type-40 realtime frames: a 32-byte live packet
/// cannot contain these fields. The decoder does not claim that motion ticks
/// equal the official WHOOP app's aggregated steps.
struct Whoop5StepSample: Equatable {
    enum CounterSource: String {
        case selectedHardwareCounter
        case softwareOverrideCounter
    }

    let timestamp: Date
    let selectedCounter: UInt16       // @57, the currently selected cumulative counter
    let cadenceRaw: UInt8             // @59, retained for diagnostics only
    let hardwareCounter: UInt16?      // @61, meaningful when override is active
    let activityClass: UInt8?         // @63: 0 still, 1 walk, 2 run; other values unknown
    let softwareOverrideActive: Bool // @64 bit 0x10
    var source: CounterSource {
        softwareOverrideActive ? .softwareOverrideCounter : .selectedHardwareCounter
    }
}

enum Whoop5StepFrameDecoder {
    enum DecodeError: Error, Equatable {
        case invalidHeader
        case wrongRecordType(Int)
        case unsupportedVersion(Int)
        case truncatedFrame(Int)
    }

    /// Decode a complete CRC-validated Type-47 frame. CRC validation belongs
    /// to the outer WHOOP frame assembler and must happen before this method.
    static func decodeHistoricalV18(_ frame: [UInt8], timestamp: Date) throws -> Whoop5StepSample {
        guard frame.count >= 65, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw frame.count < 65 ? DecodeError.truncatedFrame(frame.count) : DecodeError.invalidHeader
        }
        guard frame[8] == 47 else { throw DecodeError.wrongRecordType(Int(frame[8])) }
        guard frame[9] == 18 else { throw DecodeError.unsupportedVersion(Int(frame[9])) }

        let selected = UInt16(frame[57]) | (UInt16(frame[58]) << 8)
        let hardware = UInt16(frame[61]) | (UInt16(frame[62]) << 8)
        let classByte = frame[63]
        let overrideActive = (frame[64] & 0x10) != 0

        return Whoop5StepSample(
            timestamp: timestamp,
            selectedCounter: selected,
            cadenceRaw: frame[59],
            hardwareCounter: overrideActive ? hardware : nil,
            activityClass: classByte <= 2 ? classByte : nil,
            softwareOverrideActive: overrideActive
        )
    }
}

struct Whoop5StepCountResult: Equatable {
    let acceptedTicks: Int
    let rejectedStillOrUnknownTicks: Int
    let rejectedImplausibleTicks: Int
    let rejectedSourceSwitches: Int
    let rejectedSleepTicks: Int
    let samplePairs: Int
}

/// Converts cumulative 16-bit motion-counter changes into auditable raw ticks.
/// These are NOT calibrated steps. Callers must compare against a trusted
/// daily step total before choosing a ticks-per-step conversion.
enum Whoop5StepLedger {
    static func count(
        samples: [Whoop5StepSample],
        confirmedAsleepIntervals: [DateInterval] = [],
        calendar: Calendar = .current,
        maximumTicksPerSecond: Double = 4,
        maximumDeltaPerPair: Int = 512
    ) -> Whoop5StepCountResult {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count > 1 else {
            return Whoop5StepCountResult(acceptedTicks: 0, rejectedStillOrUnknownTicks: 0,
                                         rejectedImplausibleTicks: 0, rejectedSourceSwitches: 0,
                                         rejectedSleepTicks: 0, samplePairs: 0)
        }

        var accepted = 0
        var rejectedActivity = 0
        var rejectedImplausible = 0
        var rejectedSourceSwitch = 0
        var rejectedSleep = 0
        var pairs = 0

        for (previous, current) in zip(ordered, ordered.dropFirst()) {
            pairs += 1
            let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
            guard elapsed > 0, calendar.isDate(previous.timestamp, inSameDayAs: current.timestamp) else {
                continue // never bridge duplicate timestamps or calendar-day boundaries
            }
            guard previous.source == current.source else {
                rejectedSourceSwitch += 1
                continue // never subtract counters from different source modes
            }

            // UInt16 modular subtraction handles a genuine 65535 -> 0 rollover.
            let delta = Int(current.selectedCounter &- previous.selectedCounter)
            guard delta > 0, delta < maximumDeltaPerPair,
                  Double(delta) / elapsed <= maximumTicksPerSecond else {
                if delta > 0 { rejectedImplausible += delta }
                continue
            }

            // If activity labels are present, count only increments ending in
            // a known walk/run class. If the entire archive lacks labels, use
            // the documented legacy counter-only fallback.
            let anyActivityLabels = ordered.contains { $0.activityClass != nil }
            if anyActivityLabels && current.activityClass != 1 && current.activityClass != 2 {
                rejectedActivity += delta
                continue
            }

            // Only caller-supplied confirmed-asleep intervals are filtered.
            // Wake segments must not be included in this list.
            let midpoint = previous.timestamp.addingTimeInterval(elapsed / 2)
            if confirmedAsleepIntervals.contains(where: { $0.contains(midpoint) }) {
                rejectedSleep += delta
                continue
            }
            accepted += delta
        }

        return Whoop5StepCountResult(
            acceptedTicks: accepted,
            rejectedStillOrUnknownTicks: rejectedActivity,
            rejectedImplausibleTicks: rejectedImplausible,
            rejectedSourceSwitches: rejectedSourceSwitch,
            rejectedSleepTicks: rejectedSleep,
            samplePairs: pairs
        )
    }
}
