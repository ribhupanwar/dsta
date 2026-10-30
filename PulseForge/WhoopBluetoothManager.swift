import Foundation
import CoreBluetooth
import Combine
import HealthKit

struct DiscoveredWearable: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    let advertisedServices: [String]
    let serviceDataEntries: [String]
    let solicitedServices: [String]
    let overflowServices: [String]
    let manufacturerDataByteCount: Int?
    let transmitPower: Int?
    let isConnectable: Bool?
    var id: UUID { peripheral.identifier }
}

struct LiveHeartRateSample: Identifiable, Codable {
    let timestamp: Date
    let bpm: Int
    var id: TimeInterval { timestamp.timeIntervalSince1970 }
}


struct PersistedRRIntervalSample: Identifiable, Codable {
    let timestamp: Date
    let intervalMilliseconds: Int
    var id: String { "\(timestamp.timeIntervalSince1970)-\(intervalMilliseconds)" }
}

struct WhoopIMUSample: Identifiable, Codable {
    let timestamp: Date
    let accelerationXG: Double
    let accelerationYG: Double
    let accelerationZG: Double
    let rotationXDPS: Double
    let rotationYDPS: Double
    let rotationZDPS: Double
    var id: TimeInterval { timestamp.timeIntervalSince1970 }
}

struct WorkoutSessionRecord: Identifiable, Codable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: TimeInterval
    let wasAutomatic: Bool
    let wasInterrupted: Bool
    let heartRateSamples: [LiveHeartRateSample]
    let imuSamples: [WhoopIMUSample]

    init(startedAt: Date, durationSeconds: TimeInterval, wasAutomatic: Bool,
         wasInterrupted: Bool, heartRateSamples: [LiveHeartRateSample],
         imuSamples: [WhoopIMUSample]) {
        self.id = UUID()
        self.startedAt = startedAt
        self.durationSeconds = max(0, durationSeconds)
        self.wasAutomatic = wasAutomatic
        self.wasInterrupted = wasInterrupted
        self.heartRateSamples = heartRateSamples
        self.imuSamples = imuSamples
    }
}

final class WhoopBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var devices: [DiscoveredWearable] = []
    @Published private(set) var statusText = "Bluetooth is starting"
    @Published private(set) var connectedName: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var discoveredProfile: [String] = []
    @Published private(set) var lastBLEEvent = "No BLE data received yet"
    @Published private(set) var liveHeartRateBPM: Int?
    @Published private(set) var isStandardHeartRateNotifying = false
    @Published private(set) var lastHeartRateAt: Date?
    @Published private(set) var whoopProtocolDiagnostics = "No WHOOP 5.0 protocol frame decoded yet"
    @Published private(set) var whoopRealtimePacketCount = 0
    /// Latest RR intervals from the realtime type-40 stream only.
    @Published private(set) var whoopRRIntervalsMilliseconds: [Int] = []
    @Published private(set) var whoopStandardRRIntervalsMilliseconds: [Int] = []
    @Published private(set) var whoopStandardRRLastUpdatedAt: Date?
    /// Recent raw 2A37 Heart Rate Measurement notifications, captured before parsing.
    @Published private(set) var whoopStandardHeartRateRawFrameHistory: [String] = []
    /// Recent CRC-valid Type-40 frames, retained verbatim for independent layout verification.
    @Published private(set) var whoopRealtimeRRRawFrameHistory: [String] = []
    /// Candidate fields extracted from NOOP-derived Type-40 offsets; never treated as HR or milliseconds.
    @Published private(set) var whoopRealtimeCandidateRRWords: [Int] = []
    @Published private(set) var whoopRealtimeCandidateByteAt16: Int?
    @Published private(set) var whoopRealtimeCandidateStatus = "No Type-40 candidate frame captured"
    /// Rolling realtime RR window for live diagnostics; never used as overnight HRV.
    @Published private(set) var whoopRRWindowMilliseconds: [Int] = []
    /// Short-window RMSSD from live type-40 RR only; never overnight HRV.
    @Published private(set) var whoopLiveRMSSDMilliseconds: Double?
    /// Historical type-47/v18 intervals are kept separate from the live stream.
    @Published private(set) var whoopHistoricalRRIntervalsMilliseconds: [Int] = []
    @Published private(set) var whoopHistoricalRRLastUpdatedAt: Date?
    @Published private(set) var whoopHistoricalHeartRateBPM: Int?
    @Published private(set) var whoopHistoricalTimestampLastUpdatedAt: Date?
    @Published private(set) var whoopHistoricalRRSource = "No historical WHOOP RR intervals decoded yet"
    @Published private(set) var whoopHistorySyncStatus = "Waiting for WHOOP 5 historical sync request"
    @Published private(set) var whoopRRLastUpdatedAt: Date?
    @Published private(set) var whoopRRSource = "No WHOOP RR intervals decoded yet"
    @Published private(set) var whoopCommandResponseCount = 0
    @Published private(set) var whoopLastPacketType = "None"
    @Published private(set) var whoopBatteryPercent: Double?
    @Published private(set) var whoopBatteryLastUpdatedAt: Date?
    @Published private(set) var whoopEventPacketCount = 0
    @Published private(set) var whoopLastEventID: Int?
    @Published private(set) var whoopLastEventFrameHex = "none"
    /// Gen5 Type-48 event evidence, separated by the notifying GATT characteristic.
    @Published private(set) var whoopEventCountsByChannel: [String: Int] = [:]
    @Published private(set) var whoopEvent33Count = 0
    @Published private(set) var whoopEvent34Count = 0
    @Published private(set) var whoopLastEventChannel = "none"
    @Published private(set) var whoopLastEvent33FrameHex = "none"
    @Published private(set) var whoopLastEvent33At: Date?
    @Published private(set) var whoopLastEvent34FrameHex = "none"
    @Published private(set) var whoopLastEvent34At: Date?
    /// Puffin event transports are retained independently until their payload schema is verified.
    @Published private(set) var whoopPuffinEventCountsByChannel: [String: Int] = [:]
    @Published private(set) var whoopPuffinEventFrameHistory: [String] = []
    private var whoopPuffinEventTypeCounts: [Int: Int] = [:]
    @Published private(set) var whoopEventProbeStatus = "Controlled Event 33/34 probe not run"
    private var whoopEventProbeActive = false
    private var whoopEventProbeOffSequence: UInt8?
    private var whoopEventProbeOnSequence: UInt8?
    private var whoopEventProbeStart33Count = 0
    private var whoopEventProbeStart34Count = 0
    private var whoopEventProbeStartedAt: Date?
    private var whoopEventProbeRearmWorkItem: DispatchWorkItem?
    private var whoopEventProbeFinishWorkItem: DispatchWorkItem?
    /// Notification-level and CRC-valid packet-level evidence, keyed by GATT channel.
    private var vendorNotificationCountsByChannel: [String: Int] = [:]
    private var vendorNotificationBytesByChannel: [String: Int] = [:]
    private var vendorNotificationLastAtByChannel: [String: Date] = [:]
    private var whoopPacketTypeCountsByChannel: [String: [Int: Int]] = [:]
    private var whoopLastPacketTypeByChannel: [String: Int] = [:]
    private var whoopRejectedFrameCountsByChannel: [String: Int] = [:]
    /// True after a CRC-valid Type-40 frame arrives; its inner HR/RR fields remain unverified.
    private var whoop5Type40FrameObserved = false
    @Published private(set) var whoopConnectionGeneration = 0
    @Published private(set) var whoopSessionPhase = "Disconnected"
    @Published private(set) var heartRateUpdateCount = 0
    @Published private(set) var liveHeartRateSamples: [LiveHeartRateSample] = []
    @Published private(set) var dashboardHeartRateHistory: [LiveHeartRateSample] = []
    @Published private(set) var dashboardRRHistory: [PersistedRRIntervalSample] = []
    /// Standard Bluetooth 2A37 RR archive, kept separate from WHOOP Type-40 RR.
    @Published private(set) var dashboardStandardRRHistory: [PersistedRRIntervalSample] = []
    @Published private(set) var workoutHeartRateSamples: [LiveHeartRateSample] = []
    @Published private(set) var workoutStartedAt: Date?
    @Published private(set) var workoutIsRecording = false
    @Published private(set) var workoutRecordingIsAutomatic = false
    @Published private(set) var workoutDetectionStatus = "Waiting for live HR baseline"
    @Published private(set) var lastWorkoutDurationSeconds: TimeInterval?
    @Published private(set) var lastWorkoutStartedAt: Date?
    @Published private(set) var lastWorkoutWasAutomatic: Bool?
    @Published private(set) var lastWorkoutWasInterrupted = false
    @Published private(set) var workoutHistory: [WorkoutSessionRecord] = []
    @Published private(set) var healthKitExportStatus = "Health export awaits Apple Health write permission"
    private let healthKitStore = HKHealthStore()
    private var workoutDetectionSamples: [LiveHeartRateSample] = []
    private var workoutDetectionCandidateSince: Date?
    private var workoutDetectionCandidateBaselineBPM: Int?
    private var workoutRecoverySince: Date?
    private var workoutSessionBaselineBPM: Int?
    @Published private(set) var whoopIMUFrameCount = 0
    @Published private(set) var whoopHistoricalIMUStreamPacketCount = 0
    @Published private(set) var whoopLastHistoricalIMUStreamRawFrameHex = "none"
    @Published private(set) var whoopIMUSampleCount = 0
    @Published private(set) var whoopIMULastFrameAt: Date?
    @Published private(set) var whoopIMUStatus = "Waiting for WHOOP motion stream"
    @Published private(set) var whoopIMULastRawFrameHex = "none"
    private var whoopIMURawFrameHistory: [String] = []
    /// UI-facing IMU snapshot is published at most once per second. Raw decoded
    /// samples continue to be retained at full rate in the private buffer.
    @Published private(set) var liveWhoopIMUSamples: [WhoopIMUSample] = []
    private var liveWhoopIMUSampleBuffer: [WhoopIMUSample] = []
    private var lastLiveIMUSnapshotPublishedAt: Date?
    /// Persisted decoded WHOOP motion history; never treated as a live stream.
    @Published private(set) var whoopIMUHistorySamples: [WhoopIMUSample] = []
    @Published private(set) var workoutWhoopIMUSamples: [WhoopIMUSample] = []
    private var lastWhoopIMUPersistedSampleCount = 0
    private var lastDashboardIMUPersistedSampleCount = 0

    private enum DashboardHistoryKey {
        static let heartRate = "pulseforge.history.liveHeartRate.v1"
        static let historicalRR = "pulseforge.history.historicalRR.v1"
        static let historicalHR = "pulseforge.history.historicalHR.v1"
        static let historicalAt = "pulseforge.history.historicalAt.v1"
        static let imuSamples = "pulseforge.history.whoopIMUSamples.v1"
        static let rrSamples = "pulseforge.history.realtimeRRSamples.v1"
        static let standardRRSamples = "pulseforge.history.standardRRSamples.v1"
    }

    private var historicalRRArchiveURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PulseForge", isDirectory: true)
            .appendingPathComponent("historical-whoop-rr-v1.json")
    }

    /// Flush queued CRC-valid historical frames to durable storage.
    /// The queue is cleared only after the atomic archive write succeeds.
    @discardableResult
    private func flushHistoricalRRArchive() -> Bool {
        guard !pendingHistoricalRRArchiveRecords.isEmpty else { return true }
        guard let archiveURL = historicalRRArchiveURL else {
            whoopHistoricalRRSource = "Historical RR archive unavailable · \(pendingHistoricalRRArchiveRecords.count) frames remain queued"
            return false
        }
        do {
            let count = try HistoricalRRPacketArchive.append(
                contentsOf: pendingHistoricalRRArchiveRecords,
                to: archiveURL
            )
            let flushed = pendingHistoricalRRArchiveRecords.count
            pendingHistoricalRRArchiveRecords.removeAll(keepingCapacity: true)
            whoopHistoricalRRSource = "Historical RR archive durably flushed · \(flushed) frames · \(count) retained"
            return true
        } catch {
            whoopHistoricalRRSource = "Historical RR archive write failed · \(error.localizedDescription) · \(pendingHistoricalRRArchiveRecords.count) frames retained in memory"
            return false
        }
    }

    private func persistDashboardIMUHistoryIfNeeded(force: Bool = false) {
        guard force || whoopIMUHistorySamples.count - lastDashboardIMUPersistedSampleCount >= 500 else { return }
        let retained = Array(whoopIMUHistorySamples.suffix(20_000))
        guard let data = try? JSONEncoder().encode(retained) else { return }
        UserDefaults.standard.set(data, forKey: DashboardHistoryKey.imuSamples)
        lastDashboardIMUPersistedSampleCount = whoopIMUHistorySamples.count
    }

    /// Keep 100 Hz sensor ingestion independent from SwiftUI observation.
    /// The workout and archival paths still receive every decoded sample; only
    /// the dashboard snapshot is rate-limited to avoid invalidating scroll views
    /// for every BLE notification.
    private func appendLiveIMUSamples(_ samples: [WhoopIMUSample], now: Date = Date()) {
        guard !samples.isEmpty else { return }
        liveWhoopIMUSampleBuffer.append(contentsOf: samples)
        if liveWhoopIMUSampleBuffer.count > 2_000 {
            liveWhoopIMUSampleBuffer.removeFirst(liveWhoopIMUSampleBuffer.count - 2_000)
        }
        if lastLiveIMUSnapshotPublishedAt == nil ||
            now.timeIntervalSince(lastLiveIMUSnapshotPublishedAt!) >= 1.0 {
            liveWhoopIMUSamples = liveWhoopIMUSampleBuffer
            lastLiveIMUSnapshotPublishedAt = now
        }
    }

    private func appendVerifiedIMUHistory(_ samples: [WhoopIMUSample]) {
        guard !samples.isEmpty else { return }
        whoopIMUHistorySamples.append(contentsOf: samples)
        if whoopIMUHistorySamples.count > 20_000 {
            whoopIMUHistorySamples.removeFirst(whoopIMUHistorySamples.count - 20_000)
        }
        persistDashboardIMUHistoryIfNeeded()
    }

    private func persistDashboardHistory() {
        let defaults = UserDefaults.standard
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let retainedHR = Array(dashboardHeartRateHistory.filter { $0.timestamp >= cutoff }.suffix(20_000))
        if let data = try? JSONEncoder().encode(retainedHR) {
            defaults.set(data, forKey: DashboardHistoryKey.heartRate)
        }
        if let data = try? JSONEncoder().encode(Array(dashboardRRHistory.suffix(20_000))) {
            defaults.set(data, forKey: DashboardHistoryKey.rrSamples)
        }
        if let data = try? JSONEncoder().encode(Array(dashboardStandardRRHistory.suffix(20_000))) {
            defaults.set(data, forKey: DashboardHistoryKey.standardRRSamples)
        }
        // Historical v18 HR/time offsets are not verified; purge legacy candidate values.
        defaults.removeObject(forKey: DashboardHistoryKey.historicalRR)
        defaults.removeObject(forKey: DashboardHistoryKey.historicalHR)
        defaults.removeObject(forKey: DashboardHistoryKey.historicalAt)
    }

    private func restoreDashboardHistory() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: DashboardHistoryKey.heartRate),
           let samples = try? JSONDecoder().decode([LiveHeartRateSample].self, from: data) {
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            dashboardHeartRateHistory = Array(samples.filter { $0.timestamp >= cutoff }.suffix(20_000))
            liveHeartRateSamples = Array(dashboardHeartRateHistory.suffix(120))
        }
        // Purge legacy v18 values that older builds incorrectly labelled milliseconds.
        defaults.removeObject(forKey: DashboardHistoryKey.historicalRR)
        whoopHistoricalRRIntervalsMilliseconds = []
        whoopHistoricalRRLastUpdatedAt = nil
        if let data = defaults.data(forKey: DashboardHistoryKey.rrSamples),
           let samples = try? JSONDecoder().decode([PersistedRRIntervalSample].self, from: data) {
            dashboardRRHistory = Array(samples.suffix(20_000))
        }
        if let data = defaults.data(forKey: DashboardHistoryKey.standardRRSamples),
           let samples = try? JSONDecoder().decode([PersistedRRIntervalSample].self, from: data) {
            dashboardStandardRRHistory = Array(samples.suffix(20_000))
        }
        defaults.removeObject(forKey: DashboardHistoryKey.historicalHR)
        defaults.removeObject(forKey: DashboardHistoryKey.historicalAt)
        whoopHistoricalHeartRateBPM = nil
        whoopHistoricalTimestampLastUpdatedAt = nil
        if let data = defaults.data(forKey: DashboardHistoryKey.imuSamples),
           let samples = try? JSONDecoder().decode([WhoopIMUSample].self, from: data) {
            whoopIMUHistorySamples = Array(samples.suffix(20_000))
            lastDashboardIMUPersistedSampleCount = whoopIMUHistorySamples.count
        }
        // Never restore live BPM/freshness or calculate live RMSSD from old samples.
    }

    var freshHeartRateBPM: Int? {
        guard connectedName != nil, let lastHeartRateAt,
              Date().timeIntervalSince(lastHeartRateAt) <= 8 else { return nil }
        return liveHeartRateBPM
    }

    func startWorkoutRecording() {
        beginWorkoutRecording(automatic: false)
    }

    private func beginWorkoutRecording(automatic: Bool, baselineBPM: Int? = nil) {
        guard connectedName != nil, !workoutIsRecording else { return }
        workoutHeartRateSamples.removeAll()
        workoutWhoopIMUSamples.removeAll()
        lastWhoopIMUPersistedSampleCount = 0
        workoutStartedAt = Date()
        lastWorkoutStartedAt = workoutStartedAt
        lastWorkoutWasAutomatic = automatic
        lastWorkoutWasInterrupted = false
        lastWorkoutDurationSeconds = nil
        UserDefaults.standard.removeObject(forKey: "pulseforge.whoop.lastWorkoutDuration")
        workoutRecordingIsAutomatic = automatic
        workoutSessionBaselineBPM = automatic ? baselineBPM : nil
        workoutIsRecording = true
        workoutDetectionCandidateSince = nil
        workoutDetectionCandidateBaselineBPM = nil
        workoutRecoverySince = nil
        workoutDetectionStatus = automatic
            ? "Auto-detected from sustained elevated HR · HR-only"
            : "Manual workout recording"
        statusText = automatic
            ? "Workout auto-detected · recording HR"
            : "Workout recording · waiting for HR samples"
        persistWorkoutSession()
    }

    func stopWorkoutRecording() {
        guard workoutIsRecording else { return }
        if let workoutStartedAt {
            lastWorkoutDurationSeconds = Date().timeIntervalSince(workoutStartedAt)
            lastWorkoutStartedAt = workoutStartedAt
            archiveCurrentWorkout(startedAt: workoutStartedAt,
                                  duration: lastWorkoutDurationSeconds ?? 0,
                                  automatic: workoutRecordingIsAutomatic,
                                  interrupted: false)
        }
        lastWorkoutWasAutomatic = workoutRecordingIsAutomatic
        lastWorkoutWasInterrupted = false
        workoutIsRecording = false
        workoutStartedAt = nil
        workoutDetectionStatus = workoutRecordingIsAutomatic
            ? "Automatic workout saved · HR-only detection"
            : "Manual workout saved"
        workoutRecordingIsAutomatic = false
        workoutSessionBaselineBPM = nil
        workoutDetectionCandidateSince = nil
        workoutDetectionCandidateBaselineBPM = nil
        workoutRecoverySince = nil
        persistWorkoutSession()
        statusText = "Workout saved on this iPhone · \(workoutHeartRateSamples.count) HR samples"
    }

 
    // WHOOP archive evidence shows a dedicated ActivityDetectionSettings module
    // and a TrackActivity heart-rate sample stream, but no recoverable detector
    // implementation or thresholds. Keep this independent, HR-only detector
    // conservative until the strap's revision-aware IMU stream is verified.
    private func hasContinuousSamples(_ samples: [LiveHeartRateSample],
                                      minimumCount: Int,
                                      minimumSpan: TimeInterval,
                                      maximumGap: TimeInterval) -> Bool {
        guard samples.count >= minimumCount,
              let first = samples.first,
              let last = samples.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumSpan else {
            return false
        }
        for pair in zip(samples, samples.dropFirst()) {
            if pair.1.timestamp.timeIntervalSince(pair.0.timestamp) > maximumGap {
                return false
            }
        }
        return true
    }

    private func evaluateAutomaticWorkoutDetection(bpm: Int, at timestamp: Date) {
        let sample = LiveHeartRateSample(timestamp: timestamp, bpm: bpm)
        workoutDetectionSamples.append(sample)
        workoutDetectionSamples.removeAll {
            timestamp.timeIntervalSince($0.timestamp) > 15 * 60 ||
            timestamp.timeIntervalSince($0.timestamp) < 0
        }

        guard connectedName != nil else {
            workoutDetectionCandidateSince = nil
            workoutDetectionCandidateBaselineBPM = nil
            workoutRecoverySince = nil
            workoutDetectionStatus = "Waiting for connected-band HR"
            return
        }

        // Freeze the pre-workout baseline for the entire automatic session.
        // Otherwise, after five minutes, elevated workout HR would enter the
        // rolling baseline window and gradually move the recovery threshold up.
        if workoutIsRecording {
            guard workoutRecordingIsAutomatic,
                  let baseline = workoutSessionBaselineBPM else { return }
            let recoveryThreshold = baseline + 10
            if bpm <= recoveryThreshold {
                if workoutRecoverySince == nil { workoutRecoverySince = timestamp }
                if let recoverySince = workoutRecoverySince,
                   timestamp.timeIntervalSince(recoverySince) >= 8 * 60,
                   let startedAt = workoutStartedAt,
                   timestamp.timeIntervalSince(startedAt) >= 10 * 60 {
                    let recoverySamples = workoutDetectionSamples.filter {
                        $0.timestamp >= recoverySince && $0.bpm <= recoveryThreshold
                    }.sorted { $0.timestamp < $1.timestamp }
                    if hasContinuousSamples(recoverySamples, minimumCount: 6,
                                             minimumSpan: 7 * 60, maximumGap: 2 * 60) {
                        stopWorkoutRecording()
                    } else {
                        workoutDetectionStatus = "HR low · waiting for continuous recovery samples"
                    }
                } else {
                    workoutDetectionStatus = "HR recovery observed · confirming 8 min"
                }
            } else {
                workoutRecoverySince = nil
                workoutDetectionStatus = "Recording · HR remains elevated · HR-only"
            }
            return
        }

        let baselineWindow = workoutDetectionSamples.filter {
            let age = timestamp.timeIntervalSince($0.timestamp)
            return age >= 5 * 60 && age <= 15 * 60
        }.sorted { $0.timestamp < $1.timestamp }
        guard baselineWindow.count >= 5,
              hasContinuousSamples(baselineWindow, minimumCount: 5,
                                   minimumSpan: 2 * 60, maximumGap: 3 * 60) else {
            workoutDetectionStatus = "Learning HR baseline · need 5 samples across 2 min"
            return
        }

        let sortedBaseline = baselineWindow.map(\.bpm).sorted()
        let rollingBaseline = sortedBaseline[sortedBaseline.count / 2]

        // Start the candidate clock on the first elevated-HR sample, not
        // when the rolling baseline first becomes available. This prevents
        // idle time from shortening the sustained-elevation validation period.
        if workoutDetectionCandidateSince == nil {
            let initialThreshold = max(100, rollingBaseline + 20)
            if bpm >= initialThreshold {
                workoutDetectionCandidateSince = timestamp
                workoutDetectionCandidateBaselineBPM = rollingBaseline
            } else {
                workoutDetectionStatus = "Monitoring HR · baseline \(rollingBaseline) bpm · trigger \(initialThreshold) bpm"
                return
            }
        }

        let candidateSince = workoutDetectionCandidateSince ?? timestamp
        let baseline = workoutDetectionCandidateBaselineBPM ?? rollingBaseline
        let startThreshold = max(100, baseline + 20)
        if bpm >= startThreshold {
            let elevatedSamples = workoutDetectionSamples.filter {
                $0.timestamp >= candidateSince && $0.bpm >= startThreshold
            }.sorted { $0.timestamp < $1.timestamp }
            let elapsed = Int(timestamp.timeIntervalSince(candidateSince))
            if elapsed >= 5 * 60 &&
                hasContinuousSamples(elevatedSamples, minimumCount: 4,
                                     minimumSpan: 4 * 60, maximumGap: 2 * 60) {
                beginWorkoutRecording(automatic: true, baselineBPM: baseline)
            } else {
                workoutDetectionStatus = "Possible workout · validating HR continuity · \(min(elapsed, 300))/300 sec"
            }
        } else {
            workoutDetectionCandidateSince = nil
            workoutDetectionCandidateBaselineBPM = nil
            workoutDetectionStatus = "Monitoring HR · baseline \(rollingBaseline) bpm · trigger \(max(100, rollingBaseline + 20)) bpm"
        }
    }

    private func archiveCurrentWorkout(startedAt: Date, duration: TimeInterval,
                                        automatic: Bool, interrupted: Bool) {
        let record = WorkoutSessionRecord(
            startedAt: startedAt,
            durationSeconds: duration,
            wasAutomatic: automatic,
            wasInterrupted: interrupted,
            heartRateSamples: workoutHeartRateSamples,
            imuSamples: workoutWhoopIMUSamples
        )
        workoutHistory.removeAll { $0.startedAt == startedAt }
        workoutHistory.insert(record, at: 0)
        if workoutHistory.count > 20 { workoutHistory = Array(workoutHistory.prefix(20)) }
        saveWorkoutHistory()
        exportWorkoutToHealthKit(record)
    }

    /// Export completed WHOOP HR recordings as a HealthKit workout with its
    /// timestamped HR samples. Local history remains the source of truth if
    /// HealthKit sharing is unavailable or denied.
    private func exportWorkoutToHealthKit(_ record: WorkoutSessionRecord) {
        guard !record.wasInterrupted else {
            healthKitExportStatus = "Partial session kept in PulseForge · not exported to Apple Health"
            return
        }
        let exportedKey = "pulseforge.healthkit.exportedWorkoutIDs"
        var exportedIDs = Set(UserDefaults.standard.stringArray(forKey: exportedKey) ?? [])
        guard !exportedIDs.contains(record.id.uuidString) else {
            healthKitExportStatus = "Workout already exported to Apple Health"
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            healthKitExportStatus = "Apple Health is unavailable on this device"
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        let builder = HKWorkoutBuilder(healthStore: healthKitStore,
                                       configuration: configuration,
                                       device: HKDevice.local())
        let end = max(record.startedAt.addingTimeInterval(1),
                      record.startedAt.addingTimeInterval(record.durationSeconds))
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let rateUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let heartRateSamples = record.heartRateSamples
            .filter { $0.timestamp >= record.startedAt && $0.timestamp <= end }
            .map { sample in
                HKQuantitySample(type: heartRateType,
                                 quantity: HKQuantity(unit: rateUnit, doubleValue: Double(sample.bpm)),
                                 start: sample.timestamp,
                                 end: sample.timestamp)
            }

        healthKitExportStatus = "Exporting workout and \(heartRateSamples.count) HR samples to Apple Health…"
        builder.beginCollection(withStart: record.startedAt) { [weak self] began, beginError in
            guard let self else { return }
            guard began else {
                DispatchQueue.main.async {
                    self.healthKitExportStatus = "Apple Health export failed · \(beginError?.localizedDescription ?? "collection could not start")"
                }
                return
            }
            let finishCollection = {
                builder.endCollection(withEnd: end) { ended, endError in
                    guard ended else {
                        DispatchQueue.main.async {
                            self.healthKitExportStatus = "Apple Health export failed · \(endError?.localizedDescription ?? "collection could not finish")"
                        }
                        return
                    }
                    builder.finishWorkout { workout, finishError in
                        DispatchQueue.main.async {
                            if workout != nil {
                                exportedIDs.insert(record.id.uuidString)
                                UserDefaults.standard.set(Array(exportedIDs), forKey: exportedKey)
                                self.healthKitExportStatus = "Saved to Apple Health · \(heartRateSamples.count) HR samples"
                            } else {
                                self.healthKitExportStatus = "Apple Health export failed · \(finishError?.localizedDescription ?? "workout was not saved")"
                            }
                        }
                    }
                }
            }
            guard !heartRateSamples.isEmpty else {
                finishCollection()
                return
            }
            builder.add(heartRateSamples) { added, addError in
                guard added else {
                    DispatchQueue.main.async {
                        self.healthKitExportStatus = "Workout HR export failed · \(addError?.localizedDescription ?? "samples could not be added")"
                    }
                    return
                }
                finishCollection()
            }
        }
    }

    private var workoutHistoryFileURL: URL? {
        guard let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask).first else {
            return nil
        }
        return supportDirectory
            .appendingPathComponent("PulseForge", isDirectory: true)
            .appendingPathComponent("workout-history-v1.json", isDirectory: false)
    }

    private func loadWorkoutHistory() -> [WorkoutSessionRecord] {
        if let url = workoutHistoryFileURL,
           let data = try? Data(contentsOf: url),
           let records = try? JSONDecoder().decode([WorkoutSessionRecord].self, from: data) {
            return records.sorted { $0.startedAt > $1.startedAt }
        }
        // One-time migration from the earlier UserDefaults-backed history.
        if let data = UserDefaults.standard.data(forKey: "pulseforge.whoop.workoutHistory.v1"),
           let records = try? JSONDecoder().decode([WorkoutSessionRecord].self, from: data) {
            let migrated = Array(records.sorted { $0.startedAt > $1.startedAt }.prefix(20))
            saveWorkoutHistory(migrated)
            UserDefaults.standard.removeObject(forKey: "pulseforge.whoop.workoutHistory.v1")
            return migrated
        }
        return []
    }

    private func saveWorkoutHistory(_ records: [WorkoutSessionRecord]? = nil) {
        guard let url = workoutHistoryFileURL else { return }
        let recordsToSave = records ?? workoutHistory
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(recordsToSave)
            try data.write(to: url, options: .atomic)
            UserDefaults.standard.removeObject(forKey: "pulseforge.whoop.workoutHistory.v1")
        } catch {
            statusText = "Workout history save failed · \(error.localizedDescription)"
        }
    }

    private func persistWorkoutSession(includeIMU: Bool = true) {
        saveWorkoutHistory()
        if let data = try? JSONEncoder().encode(workoutHeartRateSamples) {
            UserDefaults.standard.set(data, forKey: "pulseforge.whoop.lastWorkoutSamples")
        }
        if includeIMU, let data = try? JSONEncoder().encode(workoutWhoopIMUSamples) {
            UserDefaults.standard.set(data, forKey: "pulseforge.whoop.lastVerifiedWorkoutIMUSamples")
            lastWhoopIMUPersistedSampleCount = workoutWhoopIMUSamples.count
        }
        if let duration = lastWorkoutDurationSeconds {
            UserDefaults.standard.set(duration, forKey: "pulseforge.whoop.lastWorkoutDuration")
        }
        if let startedAt = lastWorkoutStartedAt {
            UserDefaults.standard.set(startedAt, forKey: "pulseforge.whoop.lastWorkoutStartedAt")
        }
        if let wasAutomatic = lastWorkoutWasAutomatic {
            UserDefaults.standard.set(wasAutomatic, forKey: "pulseforge.whoop.lastWorkoutWasAutomatic")
        }
        UserDefaults.standard.set(lastWorkoutWasInterrupted, forKey: "pulseforge.whoop.lastWorkoutWasInterrupted")
        UserDefaults.standard.set(workoutIsRecording, forKey: "pulseforge.whoop.activeWorkout")
        if workoutIsRecording, let startedAt = workoutStartedAt {
            UserDefaults.standard.set(startedAt, forKey: "pulseforge.whoop.activeWorkoutStartedAt")
            UserDefaults.standard.set(workoutRecordingIsAutomatic, forKey: "pulseforge.whoop.activeWorkoutWasAutomatic")
        } else {
            UserDefaults.standard.removeObject(forKey: "pulseforge.whoop.activeWorkoutStartedAt")
            UserDefaults.standard.removeObject(forKey: "pulseforge.whoop.activeWorkoutWasAutomatic")
        }
    }

    private var vendorNotificationStates: [String: String] = [:]
    private var vendorNotificationPayloads: [String: String] = [:]
    private var vendorNotificationHistory: [String] = []
    private var vendorNotificationTimeline: [String] = []
    // Reassemble WHOOP frames independently for each FD4B notification channel.
    private var whoop5FragmentBuffers: [String: Data] = [:]
    private var whoop5ExpectedFrameLengths: [String: Int] = [:]
    private var candidateNotificationStates: [String: String] = [:]
    private var candidateNotificationHistory: [String] = []
    private let motionProbeUUIDPrefixes = ["8A58", "5983", "6108", "1150"]
    private let whoop5ServiceUUID = CBUUID(string: "FD4B0001-CCE1-4033-93CE-002D5875F58A")
    private let whoop5CommandUUID = CBUUID(string: "FD4B0002-CCE1-4033-93CE-002D5875F58A")
    private var whoop5CommandCharacteristic: CBCharacteristic?
    private var whoop5HelloSent = false
    private var whoop5HelloWritePending = false
    private var whoop5HelloWriteAcknowledged = false
    private var whoop5PostHelloNotifyRetryAttempted = Set<String>()
    private var whoop5HRStreamEnableSent = false
    private var whoop5HRStallRecoveryWorkItem: DispatchWorkItem?
    private var whoop5HRStallRecoveryAttempted = false
    private var whoop5HRStreamConfirmed = false
    private var whoop5AutoIMUStartRequested = false
    private var whoop5AutoIMUEnabled = false
    private var whoop5IMUModeEnableSequence: UInt8?
    private var whoop5IMUModeTargetEnabled: Bool?
    private var whoop5RawStartSequence: UInt8?
    private var whoop5RawStopSequence: UInt8?
    private var whoop5RawStreamStopWorkItem: DispatchWorkItem?
    private var whoop5RawStreamRearmWorkItem: DispatchWorkItem?
    private var whoop5PendingWrites: [String] = []
    private var whoop5NextCommandSequence: UInt8 = 2
    private var whoop5HistorySyncStarted = false
    private var whoop5HistorySyncRequested = false
    private var whoop5HistoryClockSequence: UInt8?
    private var whoop5HistoryRangeSequence: UInt8?
    private var whoop5HistoryRequestSequence: UInt8?
    /// Buffer historical frames and write them in batches; HISTORY_END forces a durable flush before ACK.
    private var pendingHistoricalRRArchiveRecords: [HistoricalRRPacketRecord] = []
    private let historicalRRArchiveBatchSize = 10
    private var whoop5HelloRevision: Int?
    private var whoop5HelloTimestampSeconds: UInt32?
    private var whoop5HelloTimestampSubseconds: UInt32?
    private var hrTimingConnectionAt: Date?
    private var hrTimingStandardNotifyRequestedAt: Date?
    private var hrTimingStandardNotifyEnabledAt: Date?
    private var hrTimingFirstSampleAt: Date?
    private var hrTimingEvents: [String] = []

    // Diagnostic-only timeline: records CoreBluetooth callback ordering without
    // changing the WHOOP handshake, command payloads, or subscription policy.
    private func recordVendorTimeline(_ event: String) {
        let elapsed = hrTimingConnectionAt.map { Date().timeIntervalSince($0) } ?? 0
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = String(format: "%@ · gen=%d · +%.3fs · %@ · helloSent=%@ helloAckPending=%@ hrEnableSent=%@",
                          stamp, whoopConnectionGeneration, elapsed, event,
                          whoop5HelloSent ? "yes" : "no",
                          whoop5HelloWritePending ? "yes" : "no",
                          whoop5HRStreamEnableSent ? "yes" : "no")
        vendorNotificationTimeline.append(line)
        if vendorNotificationTimeline.count > 100 {
            vendorNotificationTimeline.removeFirst(vendorNotificationTimeline.count - 100)
        }
    }

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var connectedDeviceSnapshot: DiscoveredWearable?
    private var pendingRestoredPeripheral: CBPeripheral?
    private let rememberedPeripheralKey = "pulseforge.whoop.lastPeripheralUUID"
    private var isAutomaticReconnectScan = false
    private var automaticReconnectScanToken = UUID()
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var automaticReconnectAttempt = 0
    private var pendingCharacteristicServices = Set<ObjectIdentifier>()
    private var pendingDescriptorCharacteristics = Set<ObjectIdentifier>()
    private var gattCharacteristicDiscoveryErrors: [String] = []

    // Candidate UUIDs observed in the WHOOP archive. They are scan hints only;
    // the archive string scan does not prove their exact GATT roles.
    private let candidateUUIDs: Set<String> = [
        "8A580001-2FE8-4796-9267-B87A2B0C8234",
        "59830001-5955-419B-BB8D-C8262926AF23",
        "11500001-6215-11EE-8C99-0242AC120002",
        "FD4B0001-CCE1-4033-93CE-002D5875F58A",
        "61080001-8D6D-82B8-614A-1C8CB0F8DCC6"
    ]

    override init() {
        super.init()
        whoopBatteryPercent = UserDefaults.standard.object(forKey: "pulseforge.whoop.batteryPercent") as? Double
        whoopBatteryLastUpdatedAt = UserDefaults.standard.object(forKey: "pulseforge.whoop.batteryUpdatedAt") as? Date
        restoreDashboardHistory()
        if let data = UserDefaults.standard.data(forKey: "pulseforge.whoop.lastWorkoutSamples"),
           let savedSamples = try? JSONDecoder().decode([LiveHeartRateSample].self, from: data) {
            workoutHeartRateSamples = savedSamples
        }
        if let imuData = UserDefaults.standard.data(forKey: "pulseforge.whoop.lastVerifiedWorkoutIMUSamples"),
           let savedIMUSamples = try? JSONDecoder().decode([WhoopIMUSample].self, from: imuData) {
            workoutWhoopIMUSamples = savedIMUSamples
        }
        lastWorkoutDurationSeconds = UserDefaults.standard.object(forKey: "pulseforge.whoop.lastWorkoutDuration") as? Double
        lastWorkoutStartedAt = UserDefaults.standard.object(forKey: "pulseforge.whoop.lastWorkoutStartedAt") as? Date
        if UserDefaults.standard.object(forKey: "pulseforge.whoop.lastWorkoutWasAutomatic") != nil {
            lastWorkoutWasAutomatic = UserDefaults.standard.bool(forKey: "pulseforge.whoop.lastWorkoutWasAutomatic")
        }
        lastWorkoutWasInterrupted = UserDefaults.standard.bool(forKey: "pulseforge.whoop.lastWorkoutWasInterrupted")
        workoutHistory = loadWorkoutHistory()
        if UserDefaults.standard.bool(forKey: "pulseforge.whoop.activeWorkout"),
           let interruptedStart = UserDefaults.standard.object(forKey: "pulseforge.whoop.activeWorkoutStartedAt") as? Date {
            lastWorkoutStartedAt = interruptedStart
            lastWorkoutWasAutomatic = UserDefaults.standard.bool(forKey: "pulseforge.whoop.activeWorkoutWasAutomatic")
            lastWorkoutDurationSeconds = max(0, Date().timeIntervalSince(interruptedStart))
            lastWorkoutWasInterrupted = true
            archiveCurrentWorkout(startedAt: interruptedStart,
                                  duration: lastWorkoutDurationSeconds ?? 0,
                                  automatic: lastWorkoutWasAutomatic ?? false,
                                  interrupted: true)
            workoutIsRecording = false
            workoutStartedAt = nil
            workoutRecordingIsAutomatic = false
            workoutDetectionStatus = "Workout recovered after app restart · partial data"
            persistWorkoutSession()
        }
        #if targetEnvironment(simulator)
        // CoreBluetooth state restoration is unavailable in the CI simulator
        // host because its generated Info.plist may not carry bluetooth-central.
        // Keep simulator tests deterministic; physical iPhones retain restoration.
        central = CBCentralManager(delegate: self, queue: .main)
        #else
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.ribhupanwar.pulseforge.bluetooth-central"]
        )
        #endif
    }

    private func cancelAutomaticReconnectScan() {
        isAutomaticReconnectScan = false
        automaticReconnectScanToken = UUID()
        central.stopScan()
    }

    func startScan() {
        guard connectedPeripheral == nil, !isConnecting else {
            statusText = "Disconnect the current band before scanning"
            return
        }
        guard central.state == .poweredOn else {
            statusText = "Turn on Bluetooth to scan"
            return
        }
        scanTimeoutWorkItem?.cancel()
        cancelAutomaticReconnectScan()
        devices.removeAll()
        discoveredProfile.removeAll()
        statusText = "Scanning nearby devices…"
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            self.statusText = self.devices.isEmpty
                ? "No WHOOP candidate found · try scanning again"
                : "Scan complete · found \(self.devices.count) candidate device(s)"
        }
        scanTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func stopScan() {
        cancelAutomaticReconnectScan()
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        central.stopScan()
        if connectedPeripheral == nil { statusText = "Scan stopped" }
    }

    func disconnect() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        automaticReconnectAttempt = 0
        cancelAutomaticReconnectScan()
        if let peripheral = connectedPeripheral {
            UserDefaults.standard.removeObject(forKey: rememberedPeripheralKey)
            pendingRestoredPeripheral = nil
            central.cancelPeripheralConnection(peripheral)
            statusText = "Disconnecting…"
        } else {
            clearConnectionState()
            statusText = "Disconnected"
        }
    }

    func connect(to device: DiscoveredWearable) {
        guard central.state == .poweredOn else {
            statusText = "Bluetooth is not ready"
            return
        }
        guard !isConnecting, connectedPeripheral == nil else {
            statusText = connectedPeripheral == nil
                ? "A connection is already in progress"
                : "Disconnect the current band before connecting another"
            return
        }
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        automaticReconnectAttempt = 0
        cancelAutomaticReconnectScan()
        discoveredProfile.removeAll()
        connectedDeviceSnapshot = device
        connectedPeripheral = device.peripheral
        UserDefaults.standard.set(device.id.uuidString, forKey: rememberedPeripheralKey)
        lastBLEEvent = "Waiting for first BLE characteristic value on this connection"
        connectedPeripheral?.delegate = self
        isConnecting = true
        statusText = "Connecting to \(device.name)…"
        central.connect(device.peripheral, options: nil)
        let timeout = DispatchWorkItem { [weak self, weak peripheral = device.peripheral] in
            guard let self, let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  self.connectedName == nil else { return }
            self.central.cancelPeripheralConnection(peripheral)
            self.clearConnectionState()
            self.statusText = "Connection timed out · try again"
        }
        connectionTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    var gattCapabilitySummary: String {
        let services = discoveredProfile.filter { $0.hasPrefix("Service ·") }
        let primaryServices = services.filter { $0.localizedCaseInsensitiveContains(" · primary") }.count
        let secondaryServices = services.filter { $0.localizedCaseInsensitiveContains(" · secondary") }.count
        let characteristics = discoveredProfile.filter { $0.hasPrefix("Characteristic ·") }
        let descriptors = discoveredProfile.filter { $0.hasPrefix("Descriptor ·") }
        let descriptorErrors = discoveredProfile.filter { $0.hasPrefix("Descriptor error ·") }.count
        let discoveryErrors = discoveredProfile.filter { $0.hasPrefix("Service error ·") }.count
        func count(_ property: String) -> Int {
            characteristics.filter { line in
                guard let marker = line.range(of: " · ", options: .backwards) else { return false }
                return line[marker.upperBound...]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .contains(property)
            }.count
        }
        let cccdCount = descriptors.filter {
            $0.localizedCaseInsensitiveContains("00002902")
        }.count
        return "\(services.count) services (P:\(primaryServices) S:\(secondaryServices)) · \(characteristics.count) characteristics · D:\(descriptors.count) CCCD:\(cccdCount) · R:\(count("read")) W:\(count("write")) WNR:\(count("write-no-response")) N:\(count("notify")) I:\(count("indicate")) · Errors:\(discoveryErrors + descriptorErrors)"
    }

    var notificationDiagnostics: [String] {
        let standard = isStandardHeartRateNotifying ? "enabled" : "not enabled"
        let uuids = [
            "FD4B0003-CCE1-4033-93CE-002D5875F58A",
            "FD4B0004-CCE1-4033-93CE-002D5875F58A",
            "FD4B0005-CCE1-4033-93CE-002D5875F58A",
            "FD4B0007-CCE1-4033-93CE-002D5875F58A"
        ]
        return ["180D / 2A37 standard HR: \(standard)"] + uuids.map { uuid in
            let state = vendorNotificationStates[uuid] ?? "not requested"
            let payload = vendorNotificationPayloads[uuid] ?? "no payload received"
            return "\(uuid): \(state) · \(payload)"
        }
    }

    /// JSON export of CRC-valid Type-47 v18 frames captured from the connected band.
    /// Includes raw frame hex, phone receipt time, candidate RR values, and decode errors.
    /// Physiological timestamps remain nil until the packet layout is independently verified.
    var historicalRRArchiveExport: String {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return "[]" }
        let archiveURL = support
            .appendingPathComponent("PulseForge", isDirectory: true)
            .appendingPathComponent("historical-whoop-rr-v1.json")
        return HistoricalRRPacketArchive.exportJSON(from: archiveURL)
            ?? "Archive export unavailable · file could not be decoded · original bytes were not changed"
    }

    var historicalRRArchiveRecordCount: Int {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return 0 }
        let archiveURL = support
            .appendingPathComponent("PulseForge", isDirectory: true)
            .appendingPathComponent("historical-whoop-rr-v1.json")
        return HistoricalRRPacketArchive.load(from: archiveURL).count
    }

    var diagnosticSnapshot: String {
        var lines = [
            "GATT summary: \(gattCapabilitySummary)",
            "PulseForge BLE diagnostic snapshot",
            "Captured: \(ISO8601DateFormatter().string(from: Date()))",
            "Device: \(connectedName ?? "Not connected")",
            "Peripheral ID: \(connectedDeviceSnapshot?.id.uuidString ?? "Unavailable")",
            "RSSI at discovery: \(connectedDeviceSnapshot.map { "\($0.rssi) dBm" } ?? "Unavailable")",
            "Advertised services: \(connectedDeviceSnapshot?.advertisedServices.joined(separator: ", ") ?? "None")",
            "Service data: \(connectedDeviceSnapshot?.serviceDataEntries.joined(separator: ", ") ?? "None")",
            "Solicited services: \(connectedDeviceSnapshot?.solicitedServices.joined(separator: ", ") ?? "None")",
            "Overflow services: \(connectedDeviceSnapshot?.overflowServices.joined(separator: ", ") ?? "None")",
            "Manufacturer data length: \(connectedDeviceSnapshot?.manufacturerDataByteCount.map(String.init) ?? "Unavailable")",
            "Transmit power: \(connectedDeviceSnapshot?.transmitPower.map { "\($0) dBm" } ?? "Unavailable")",
            "Connectable: \(connectedDeviceSnapshot?.isConnectable.map(String.init) ?? "Unavailable")",
            "Status: \(statusText)",
            "WHOOP battery: \(whoopBatteryPercent.map { String(format: "%.1f%%", $0) } ?? "not received") · updated: \(whoopBatteryLastUpdatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
            "WHOOP connection generation: \(whoopConnectionGeneration) · session phase: \(whoopSessionPhase)",
            "WHOOP event packets: \(whoopEventPacketCount) · last event ID: \(whoopLastEventID.map(String.init) ?? "none") · last frame: \(whoopLastEventFrameHex)",
            "Latest BLE event: \(lastBLEEvent)",
            "Standard Heart Rate Measurement: \(isStandardHeartRateNotifying ? "subscribed" : "not subscribed")",
            "Latest WHOOP standard HR value: \(liveHeartRateBPM.map { "\($0) bpm" } ?? "None received")",
            "Latest HR timestamp: \(lastHeartRateAt.map { ISO8601DateFormatter().string(from: $0) } ?? "None")",
            "HR updates this connection: \(heartRateUpdateCount)",
            "HR timing · connected: \(hrTimingConnectionAt.map { ISO8601DateFormatter().string(from: $0) } ?? "not recorded")",
            "HR timing · standard notify requested: \(hrTimingStandardNotifyRequestedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "not requested")",
            "HR timing · standard notify enabled: \(hrTimingStandardNotifyEnabledAt.map { ISO8601DateFormatter().string(from: $0) } ?? "not enabled")",
            "HR timing · first sample: \(hrTimingFirstSampleAt.map { ISO8601DateFormatter().string(from: $0) } ?? "not received")",
            "HR timing events: \(hrTimingEvents.suffix(12).joined(separator: " | "))",
            "WHOOP 5.0 CLIENT_HELLO sent: \(whoop5HelloSent ? "yes" : "no")",
            "WHOOP 5.0 CLIENT_HELLO write pending: \(whoop5HelloWritePending ? "yes" : "no")",
            "WHOOP realtime HR enable command sent: \(whoop5HRStreamEnableSent ? "yes" : "no")",
            "WHOOP Type-40 frame observed (inner fields unverified): \(whoop5Type40FrameObserved ? "yes" : "no")",
            "WHOOP realtime HR ON event confirmed: \(whoop5HRStreamConfirmed ? "yes" : "no")",
            "WHOOP Type-48 EVENT counts by channel: \(whoopEventCountsByChannel.keys.sorted().map { "\($0)=\(whoopEventCountsByChannel[$0] ?? 0)" }.joined(separator: ", ").isEmpty ? "none" : whoopEventCountsByChannel.keys.sorted().map { "\($0)=\(whoopEventCountsByChannel[$0] ?? 0)" }.joined(separator: ", "))",
            "WHOOP event IDs · total: \(whoopEventPacketCount) · ID 33: \(whoopEvent33Count) · ID 34: \(whoopEvent34Count) · last ID: \(whoopLastEventID.map(String.init) ?? "none") · last channel: \(whoopLastEventChannel)",
            "WHOOP per-channel telemetry: \(whoopPerChannelTelemetrySummary)",
            "WHOOP last Event 33: \(whoopLastEvent33At.map { ISO8601DateFormatter().string(from: $0) } ?? "not observed") · \(whoopLastEvent33FrameHex)",
            "WHOOP last Event 34: \(whoopLastEvent34At.map { ISO8601DateFormatter().string(from: $0) } ?? "not observed") · \(whoopLastEvent34FrameHex)",
            "WHOOP Puffin event packet types 53/54: \(whoopPuffinEventTypeCounts.keys.sorted().map { "type \($0)=\(whoopPuffinEventTypeCounts[$0] ?? 0)" }.joined(separator: ", ").isEmpty ? "none" : whoopPuffinEventTypeCounts.keys.sorted().map { "type \($0)=\(whoopPuffinEventTypeCounts[$0] ?? 0)" }.joined(separator: ", "))",
            "WHOOP Puffin event channels: \(whoopPuffinEventCountsByChannel.keys.sorted().map { "\($0)=\(whoopPuffinEventCountsByChannel[$0] ?? 0)" }.joined(separator: ", ").isEmpty ? "none" : whoopPuffinEventCountsByChannel.keys.sorted().map { "\($0)=\(whoopPuffinEventCountsByChannel[$0] ?? 0)" }.joined(separator: ", "))",
            "WHOOP Event 33/34 controlled probe: \(whoopEventProbeStatus)",
            "WHOOP automatic IMU request: \(whoop5AutoIMUStartRequested ? "yes" : "no")",
            "WHOOP automatic IMU enabled: \(whoop5AutoIMUEnabled ? "yes" : "no")",
            "WHOOP IMU frames: \(whoopIMUFrameCount) · samples: \(whoopIMUSampleCount) · live buffer: \(liveWhoopIMUSamples.count) · workout samples: \(workoutWhoopIMUSamples.count) · status: \(whoopIMUStatus)",
            "WHOOP latest IMU sample: \(liveWhoopIMUSamples.last.map { String(format: "A %.3f, %.3f, %.3f g · G %.1f, %.1f, %.1f dps", $0.accelerationXG, $0.accelerationYG, $0.accelerationZG, $0.rotationXDPS, $0.rotationYDPS, $0.rotationZDPS) } ?? "none")",
            "WHOOP IMU last frame: \(whoopIMULastFrameAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
            "WHOOP latest CRC-valid raw IMU frame hex (outer type 43 · inner 0x2B/R21): \(whoopIMULastRawFrameHex)",
            "WHOOP RR state: \(whoopRRIntervalsMilliseconds.map(String.init).joined(separator: ",").isEmpty ? "none" : whoopRRIntervalsMilliseconds.map(String.init).joined(separator: ",")) ms · source: \(whoopRRSource) · last RR update: \(whoopRRLastUpdatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
            "WHOOP Type-40 candidate fields: \(whoopRealtimeCandidateStatus) · byte[16]=\(whoopRealtimeCandidateByteAt16.map(String.init) ?? "unavailable") · raw words=\(whoopRealtimeCandidateRRWords.map(String.init).joined(separator: ","))",
            "WHOOP standard 2A37 raw notifications: \(whoopStandardHeartRateRawFrameHistory.count) retained · latest: \(whoopStandardHeartRateRawFrameHistory.last ?? "none")",
            "WHOOP standard 2A37 RR: \(whoopStandardRRIntervalsMilliseconds.map(String.init).joined(separator: ",").isEmpty ? "none" : whoopStandardRRIntervalsMilliseconds.map(String.init).joined(separator: ",")) ms · last update: \(whoopStandardRRLastUpdatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
            "WHOOP historical sync: \(whoopHistorySyncStatus)",
            "WHOOP historical Type-47 v18 archive: \(historicalRRArchiveRecordCount) raw frames · latest HR: \(whoopHistoricalHeartRateBPM.map(String.init) ?? "none") bpm · physiological timestamp: \(whoopHistoricalTimestampLastUpdatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none") · source: \(whoopHistoricalRRSource)",
            "WHOOP IMU recent CRC-valid raw frames (oldest first):",
        ]
        lines.append(contentsOf: whoopIMURawFrameHistory.isEmpty ? ["  none"] : whoopIMURawFrameHistory.map { "  \($0)" })
        lines.append("")
        lines.append("WHOOP standard 2A37 raw notifications (oldest first):")
        lines.append(contentsOf: whoopStandardHeartRateRawFrameHistory.isEmpty ? ["  No 2A37 notifications captured"] : whoopStandardHeartRateRawFrameHistory.map { "  \($0)" })
        lines.append("")
        lines.append("WHOOP realtime Type-40 raw frames (oldest first):")
        lines.append(contentsOf: whoopRealtimeRRRawFrameHistory.isEmpty ? ["  No Type-40 raw frames captured"] : whoopRealtimeRRRawFrameHistory.map { "  \($0)" })
        lines.append(contentsOf: [
            "WHOOP protocol diagnosis: \(whoopProtocolDiagnostics)",
            "WHOOP packet counts · realtime: \(whoopRealtimePacketCount) · command responses: \(whoopCommandResponseCount)",
            "WHOOP last packet type: \(whoopLastPacketType)",
            "WHOOP FD4B vendor notification subscriptions:",
            "",
            "GATT profile:"
        ])
        lines.append(contentsOf: vendorNotificationStates.keys.sorted().map { "  \($0): \(vendorNotificationStates[$0] ?? "unknown")" })
        lines.append(contentsOf: vendorNotificationPayloads.keys.sorted().map { "  Latest full payload \($0): \(vendorNotificationPayloads[$0] ?? "none")" })
        lines.append("")
        lines.append("WHOOP vendor notification history (latest 40 events):")
        lines.append(contentsOf: vendorNotificationHistory.isEmpty ? ["  No vendor payload events captured"] : vendorNotificationHistory)
        lines.append("")
        lines.append("WHOOP Puffin event transport raw frames (types 53/54; newest last):")
        lines.append(contentsOf: whoopPuffinEventFrameHistory.isEmpty ? ["  No type-53/type-54 frames captured"] : whoopPuffinEventFrameHistory.map { "  \($0)" })
        lines.append("")
        lines.append("WHOOP BLE connection timeline (latest 100 events):")
        lines.append(contentsOf: vendorNotificationTimeline.isEmpty ? ["  No connection timeline events captured"] : vendorNotificationTimeline.map { "  \($0)" })
        lines.append("")
        lines.append("WHOOP archive candidate-channel probe (passive notifications only):")
        lines.append(contentsOf: candidateNotificationStates.keys.sorted().map { "  \($0): \(candidateNotificationStates[$0] ?? "unknown")" })
        lines.append(contentsOf: candidateNotificationHistory.isEmpty ? ["  No candidate-channel payloads captured"] : candidateNotificationHistory)
        lines.append(contentsOf: discoveredProfile.isEmpty ? ["No GATT profile captured"] : discoveredProfile)
        lines.append("")
        lines.append("Note: WHOOP 5.0 frames are checked with header CRC16-Modbus and payload CRC32. HR stream activation is tracked separately from notification subscription.")
        return lines.joined(separator: "\n")
    }

    /// Compact, bounded summary of which GATT channels actually delivered notifications
    /// and which CRC-valid WHOOP Gen5 frame types arrived on each channel.
    private var whoopPerChannelTelemetrySummary: String {
        let channelIDs = Set(vendorNotificationCountsByChannel.keys)
            .union(whoopPacketTypeCountsByChannel.keys)
            .union(whoopRejectedFrameCountsByChannel.keys)
        guard !channelIDs.isEmpty else { return "none" }
        return channelIDs.sorted().map { channel in
            let notificationCount = vendorNotificationCountsByChannel[channel] ?? 0
            let byteCount = vendorNotificationBytesByChannel[channel] ?? 0
            let packetCounts = whoopPacketTypeCountsByChannel[channel] ?? [:]
            let packetSummary = packetCounts.keys.sorted().map { type in
                "\(type):\(packetCounts[type] ?? 0)"
            }.joined(separator: ", ")
            let lastType = whoopLastPacketTypeByChannel[channel].map(String.init) ?? "none"
            let rejected = whoopRejectedFrameCountsByChannel[channel] ?? 0
            let lastAt = vendorNotificationLastAtByChannel[channel]
                .map { ISO8601DateFormatter().string(from: $0) } ?? "none"
            return "\(channel): notifications=\(notificationCount), bytes=\(byteCount), validTypes=[\(packetSummary.isEmpty ? "none" : packetSummary)], lastType=\(lastType), crcRejected=\(rejected), lastAt=\(lastAt)"
        }.joined(separator: " | ")
    }

    private func propertyNames(_ properties: CBCharacteristicProperties) -> String {
        var values: [String] = []
        if properties.contains(.read) { values.append("read") }
        if properties.contains(.write) { values.append("write") }
        if properties.contains(.writeWithoutResponse) { values.append("write-no-response") }
        if properties.contains(.notify) { values.append("notify") }
        if properties.contains(.indicate) { values.append("indicate") }
        if properties.contains(.broadcast) { values.append("broadcast") }
        return values.isEmpty ? "no common properties" : values.joined(separator: ", ")
    }
}

extension WhoopBluetoothManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let peripheral = restored.first else {
            lastBLEEvent = "CoreBluetooth restoration callback received · no peripheral to restore"
            return
        }

        connectedPeripheral = peripheral
        connectedDeviceSnapshot = nil
        peripheral.delegate = self
        isConnecting = peripheral.state != .connected
        connectedName = peripheral.name ?? "WHOOP"
        lastBLEEvent = "CoreBluetooth restored WHOOP peripheral · \(peripheral.identifier.uuidString)"

        pendingRestoredPeripheral = peripheral
        statusText = "WHOOP peripheral restored · waiting for Bluetooth to become ready"
        resumeRestoredPeripheralIfPossible()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            scanTimeoutWorkItem?.cancel()
            scanTimeoutWorkItem = nil
            cancelAutomaticReconnectScan()
            scanTimeoutWorkItem?.cancel()
            scanTimeoutWorkItem = nil
        }
        switch central.state {
        case .poweredOn:
            statusText = connectedPeripheral == nil ? "Bluetooth ready" : "Bluetooth ready · restoring connection state"
            resumeRestoredPeripheralIfPossible()
        case .poweredOff:
            clearConnectionState()
            statusText = "Bluetooth is off"
        case .unauthorized:
            clearConnectionState()
            statusText = "Bluetooth permission not granted"
        case .unsupported:
            clearConnectionState()
            statusText = "Bluetooth LE is unavailable"
        case .resetting:
            clearConnectionState()
            statusText = "Bluetooth is resetting"
        case .unknown:
            statusText = "Bluetooth state unknown"
        @unknown default:
            statusText = "Bluetooth state unavailable"
        }
    }

    private func resumeRestoredPeripheralIfPossible() {
        guard central.state == .poweredOn else { return }
        let peripheral: CBPeripheral?
        if let pendingRestoredPeripheral {
            peripheral = pendingRestoredPeripheral
        } else if let rawID = UserDefaults.standard.string(forKey: rememberedPeripheralKey),
                  let identifier = UUID(uuidString: rawID) {
            peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first
        } else {
            peripheral = nil
        }
        guard let peripheral else {
            // CoreBluetooth may no longer have a cached CBPeripheral after a
            // force-quit. Keep the saved identifier and wait for a later manual scan.
            statusText = "Bluetooth ready · searching for previously used WHOOP"
            if !isAutomaticReconnectScan {
                isAutomaticReconnectScan = true
                let scanToken = UUID()
                automaticReconnectScanToken = scanToken
                central.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self,
                          self.isAutomaticReconnectScan,
                          self.automaticReconnectScanToken == scanToken else { return }
                    self.central.stopScan()
                    self.isAutomaticReconnectScan = false
                    self.automaticReconnectScanToken = UUID()
                    self.statusText = "WHOOP not found · open Device and tap Scan to retry"
                }
            }
            return
        }

        pendingRestoredPeripheral = nil
        if connectedPeripheral?.identifier == peripheral.identifier,
           isConnecting, peripheral.state == .connecting {
            // CoreBluetooth may deliver restoration and poweredOn callbacks close
            // together. Keep the existing in-flight connection and its timeout.
            return
        }
        connectedPeripheral = peripheral
        connectedDeviceSnapshot = nil
        peripheral.delegate = self
        connectedName = peripheral.name ?? "WHOOP"
        resetGattSessionForReconnect()

        if peripheral.state == .connected {
            connectionTimeoutWorkItem?.cancel()
            connectionTimeoutWorkItem = nil
            isConnecting = false
            statusText = "WHOOP connection recovered · rediscovering services"
            lastBLEEvent = "Recovered existing CoreBluetooth peripheral · refreshing GATT"
            peripheral.discoverServices(nil)
        } else if peripheral.state == .connecting {
            isConnecting = true
            statusText = "WHOOP connection restoration in progress"
            lastBLEEvent = "CoreBluetooth already connecting restored WHOOP peripheral"
            scheduleReconnectTimeout(for: peripheral)
        } else {
            isConnecting = true
            statusText = "Reconnecting to previously used WHOOP…"
            lastBLEEvent = "Automatic reconnect requested for remembered WHOOP peripheral"
            central.connect(peripheral, options: nil)
            scheduleReconnectTimeout(for: peripheral)
        }
    }

    private func resetGattSessionForReconnect() {
        // Never carry an HR baseline or candidate across BLE sessions.
        // A quick reconnect must not stitch old samples into a new workout.
        workoutDetectionSamples.removeAll()
        workoutDetectionCandidateSince = nil
        workoutDetectionCandidateBaselineBPM = nil
        workoutRecoverySince = nil
        pendingCharacteristicServices.removeAll()
        pendingDescriptorCharacteristics.removeAll()
        gattCharacteristicDiscoveryErrors.removeAll()
        discoveredProfile.removeAll()
        vendorNotificationStates.removeAll()
        vendorNotificationPayloads.removeAll()
        vendorNotificationHistory.removeAll()
        vendorNotificationCountsByChannel.removeAll()
        vendorNotificationBytesByChannel.removeAll()
        vendorNotificationLastAtByChannel.removeAll()
        whoopPacketTypeCountsByChannel.removeAll()
        whoopLastPacketTypeByChannel.removeAll()
        whoopRejectedFrameCountsByChannel.removeAll()
        whoopPuffinEventCountsByChannel.removeAll()
        whoopPuffinEventTypeCounts.removeAll()
        whoopPuffinEventFrameHistory.removeAll()
        whoopEventProbeRearmWorkItem?.cancel()
        whoopEventProbeRearmWorkItem = nil
        whoopEventProbeFinishWorkItem?.cancel()
        whoopEventProbeFinishWorkItem = nil
        whoopEventProbeActive = false
        whoopEventProbeOffSequence = nil
        whoopEventProbeOnSequence = nil
        whoopEventProbeStartedAt = nil
        whoopEventProbeStatus = "Controlled Event 33/34 probe not run in this connection"
        vendorNotificationTimeline.removeAll()
        whoop5FragmentBuffers.removeAll()
        whoop5ExpectedFrameLengths.removeAll()
        candidateNotificationStates.removeAll()
        candidateNotificationHistory.removeAll()
        whoop5CommandCharacteristic = nil
        whoop5HelloSent = false
        whoop5HelloWritePending = false
        whoop5HelloWriteAcknowledged = false
        whoopSessionPhase = "GATT session reset · awaiting discovery"
        whoop5PostHelloNotifyRetryAttempted.removeAll()
        // Cancel any quiet-period callback before rebuilding the GATT session.
        whoop5HRStallRecoveryWorkItem?.cancel()
        whoop5HRStallRecoveryWorkItem = nil
        whoop5HRStallRecoveryAttempted = false
        whoop5HRStreamEnableSent = false
        whoop5HRStreamConfirmed = false
        whoop5Type40FrameObserved = false
        whoopRealtimeCandidateRRWords.removeAll()
        whoopRealtimeCandidateByteAt16 = nil
        whoopRealtimeCandidateStatus = "No Type-40 candidate frame captured"
        whoop5AutoIMUStartRequested = false
        whoop5AutoIMUEnabled = false
        whoop5IMUModeEnableSequence = nil
        whoop5IMUModeTargetEnabled = nil
        whoop5RawStartSequence = nil
        whoop5RawStopSequence = nil
        whoop5RawStreamStopWorkItem?.cancel()
        whoop5RawStreamStopWorkItem = nil
        whoop5RawStreamRearmWorkItem?.cancel()
        whoop5RawStreamRearmWorkItem = nil
        // Keep the last known battery reading across BLE reconnects; WHOOP does not
        // necessarily emit BATTERY_LEVEL on every connection.
        whoopEventPacketCount = 0
        whoopLastEventID = nil
        whoopLastEventFrameHex = "none"
        whoopEventCountsByChannel.removeAll()
        whoopEvent33Count = 0
        whoopEvent34Count = 0
        whoopLastEventChannel = "none"
        whoopLastEvent33FrameHex = "none"
        whoopLastEvent33At = nil
        whoopLastEvent34FrameHex = "none"
        whoopLastEvent34At = nil
        whoopPuffinEventCountsByChannel.removeAll()
        whoopPuffinEventTypeCounts.removeAll()
        whoopPuffinEventFrameHistory.removeAll()
        whoopEventProbeRearmWorkItem?.cancel()
        whoopEventProbeRearmWorkItem = nil
        whoopEventProbeFinishWorkItem?.cancel()
        whoopEventProbeFinishWorkItem = nil
        whoopEventProbeActive = false
        whoopEventProbeOffSequence = nil
        whoopEventProbeOnSequence = nil
        whoopEventProbeStartedAt = nil
        whoopEventProbeStatus = "Controlled Event 33/34 probe not run in this connection"
        whoopIMUFrameCount = 0
        whoopIMUSampleCount = 0
        whoopIMULastFrameAt = nil
        whoopIMULastRawFrameHex = "none"
        whoopIMURawFrameHistory.removeAll()
        liveWhoopIMUSamples.removeAll()
        liveWhoopIMUSampleBuffer.removeAll()
        lastLiveIMUSnapshotPublishedAt = nil
        whoopIMUStatus = "Waiting for WHOOP motion stream"
        whoopRRIntervalsMilliseconds.removeAll()
        whoopStandardRRIntervalsMilliseconds.removeAll()
        whoopStandardRRLastUpdatedAt = nil
        whoopRRWindowMilliseconds.removeAll()
        whoopLiveRMSSDMilliseconds = nil
        whoopRRLastUpdatedAt = nil
        whoopRRSource = "Waiting for WHOOP RR intervals"
        whoop5PendingWrites.removeAll()
        whoop5NextCommandSequence = 2
        whoop5HistorySyncStarted = false
        whoop5HistorySyncRequested = false
        whoop5HistoryClockSequence = nil
        whoop5HistoryRangeSequence = nil
        whoop5HistoryRequestSequence = nil
        whoop5HelloRevision = nil
        whoop5HelloTimestampSeconds = nil
        whoop5HelloTimestampSubseconds = nil
        whoopHistorySyncStatus = "Waiting for WHOOP 5 historical sync request"
        isStandardHeartRateNotifying = false
        liveHeartRateBPM = nil
        lastHeartRateAt = nil
        heartRateUpdateCount = 0
        liveHeartRateSamples.removeAll()
        hrTimingConnectionAt = Date()
        hrTimingStandardNotifyRequestedAt = nil
        hrTimingStandardNotifyEnabledAt = nil
        hrTimingFirstSampleAt = nil
        hrTimingEvents.removeAll()
    }

    private func scheduleReconnectTimeout(for peripheral: CBPeripheral) {
        connectionTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  self.isConnecting else { return }
            self.central.cancelPeripheralConnection(peripheral)
            self.clearConnectionState()
            self.statusText = "Automatic reconnect timed out · tap Scan to retry"
            self.lastBLEEvent = "Automatic reconnect timed out before CoreBluetooth callback"
        }
        connectionTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func clearConnectionState() {
        // Preserve any partial historical transfer before resetting BLE state.
        if !flushHistoricalRRArchive() {
            recordVendorTimeline("Disconnect with historical RR archive flush failure · queued frames remain in memory until process exit")
        }
        // A disconnect breaks detector continuity; discard the rolling baseline.
        workoutDetectionSamples.removeAll()
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        // A delayed HR-stall recovery must not issue a WHOOP command after disconnect.
        whoop5HRStallRecoveryWorkItem?.cancel()
        whoop5HRStallRecoveryWorkItem = nil
        whoop5HRStallRecoveryAttempted = false
        pendingCharacteristicServices.removeAll()
        pendingDescriptorCharacteristics.removeAll()
        connectedName = nil
        connectedDeviceSnapshot = nil
        whoopSessionPhase = "Disconnected"
        if workoutIsRecording {
            if let workoutStartedAt {
                lastWorkoutDurationSeconds = Date().timeIntervalSince(workoutStartedAt)
                lastWorkoutStartedAt = workoutStartedAt
            }
            lastWorkoutWasAutomatic = workoutRecordingIsAutomatic
            lastWorkoutWasInterrupted = true
            archiveCurrentWorkout(startedAt: workoutStartedAt ?? Date(),
                                  duration: lastWorkoutDurationSeconds ?? 0,
                                  automatic: workoutRecordingIsAutomatic,
                                  interrupted: true)
            // Preserve the partial session, but never leave the UI claiming that
            // a workout is still recording after its HR source has disconnected.
            workoutIsRecording = false
            workoutStartedAt = nil
            workoutRecordingIsAutomatic = false
            workoutSessionBaselineBPM = nil
            workoutDetectionCandidateSince = nil
            workoutDetectionCandidateBaselineBPM = nil
            workoutRecoverySince = nil
            workoutDetectionStatus = "Workout interrupted · band disconnected · partial data saved"
            persistWorkoutSession()
        } else {
            workoutDetectionCandidateSince = nil
            workoutDetectionCandidateBaselineBPM = nil
            workoutRecoverySince = nil
        }
        liveHeartRateBPM = nil
        liveHeartRateSamples.removeAll()
        isStandardHeartRateNotifying = false
        lastHeartRateAt = nil
        heartRateUpdateCount = 0
        vendorNotificationStates.removeAll()
        vendorNotificationPayloads.removeAll()
        vendorNotificationHistory.removeAll()
        vendorNotificationCountsByChannel.removeAll()
        vendorNotificationBytesByChannel.removeAll()
        vendorNotificationLastAtByChannel.removeAll()
        whoopPacketTypeCountsByChannel.removeAll()
        whoopLastPacketTypeByChannel.removeAll()
        whoopRejectedFrameCountsByChannel.removeAll()
        vendorNotificationTimeline.removeAll()
        whoop5FragmentBuffers.removeAll()
        whoop5ExpectedFrameLengths.removeAll()
        candidateNotificationStates.removeAll()
        candidateNotificationHistory.removeAll()
        whoop5CommandCharacteristic = nil
        whoop5HelloSent = false
        whoop5HelloWritePending = false
        whoop5HelloWriteAcknowledged = false
        whoop5PostHelloNotifyRetryAttempted.removeAll()
        whoop5HRStreamEnableSent = false
        whoop5HRStreamConfirmed = false
        whoop5Type40FrameObserved = false
        whoopRealtimeCandidateRRWords.removeAll()
        whoopRealtimeCandidateByteAt16 = nil
        whoopRealtimeCandidateStatus = "No Type-40 candidate frame captured"
        whoop5AutoIMUStartRequested = false
        whoop5AutoIMUEnabled = false
        whoop5RawStreamStopWorkItem?.cancel()
        whoop5RawStreamStopWorkItem = nil
        whoopIMUFrameCount = 0
        whoopIMUSampleCount = 0
        whoopIMULastFrameAt = nil
        liveWhoopIMUSamples.removeAll()
        liveWhoopIMUSampleBuffer.removeAll()
        lastLiveIMUSnapshotPublishedAt = nil
        whoopIMUStatus = "Waiting for WHOOP motion stream"
        whoopRRIntervalsMilliseconds.removeAll()
        whoopRRWindowMilliseconds.removeAll()
        whoopLiveRMSSDMilliseconds = nil
        whoopRRLastUpdatedAt = nil
        whoopRRSource = "Waiting for WHOOP RR intervals"
        whoop5PendingWrites.removeAll()
        whoop5NextCommandSequence = 2
        whoop5HistorySyncStarted = false
        whoop5HistorySyncRequested = false
        whoop5HistoryClockSequence = nil
        whoop5HistoryRangeSequence = nil
        whoop5HistoryRequestSequence = nil
        whoop5HelloRevision = nil
        whoop5HelloTimestampSeconds = nil
        whoop5HelloTimestampSubseconds = nil
        whoopHistorySyncStatus = "Waiting for WHOOP 5 historical sync request"
        isConnecting = false
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        discoveredProfile.removeAll()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "Unknown BLE device"
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let solicitedServices = advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? []
        let overflowServices = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let advertisedUUIDs = advertisedServices + Array(serviceData.keys) + solicitedServices + overflowServices
        let hasCandidateService = advertisedUUIDs.contains {
            candidateUUIDs.contains($0.uuidString.uppercased())
        }
        if let rememberedID = UserDefaults.standard.string(forKey: rememberedPeripheralKey),
           peripheral.identifier.uuidString == rememberedID,
           isAutomaticReconnectScan {
            cancelAutomaticReconnectScan()
            connectedPeripheral = peripheral
            connectedDeviceSnapshot = nil
            peripheral.delegate = self
            isConnecting = true
            connectedName = peripheral.name ?? "WHOOP"
            resetGattSessionForReconnect()
            lastBLEEvent = "Remembered WHOOP found during automatic reconnect scan"
            statusText = "Reconnecting to WHOOP…"
            central.connect(peripheral, options: nil)
            scheduleReconnectTimeout(for: peripheral)
            return
        }
        guard name.localizedCaseInsensitiveContains("whoop") || hasCandidateService else { return }

        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber
        let item = DiscoveredWearable(
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            advertisedServices: advertisedServices.map { $0.uuidString.uppercased() }.sorted(),
            serviceDataEntries: serviceData
                .map { "\($0.key.uuidString.uppercased()) (\($0.value.count) bytes)" }.sorted(),
            solicitedServices: solicitedServices.map { $0.uuidString.uppercased() }.sorted(),
            overflowServices: overflowServices.map { $0.uuidString.uppercased() }.sorted(),
            manufacturerDataByteCount: manufacturerData?.count,
            transmitPower: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
            isConnectable: connectable?.boolValue
        )
        if let index = devices.firstIndex(where: { $0.id == item.id }) {
            devices[index] = item
        } else {
            devices.append(item)
        }
        devices.sort { $0.rssi > $1.rssi }
        statusText = devices.isEmpty ? "No WHOOP candidate found yet" : "Found \(devices.count) candidate device(s)"
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        // Every successful link starts a fresh GATT session. Manual reconnects
        // must reset the same one-shot recovery flags and packet buffers as
        // automatic reconnects, otherwise a prior session can suppress recovery.
        resetGattSessionForReconnect()
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        automaticReconnectAttempt = 0
        isConnecting = false
        peripheral.delegate = self
        connectedName = peripheral.name ?? "WHOOP candidate"
        statusText = "Connected · discovering GATT profile"
        whoopConnectionGeneration += 1
        whoopSessionPhase = "Connected · discovering GATT profile"
        hrTimingConnectionAt = Date()
        hrTimingEvents = ["connected +0.000s"]
        recordVendorTimeline("peripheral connected · \(peripheral.identifier.uuidString)")
        lastBLEEvent = "Connected · waiting for characteristic value"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        let shouldRetry = UserDefaults.standard.string(forKey: rememberedPeripheralKey) == peripheral.identifier.uuidString
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        clearConnectionState()
        let reason = error?.localizedDescription ?? "unknown error"
        if shouldRetry && central.state == .poweredOn {
            lastBLEEvent = "WHOOP connection attempt failed · \(reason) · retry scheduled"
            scheduleAutomaticReconnect(for: peripheral, reason: reason)
        } else {
            statusText = "Connection failed: \(reason)"
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        let wasRememberedDevice =
            UserDefaults.standard.string(forKey: rememberedPeripheralKey) == peripheral.identifier.uuidString
        clearConnectionState()

        // An explicit in-app disconnect removes the remembered UUID before
        // CoreBluetooth calls back. If the UUID is still saved, this was an
        // unexpected link loss and the app should restore its background BLE
        // session instead of silently remaining disconnected.
        guard wasRememberedDevice, central.state == .poweredOn else {
            statusText = error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected"
            return
        }

        scheduleAutomaticReconnect(for: peripheral,
                                    reason: error?.localizedDescription ?? "link lost")
    }

    private func scheduleAutomaticReconnect(for peripheral: CBPeripheral, reason: String) {
        guard central.state == .poweredOn,
              UserDefaults.standard.string(forKey: rememberedPeripheralKey) == peripheral.identifier.uuidString else {
            statusText = "WHOOP disconnected · automatic reconnect unavailable"
            return
        }
        guard let delay = ReconnectBackoffPolicy.delay(forAttempt: automaticReconnectAttempt) else {
            statusText = "WHOOP reconnect paused after \(ReconnectBackoffPolicy.maximumAttempts) attempts · tap Scan to retry"
            lastBLEEvent = "Automatic reconnect limit reached · \(reason)"
            return
        }
        reconnectWorkItem?.cancel()
        automaticReconnectAttempt += 1
        let attempt = automaticReconnectAttempt
        connectedPeripheral = peripheral
        connectedDeviceSnapshot = nil
        peripheral.delegate = self
        connectedName = peripheral.name ?? "WHOOP"
        isConnecting = true
        resetGattSessionForReconnect()
        statusText = "WHOOP reconnecting · attempt \(attempt)/\(ReconnectBackoffPolicy.maximumAttempts) in \(Int(delay))s"
        lastBLEEvent = "Automatic reconnect scheduled · attempt \(attempt)/\(ReconnectBackoffPolicy.maximumAttempts) · \(reason)"
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  self.central.state == .poweredOn,
                  UserDefaults.standard.string(forKey: self.rememberedPeripheralKey) == peripheral.identifier.uuidString else { return }
            self.statusText = "WHOOP reconnecting · attempt \(attempt)/\(ReconnectBackoffPolicy.maximumAttempts)"
            self.central.connect(peripheral, options: nil)
            self.scheduleReconnectTimeout(for: peripheral)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension WhoopBluetoothManager: CBPeripheralDelegate {
    /// CoreBluetooth can deliver callbacks for characteristic instances that were
    /// discovered before a service invalidation/reconnect. Matching only the
    /// peripheral UUID is insufficient when the same peripheral is rediscovered.
    /// Accept a callback only when its exact service/characteristic object still
    /// belongs to the peripheral's current GATT tree.
    private func isCurrentGattService(_ service: CBService, on peripheral: CBPeripheral) -> Bool {
        peripheral.services?.contains(where: { $0 === service }) == true
    }

    private func isCurrentGattCharacteristic(_ characteristic: CBCharacteristic,
                                             on peripheral: CBPeripheral) -> Bool {
        guard let service = characteristic.service,
              isCurrentGattService(service, on: peripheral),
              let currentCharacteristics = service.characteristics else {
            return false
        }
        return currentCharacteristics.contains(where: { $0 === characteristic })
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        let invalidatedIDs = Array(Set(invalidatedServices.map { $0.uuid.uuidString })).sorted()
        let invalidatedSummary = invalidatedIDs.isEmpty ? "unspecified services" : invalidatedIDs.joined(separator: ", ")

        // Service invalidation invalidates the old CBCharacteristic instances too.
        // Start a clean GATT session so we rediscover the command characteristic,
        // resend CLIENT_HELLO once, and rebuild notification state against fresh
        // characteristic objects instead of retaining stale session flags.
        resetGattSessionForReconnect()
        peripheral.delegate = self
        recordVendorTimeline("GATT services invalidated · \(invalidatedSummary) · restarting GATT session")
        lastBLEEvent = "GATT services invalidated · \(invalidatedSummary) · refreshing profile"
        statusText = "GATT services changed · restarting WHOOP handshake"
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if let error {
            pendingCharacteristicServices.removeAll()
            pendingDescriptorCharacteristics.removeAll()
            statusText = "Service discovery failed: \(error.localizedDescription)"
            lastBLEEvent = "Service discovery error · \(error.localizedDescription)"
            recordVendorTimeline("service discovery failed · \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            pendingCharacteristicServices.removeAll()
            pendingDescriptorCharacteristics.removeAll()
            statusText = "Connected · service list unavailable"
            return
        }
        pendingCharacteristicServices = Set(services.map { ObjectIdentifier($0) })
        recordVendorTimeline("services discovered · \(services.count) · \(services.map { $0.uuid.uuidString }.joined(separator: ","))")
        whoopSessionPhase = "Discovering characteristics · \(services.count) services"
        guard !services.isEmpty else {
            pendingCharacteristicServices.removeAll()
            pendingDescriptorCharacteristics.removeAll()
            statusText = "Connected · no GATT services exposed"
            return
        }
        for service in services {
            discoveredProfile.append("Service · \(service.uuid.uuidString) · \(service.isPrimary ? "primary" : "secondary")")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        statusText = "Found \(services.count) service(s) · inspecting characteristics"
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              isCurrentGattCharacteristic(characteristic, on: peripheral) else { return }
        if let error {
            lastBLEEvent = "Read/notification error · \(characteristic.uuid.uuidString) · \(error.localizedDescription)"
            return
        }
        if characteristic.service?.uuid == CBUUID(string: "FD4B0001-CCE1-4033-93CE-002D5875F58A") {
            let uuid = characteristic.uuid.uuidString.uppercased()
            let data = characteristic.value ?? Data()
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            let now = Date()
            vendorNotificationCountsByChannel[uuid, default: 0] += 1
            vendorNotificationBytesByChannel[uuid, default: 0] += data.count
            vendorNotificationLastAtByChannel[uuid] = now
            let timestamp = ISO8601DateFormatter().string(from: now)
            whoopProtocolDiagnostics = ingestWhoop5Notification(data, channel: uuid, peripheral: peripheral)
            if vendorNotificationTimeline.first(where: { $0.contains("first vendor payload") }) == nil {
                recordVendorTimeline("first vendor payload · \(uuid) · \(data.count) bytes")
            }
            vendorNotificationPayloads[uuid] = "\(data.count) bytes · \(hex.isEmpty ? "empty" : hex)"
            vendorNotificationHistory.append("\(timestamp) · \(uuid) · \(data.count) bytes · HEX: \(hex.isEmpty ? "empty" : hex) · \(whoopProtocolDiagnostics)")
            if vendorNotificationHistory.count > 40 {
                vendorNotificationHistory.removeFirst(vendorNotificationHistory.count - 40)
            }
            lastBLEEvent = "WHOOP vendor notification · \(uuid) · \(data.count) bytes · \(timestamp)"
            return
        }
        let incomingUUID = characteristic.uuid.uuidString.uppercased()
        if motionProbeUUIDPrefixes.contains(where: { incomingUUID.hasPrefix($0) }) {
            let data = characteristic.value ?? Data()
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            let timestamp = ISO8601DateFormatter().string(from: Date())
            candidateNotificationHistory.append("\(timestamp) · \(incomingUUID) · \(data.count) bytes · HEX: \(hex)")
            if candidateNotificationHistory.count > 80 { candidateNotificationHistory.removeFirst(candidateNotificationHistory.count - 80) }
            lastBLEEvent = "WHOOP archive candidate notification · \(incomingUUID) · \(data.count) bytes"
            return
        }
        guard characteristic.service?.uuid == CBUUID(string: "180D"),
              characteristic.uuid == CBUUID(string: "2A37") else {
            let byteCount = characteristic.value?.count ?? 0
            let timestamp = ISO8601DateFormatter().string(from: Date())
            lastBLEEvent = "BLE value received · \(characteristic.uuid.uuidString) · \(byteCount) bytes · unclassified payload · \(timestamp)"
            return
        }
        guard let data = characteristic.value else {
            lastBLEEvent = "Standard HR notification received · payload missing"
            return
        }
        // Preserve exact 2A37 bytes before interpreting flags, offsets or RR values.
        let rawTimestamp = ISO8601DateFormatter().string(from: Date())
        let rawHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        whoopStandardHeartRateRawFrameHistory.append(
            "\(rawTimestamp) · 2A37 · \(data.count) bytes · HEX: \(rawHex)"
        )
        if whoopStandardHeartRateRawFrameHistory.count > 100 {
            whoopStandardHeartRateRawFrameHistory.removeFirst(
                whoopStandardHeartRateRawFrameHistory.count - 100
            )
        }
        guard let bpm = parseStandardHeartRateMeasurement(data),
              (1...300).contains(bpm) else {
            lastBLEEvent = "Standard HR notification received · raw bytes retained · payload could not be parsed"
            return
        }
        // Type-40 inner fields remain unverified. Until matched to WHOOP IPA/device
        // evidence, Bluetooth SIG 2A37 is the trusted live HR and millisecond-RR source.
        let standardRR = StandardHeartRateRRParser.parseMilliseconds(data)
        if !standardRR.isEmpty {
            whoopStandardRRIntervalsMilliseconds = standardRR
            whoopStandardRRLastUpdatedAt = Date()
            dashboardStandardRRHistory.append(contentsOf: standardRR.map {
                PersistedRRIntervalSample(timestamp: Date(), intervalMilliseconds: $0)
            })
            if dashboardStandardRRHistory.count > 20_000 {
                dashboardStandardRRHistory.removeFirst(dashboardStandardRRHistory.count - 20_000)
            }
            persistDashboardHistory()
            appendRRIntervals(standardRR, source: "WHOOP standard 2A37")
        }
        recordHeartRateSample(bpm, source: "WHOOP standard BLE HR")
    }

    private func updateGattDiscoveryCompletionStatus() {
        guard pendingCharacteristicServices.isEmpty && pendingDescriptorCharacteristics.isEmpty else { return }
        let errorCount = discoveredProfile.filter {
            $0.hasPrefix("Service error ·") || $0.hasPrefix("Descriptor error ·")
        }.count
        let inspection = errorCount == 0
            ? "GATT profile and descriptors inspected"
            : "GATT inspection finished · \(errorCount) discovery error(s)"
        if isStandardHeartRateNotifying {
            if let bpm = freshHeartRateBPM {
                statusText = "Live HR · \(bpm) bpm · \(heartRateUpdateCount) update(s) · \(inspection)"
            } else {
                statusText = "Connected · HR notifications enabled · waiting for first sample · \(inspection)"
            }
        } else {
            statusText = "Connected · HR notification not enabled yet · \(inspection)"
        }
    }

    /// Stitch WHOOP protocol frames split across BLE notification values.
    /// Buffers are isolated by characteristic; unframed payloads remain diagnostic-only.
    private func ingestWhoop5Notification(_ chunk: Data, channel: String, peripheral: CBPeripheral) -> String {
        // Treat notification values as a byte stream: a frame may span several
        // notifications, and one notification may contain more than one frame.
        var buffer = whoop5FragmentBuffers[channel] ?? Data()
        if buffer.isEmpty {
            let incoming = [UInt8](chunk)
            // A BLE notification boundary may split the two-byte 0xAA 0x01
            // frame marker. Preserve a lone 0xAA (or scan forward to a marker)
            // instead of discarding the first byte before the next callback.
            let containsFrameMarker = incoming.count >= 2 &&
                (0..<(incoming.count - 1)).contains {
                    incoming[$0] == 0xAA && incoming[$0 + 1] == 0x01
                }
            guard incoming.first == 0xAA || containsFrameMarker else {
                return diagnoseWhoop5Frame(chunk, channel: channel, peripheral: peripheral)
            }
        }
        buffer.append(chunk)

        var diagnostics: [String] = []
        while !buffer.isEmpty {
            let bytes = [UInt8](buffer)

            // Resynchronise on the next frame marker without discarding a
            // possible 0xAA split across notification boundaries.
            if bytes.count < 2 { break }
            if bytes[0] != 0xAA || bytes[1] != 0x01 {
                if bytes.count >= 2,
                   let sync = (0..<(bytes.count - 1)).first(where: {
                       bytes[$0] == 0xAA && bytes[$0 + 1] == 0x01
                   }) {
                    buffer = Data(bytes[sync...])
                    continue
                }
                buffer = bytes.last == 0xAA ? Data([0xAA]) : Data()
                break
            }

            guard bytes.count >= 8 else { break }
            let declared = Int(bytes[2]) | (Int(bytes[3]) << 8)
            let frameLength = 8 + declared
            guard frameLength >= 12, frameLength <= 8192 else {
                diagnostics.append("WHOOP5 invalid declared frame length · \(frameLength)")
                buffer.removeFirst()
                continue
            }

            guard bytes.count >= frameLength else { break }
            let completeFrame = Data(bytes.prefix(frameLength))
            buffer.removeFirst(frameLength)
            diagnostics.append(diagnoseWhoop5Frame(completeFrame, channel: channel, peripheral: peripheral))
        }

        if buffer.count > 8192 {
            buffer.removeAll()
            diagnostics.append("WHOOP5 reassembly buffer exceeded safety limit · reset")
        }
        if buffer.isEmpty {
            whoop5FragmentBuffers.removeValue(forKey: channel)
            whoop5ExpectedFrameLengths.removeValue(forKey: channel)
        } else {
            whoop5FragmentBuffers[channel] = buffer
            let bytes = [UInt8](buffer)
            if bytes.count >= 4, bytes[0] == 0xAA, bytes[1] == 0x01 {
                whoop5ExpectedFrameLengths[channel] = 8 + Int(bytes[2]) + (Int(bytes[3]) << 8)
            }
            let expected = whoop5ExpectedFrameLengths[channel].map(String.init) ?? "header"
            diagnostics.append("WHOOP5 frame fragment · \(buffer.count)/\(expected) bytes")
        }

        return diagnostics.isEmpty
            ? "WHOOP5 awaiting frame continuation"
            : diagnostics.joined(separator: " · ")
    }

    /// WHOOP 5.0 frame validation and packet routing.
    /// The frame header uses CRC16-Modbus; the padded inner payload uses CRC32.
    private func diagnoseWhoop5Frame(_ data: Data, channel: String, peripheral: CBPeripheral) -> String {
        let b = [UInt8](data)
        guard b.count >= 13 else { return "Fragment/short frame · \(b.count) bytes" }
        guard b[0] == 0xAA, b[1] == 0x01 else {
            return "Unknown WHOOP5 frame prefix/revision · \(String(format: "%02X", b[0]))"
        }
        let declared = Int(b[2]) | (Int(b[3]) << 8)
        let expected = 8 + declared
        guard expected == b.count else {
            return "WHOOP5 length mismatch · expected \(expected), received \(b.count) · awaiting complete frame"
        }
        guard isValidWhoop5Frame(b) else {
            whoopRejectedFrameCountsByChannel[channel, default: 0] += 1
            return "WHOOP5 frame rejected · CRC16 header or CRC32 payload invalid"
        }

        let type = Int(b[8])
        whoopLastPacketType = "\(type)"
        whoopPacketTypeCountsByChannel[channel, default: [:]][type, default: 0] += 1
        whoopLastPacketTypeByChannel[channel] = type
        switch type {
        // The NOOP Gen5 reference routes PUFFIN_COMMAND_RESPONSE (38) through the command-response decoder.
        case 36, 38: // COMMAND_RESPONSE / PUFFIN_COMMAND_RESPONSE share command, sequence and result fields.
            whoopCommandResponseCount += 1
            let command = Int(b[10])
            guard b.count > 12 else { return "COMMAND_RESPONSE · cmd \(command) · truncated" }
            // WHOOP 5 response byte [9] echoes the host command-frame sequence.
            // Byte [11] is the strap's independent response counter; never correlate on it.
            let echoedHostSequence = Int(b[9])
            let responseCounter = Int(b[11])
            let result = Int(b[12])
            let resultName = [0: "FAILURE", 1: "SUCCESS", 2: "PENDING", 3: "UNSUPPORTED"][result] ?? "UNKNOWN(\(result))"
            recordVendorTimeline("COMMAND_RESPONSE · cmd=\(command) · hostSeq=\(echoedHostSequence) · responseCounter=\(responseCounter) · result=\(resultName) · frame=\(b.count) bytes · CRC valid")
            if command == 81,
               let expectedSequence = whoop5RawStartSequence,
               echoedHostSequence == Int(expectedSequence) {
                if result == 2 {
                    whoopIMUStatus = "START_RAW_DATA pending · awaiting final response"
                    return "COMMAND_RESPONSE · START_RAW_DATA(81) · PENDING"
                }
                whoop5RawStartSequence = nil
                guard result == 1 else {
                    whoop5AutoIMUStartRequested = false
                    whoopIMUStatus = "START_RAW_DATA rejected · \(resultName)"
                    recordVendorTimeline("START_RAW_DATA(81) rejected · \(resultName)")
                    return "COMMAND_RESPONSE · START_RAW_DATA(81) · \(resultName)"
                }
                whoop5AutoIMUEnabled = true
                whoopIMUStatus = "Raw capture accepted · enabling Gen5 IMU mode · awaiting Type-43"
                recordVendorTimeline("START_RAW_DATA(81) SUCCESS · now requesting TOGGLE_IMU_MODE ON")
                scheduleWhoop5RawStreamStop(for: peripheral, after: 60)
                sendWhoop5IMUModeToggle(to: peripheral, enabled: true)
                return "COMMAND_RESPONSE · START_RAW_DATA(81) SUCCESS · TOGGLE_IMU_MODE ON requested"
            }
            if command == 106,
               let expectedSequence = whoop5IMUModeEnableSequence,
               echoedHostSequence == Int(expectedSequence),
               let targetEnabled = whoop5IMUModeTargetEnabled {
                if result == 2 {
                    whoopIMUStatus = "Gen5 IMU mode \(targetEnabled ? "ON" : "OFF") pending · awaiting final response"
                    recordVendorTimeline("TOGGLE_IMU_MODE(106) \(targetEnabled ? "ON" : "OFF") response · PENDING")
                    return "COMMAND_RESPONSE · TOGGLE_IMU_MODE(106) · PENDING"
                }
                whoop5IMUModeEnableSequence = nil
                whoop5IMUModeTargetEnabled = nil
                guard result == 1 else {
                    whoopIMUStatus = "Gen5 IMU mode \(targetEnabled ? "ON" : "OFF") rejected · \(resultName)"
                    recordVendorTimeline("TOGGLE_IMU_MODE(106) \(targetEnabled ? "ON" : "OFF") rejected · \(resultName)")
                    if targetEnabled {
                        whoop5AutoIMUEnabled = false
                        whoop5AutoIMUStartRequested = false
                        whoop5RawStreamStopWorkItem?.cancel()
                    }
                    return "COMMAND_RESPONSE · TOGGLE_IMU_MODE(106) · \(resultName)"
                }
                if targetEnabled {
                    whoopIMUStatus = "IMU mode enabled · waiting for actual Type-43 motion packets"
                    recordVendorTimeline("TOGGLE_IMU_MODE(106) ON SUCCESS · waiting for Type-43 evidence")
                } else {
                    whoop5AutoIMUEnabled = false
                    whoop5AutoIMUStartRequested = false
                    whoopIMUStatus = "Raw stream and IMU mode stopped · scheduling next window"
                    recordVendorTimeline("TOGGLE_IMU_MODE(106) OFF SUCCESS · safe to re-arm")
                    scheduleWhoop5RawStreamRearm(for: peripheral, after: 3)
                }
                return "COMMAND_RESPONSE · TOGGLE_IMU_MODE(106) \(targetEnabled ? "ON" : "OFF") SUCCESS"
            }
            if command == 82,
               let expectedSequence = whoop5RawStopSequence,
               echoedHostSequence == Int(expectedSequence) {
                if result == 2 {
                    whoopIMUStatus = "STOP_RAW_DATA pending · awaiting final response"
                    return "COMMAND_RESPONSE · STOP_RAW_DATA(82) · PENDING"
                }
                whoop5RawStopSequence = nil
                guard result == 1 else {
                    whoopIMUStatus = "STOP_RAW_DATA rejected · \(resultName) · no automatic re-arm"
                    recordVendorTimeline("STOP_RAW_DATA(82) rejected · \(resultName) · re-arm withheld")
                    return "COMMAND_RESPONSE · STOP_RAW_DATA(82) · \(resultName)"
                }
                recordVendorTimeline("STOP_RAW_DATA(82) SUCCESS · requesting TOGGLE_IMU_MODE OFF")
                sendWhoop5IMUModeToggle(to: peripheral, enabled: false)
                return "COMMAND_RESPONSE · STOP_RAW_DATA(82) SUCCESS · TOGGLE_IMU_MODE OFF requested"
            }
            if command == 145 {
                // The Gen5 strap assigns its own response-frame sequence in byte [9].
                // It is NOT an echo of the fixed CLIENT_HELLO host sequence (1).
                // On-device capture: CLIENT_HELLO produced PENDING at response seq 58,
                // followed by SUCCESS at response seq 59; response counter [11] stayed 1.
                guard whoop5HelloSent, whoop5HelloWriteAcknowledged else {
                    return "COMMAND_RESPONSE · GET_HELLO ignored · no acknowledged CLIENT_HELLO · response seq \(echoedHostSequence) · \(resultName)"
                }
                if result == 2 {
                    recordVendorTimeline("GET_HELLO response · PENDING · strap response seq=\(echoedHostSequence) · responseCounter=\(responseCounter)")
                    return "COMMAND_RESPONSE · GET_HELLO · PENDING · strap response seq \(echoedHostSequence)"
                }
                guard result == 1 else {
                    recordVendorTimeline("GET_HELLO response · \(resultName) · strap response seq=\(echoedHostSequence)")
                    return "COMMAND_RESPONSE · GET_HELLO · \(resultName) · strap response seq \(echoedHostSequence)"
                }
                let responseHex = b.map { String(format: "%02X", $0) }.joined(separator: " ")
                recordVendorTimeline("GET_HELLO response raw HEX · strap response seq=\(echoedHostSequence) · \(responseHex)")
                // Gen5 HELLO revision-1 semantic body spans 104 bytes.
                guard b.count >= 121 else {
                    recordVendorTimeline("GET_HELLO response rejected · body too short · \(b.count) bytes")
                    return "COMMAND_RESPONSE · GET_HELLO success but body too short (\(b.count) bytes)"
                }
                recordVendorTimeline("GET_HELLO response accepted · strap response seq=\(echoedHostSequence) · success · minimum body length met")
                // Revision-1 Gen5 HELLO carries strap RTC at body[6..13]:
                // seconds:u32le + subseconds:u32le in 1/32768-second units.
                whoop5HelloRevision = Int(b[13])
                whoop5HelloTimestampSeconds = UInt32(b[19])
                    | (UInt32(b[20]) << 8) | (UInt32(b[21]) << 16) | (UInt32(b[22]) << 24)
                whoop5HelloTimestampSubseconds = UInt32(b[23])
                    | (UInt32(b[24]) << 8) | (UInt32(b[25]) << 16) | (UInt32(b[26]) << 24)
                whoop5HistorySyncRequested = true
                whoopSessionPhase = "GET_HELLO response parsed · requesting realtime HR and historical sync"
                sendRealtimeHrEnable(to: peripheral)
                return "COMMAND_RESPONSE · GET_HELLO(145) SUCCESS · CRC valid · realtime HR and history setup requested"
            }
            if command == 10, let sequence = whoop5HistoryClockSequence,
               echoedHostSequence == Int(sequence) {
                if result == 2 {
                    whoopHistorySyncStatus = "SET_CLOCK pending · waiting for terminal response"
                    recordVendorTimeline("Historical sync SET_CLOCK response · PENDING")
                    return "COMMAND_RESPONSE · SET_CLOCK(10) · PENDING"
                }
                guard result == 1 else {
                    whoopHistorySyncStatus = "Clock correction rejected · historical sync withheld · \(resultName)"
                    recordVendorTimeline("Historical sync SET_CLOCK response · \(resultName) · request withheld")
                    return "COMMAND_RESPONSE · SET_CLOCK(10) · \(resultName) · historical sync withheld"
                }
                recordVendorTimeline("Historical sync SET_CLOCK(10) confirmed · proceeding to GET_DATA_RANGE")
                requestWhoop5HistoricalDataRange(to: peripheral)
                return "COMMAND_RESPONSE · SET_CLOCK(10) SUCCESS · requesting GET_DATA_RANGE"
            }
            if command == 34, let sequence = whoop5HistoryRangeSequence,
               echoedHostSequence == Int(sequence) {
                recordVendorTimeline("Historical GET_DATA_RANGE(34) response · \(resultName)")
                return "COMMAND_RESPONSE · GET_DATA_RANGE(34) · \(resultName)"
            }
            if command == 22, let sequence = whoop5HistoryRequestSequence,
               echoedHostSequence == Int(sequence) {
                if result == 2 {
                    whoopHistorySyncStatus = "SEND_HISTORICAL_DATA pending · waiting for HISTORY_START"
                } else if result == 1 {
                    whoopHistorySyncStatus = "History request accepted · waiting for Type-47 / HISTORY markers"
                } else {
                    whoopHistorySyncStatus = "History request rejected · \(resultName)"
                }
                recordVendorTimeline("SEND_HISTORICAL_DATA(22) response · \(resultName)")
                return "COMMAND_RESPONSE · SEND_HISTORICAL_DATA(22) · \(resultName)"
            }
            if command == 3 {
                if let offSequence = whoopEventProbeOffSequence,
                   echoedHostSequence == Int(offSequence) {
                    recordVendorTimeline("Event probe OFF command response · seq=\(echoedHostSequence) · result=\(resultName) · 1.5s observation window")
                    if result != 2 { scheduleWhoopEventProbeRearm(after: 1.5) }
                    return "COMMAND_RESPONSE · Event probe REALTIME_HR_OFF(3) · seq \(echoedHostSequence) · \(resultName)"
                }
                if let onSequence = whoopEventProbeOnSequence,
                   echoedHostSequence == Int(onSequence) {
                    recordVendorTimeline("Event probe ON command response · seq=\(echoedHostSequence) · result=\(resultName)")
                    return "COMMAND_RESPONSE · Event probe REALTIME_HR_ON(3) · seq \(echoedHostSequence) · \(resultName)"
                }
                // Realtime-HR command success is not an IMU readiness signal.
                // Motion startup is gated exclusively by the CRC-valid Event 33 path.
                return "COMMAND_RESPONSE · REALTIME_HR_ON(3) · \(resultName) · IMU startup remains Event-33 gated"
            }
            return "COMMAND_RESPONSE · command \(command) · seq echo \(echoedHostSequence) · result \(resultName) · CRC valid"

        case 43: // Gen5 R21 realtime IMU buffer (0x2B); same v21 layout as historical 0x2F.
            whoopIMUFrameCount += 1
            whoopIMULastFrameAt = Date()
            whoopIMULastRawFrameHex = b.map { String(format: "%02X", $0) }.joined()
            let capturedAt = ISO8601DateFormatter().string(from: Date())
            whoopIMURawFrameHistory.append("type=43 · \(capturedAt) · \(whoopIMULastRawFrameHex)")
            if whoopIMURawFrameHistory.count > 4 {
                whoopIMURawFrameHistory.removeFirst(whoopIMURawFrameHistory.count - 4)
            }

            do {
                let decoded = try Gen5R21IMUDecoder.decode(b)
                guard !decoded.isEmpty else {
                    whoopIMUStatus = "Gen5 R21 frame valid · no paired samples · raw retained"
                    return "GEN5_R21_IMU(0x2B) · no paired samples"
                }
                appendLiveIMUSamples(decoded)
                appendVerifiedIMUHistory(decoded)
                if workoutIsRecording {
                    workoutWhoopIMUSamples.append(contentsOf: decoded)
                }
                whoopIMUSampleCount += decoded.count
                if workoutIsRecording,
                   workoutWhoopIMUSamples.count - lastWhoopIMUPersistedSampleCount >= 500 {
                    // Persist IMU in ~5-second batches at 100 Hz, not on every frame.
                    persistWorkoutSession()
                }
                whoopIMUStatus = "Gen5 R21 decoded · \(decoded.count) paired samples · 100 Hz · accel/gyro scales applied"
                return "GEN5_R21_IMU(0x2B) · decoded \(decoded.count) samples · 100 Hz · CRC valid"
            } catch {
                whoopIMUStatus = "Gen5 R21 candidate rejected · \(error) · raw retained"
                return "GEN5_R21_IMU(0x2B) · decode rejected · \(error)"
            }
        case 52: // HISTORICAL_IMU_DATA_STREAM; keep opaque until this firmware's framing is validated.
            // Type 52 is a distinct packet family from Type-47 biometric records.
            // Retain CRC-valid complete frames and expose their sizes/revision bytes;
            // never count them as decoded IMU samples until the inner schema is proven.
            whoopHistoricalIMUStreamPacketCount += 1
            whoopLastHistoricalIMUStreamRawFrameHex = b.map { String(format: "%02X", $0) }.joined()
            whoopIMUStatus = "WHOOP historical IMU stream received · raw frame retained · awaiting validated inner-layout decoder"
            recordVendorTimeline("HISTORICAL_IMU_DATA_STREAM(52) · CRC valid · bytes=\\(b.count) · raw retained · no samples counted")
            return "HISTORICAL_IMU_STREAM(52) · raw frame retained · layout pending · CRC valid"

        case 51: // Existing REALTIME_IMU_DATA_STREAM path retained independently; do not conflate with Gen5 R21.
            whoopIMUFrameCount += 1
            whoopIMULastFrameAt = Date()
            whoopIMULastRawFrameHex = b.map { String(format: "%02X", $0) }.joined()
            let capturedAt = ISO8601DateFormatter().string(from: Date())
            whoopIMURawFrameHistory.append("type=51 · \(capturedAt) · \(whoopIMULastRawFrameHex)")
            if whoopIMURawFrameHistory.count > 4 {
                whoopIMURawFrameHistory.removeFirst(whoopIMURawFrameHistory.count - 4)
            }
            whoopIMUStatus = "Realtime IMU stream packet received · \(b.count) bytes · CRC valid · subtype decode pending"
            return "REALTIME_IMU_DATA_STREAM(51) · \(b.count) bytes · CRC valid · raw frame retained"

        case 49: // METADATA; WHOOP 5 HISTORY_END must be acknowledged to advance the trim cursor.
            // NOOP's hardware-backed v5 fixture establishes:
            // meta_type @10 (2 = HISTORY_END), and end_data @21..<29 (trim cursor + next cursor).
            // The official flow echoes these exact 8 bytes in HISTORICAL_DATA_RESULT(23),
            // prefixed by 0x01. Do not infer timestamps from phone receipt time.
            guard b.count >= 29 else {
                return "METADATA · truncated frame · \\(b.count) bytes · CRC valid"
            }
            let metadataType = Int(b[10])
            if metadataType == 1 {
                whoopHistorySyncStatus = "HISTORY_START received · waiting for Type-47 records"
            } else if metadataType == 3 {
                if flushHistoricalRRArchive() {
                    whoopHistorySyncStatus = "HISTORY_COMPLETE received · historical archive flushed"
                } else {
                    whoopHistorySyncStatus = "HISTORY_COMPLETE received · archive flush failed · inspect diagnostics"
                }
            }
            if metadataType == 2 { // HISTORY_END
                // Never ACK a trim cursor until all preceding RR frames are durably archived.
                guard flushHistoricalRRArchive() else {
                    recordVendorTimeline("HISTORY_END ACK withheld · historical RR archive flush failed")
                    return "METADATA · HISTORY_END · ACK withheld · archive flush failed"
                }
                let endData = Array(b[21..<29])
                let trimCursor = UInt32(endData[0])
                    | (UInt32(endData[1]) << 8)
                    | (UInt32(endData[2]) << 16)
                    | (UInt32(endData[3]) << 24)
                guard let command = whoop5CommandCharacteristic,
                      command.properties.contains(.write) else {
                    recordVendorTimeline("HISTORY_END received · trim=\(trimCursor) · ACK withheld because command characteristic is unavailable")
                    return "METADATA · HISTORY_END · trim=\(trimCursor) · ACK unavailable"
                }
                let sequence = whoop5NextCommandSequence
                whoop5NextCommandSequence &+= 1
                let payload = [UInt8(0x01)] + endData
                let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x17, payload: payload)
                whoop5PendingWrites.append("HISTORICAL_DATA_RESULT")
                recordVendorTimeline("HISTORY_END ACK requested · HISTORICAL_DATA_RESULT(23) · trim=\(trimCursor) · seq=\(sequence) · exact end_data echoed")
                peripheral.writeValue(frame, for: command, type: .withResponse)
                return "METADATA · HISTORY_END · trim=\(trimCursor) · HISTORICAL_DATA_RESULT(23) ACK sent"
            }
            let metadataName = metadataType == 1 ? "HISTORY_START"
                : metadataType == 3 ? "HISTORY_COMPLETE" : "metadata type \(metadataType)"
            recordVendorTimeline("WHOOP metadata observed · \(metadataName) · CRC valid")
            return "METADATA · \(metadataName) · CRC valid"

        case 47: // HISTORICAL_DATA; contains several Gen5 layouts, not all of them IMU.
            // Preserve every CRC-valid v18 frame before trusting the candidate RR offsets.
            // Receipt time is forensic metadata only; physiological time remains nil.
            if b.count > 9, b[9] == 18 {
                whoopHistorySyncStatus = "Type-47 v18 historical frame received · decoding/archive in progress"
                let receivedAt = Date()
                let rawHex = b.map { String(format: "%02X", $0) }.joined()
                var rr: [Int] = []
                // Preserve the complete frame, but withhold candidate HR/time fields:
                // the WHOOP IPA symbols do not establish these v18 wire offsets.
                whoopHistoricalTimestampLastUpdatedAt = nil
                whoopHistoricalHeartRateBPM = nil
                var decodeError: String?

                do {
                    rr = try Whoop5RRDecoder.decodeHistoricalV18CandidateRRWords(b)
                    // A zero RR count is a successfully decoded empty interval list,
                    // not a packet/layout failure. Preserve the raw frame and keep
                    // the diagnostic distinct from genuine decode errors.
                    // The v18 words are not yet verified as milliseconds.
                    // Never publish them through an ms-labelled property or HRV input.
                    whoopHistoricalRRIntervalsMilliseconds = []
                    whoopHistoricalRRLastUpdatedAt = nil
                } catch {
                    decodeError = String(describing: error)
                    whoopRRSource = "Historical v18 RR candidate rejected · \(error)"
                }

                let record = HistoricalRRPacketRecord(
                    receivedAt: receivedAt,
                    recordType: 47,
                    revision: 18,
                    intervalsMilliseconds: [],
                    rawRRWords: rr,
                    rawFrameHex: rawHex,
                    heartRateBPM: nil,
                    physiologicalTimestamp: nil,
                    decodeError: decodeError
                )
                pendingHistoricalRRArchiveRecords.append(record)
                if pendingHistoricalRRArchiveRecords.count >= historicalRRArchiveBatchSize {
                    _ = flushHistoricalRRArchive()
                } else if let decodeError {
                    whoopHistoricalRRSource = "Type-47 v18 raw frame queued · candidate RR decode rejected · \(decodeError) · pending \(pendingHistoricalRRArchiveRecords.count)"
                } else {
                    whoopHistoricalRRSource = "Type-47 v18 raw frame queued · \(rr.count) candidate RR words · offsets/units unverified · HR/time withheld · pending \(pendingHistoricalRRArchiveRecords.count)"
                }

                if let decodeError {
                    return "HISTORICAL_DATA v18 · raw frame retained · RR candidate rejected · \(decodeError) · CRC valid"
                }
                return "HISTORICAL_DATA v18 · candidate RR words \(rr.map(String.init).joined(separator: ",")) · offsets/units unverified · HR/time withheld · CRC valid"
            }

            // WHOOP 5 R22 can carry the same 1,244-byte R21 IMU body inside
            // historical type 47 (inner type 0x2F, revision 21). This is the
            // observed high-rate offload path; command ACKs alone do not prove
            // that live raw streaming (0x2B) or IMU mode (106) is active.
            if b.count == 1244, b[8] == 0x2F, b[9] == 21 {
                whoopIMUFrameCount += 1
                whoopIMULastFrameAt = Date()
                whoopIMULastRawFrameHex = b.map { String(format: "%02X", $0) }.joined()
                let capturedAt = ISO8601DateFormatter().string(from: Date())
                whoopIMURawFrameHistory.append("type=47 · \(capturedAt) · \(whoopIMULastRawFrameHex)")
                if whoopIMURawFrameHistory.count > 4 {
                    whoopIMURawFrameHistory.removeFirst(whoopIMURawFrameHistory.count - 4)
                }
                do {
                    let decoded = try Gen5R21IMUDecoder.decode(b)
                    guard !decoded.isEmpty else {
                        whoopIMUStatus = "Historical Gen5 R21 buffer valid · no paired samples"
                        return "HISTORICAL_R21_IMU(0x2F) · no paired samples · CRC valid"
                    }
                    appendLiveIMUSamples(decoded)
                    appendVerifiedIMUHistory(decoded)
                    if workoutIsRecording {
                        workoutWhoopIMUSamples.append(contentsOf: decoded)
                    }
                    whoopIMUSampleCount += decoded.count
                    if workoutIsRecording,
                       workoutWhoopIMUSamples.count - lastWhoopIMUPersistedSampleCount >= 500 {
                        persistWorkoutSession()
                    }
                    whoopIMUStatus = "Gen5 R21 offload decoded · \(decoded.count) paired samples · 100 Hz"
                    recordVendorTimeline("HISTORICAL R21 IMU decoded · \(decoded.count) samples · type 47 · 100 Hz")
                    return "HISTORICAL_R21_IMU(0x2F) · decoded \(decoded.count) samples · CRC valid"
                } catch {
                    whoopIMUStatus = "Historical Gen5 R21 candidate rejected · \(error) · raw retained"
                    return "HISTORICAL_R21_IMU(0x2F) · decode rejected · \(error)"
                }
            }

            whoopIMUStatus = "Historical WHOOP 5 frame retained · \(b.count) bytes · inner revision \(b.count > 9 ? Int(b[9]) : -1) · R21 decode not matched"
            return "HISTORICAL_DATA(0x2F) · \(b.count) bytes · raw retained"

        case 40: // WHOOP 5.0 REALTIME_DATA · offsets correlated against 19 live device frames
            whoopRealtimePacketCount += 1
            let receivedAt = Date()
            let capturedAt = ISO8601DateFormatter().string(from: receivedAt)
            let rawHex = b.map { String(format: "%02X", $0) }.joined()
            whoopRealtimeRRRawFrameHistory.append("\(capturedAt) · type=40 · \(b.count) bytes · HEX: \(rawHex)")
            if whoopRealtimeRRRawFrameHistory.count > 20 {
                whoopRealtimeRRRawFrameHistory.removeFirst(whoopRealtimeRRRawFrameHistory.count - 20)
            }
            whoop5Type40FrameObserved = true

            // Device-captured 32-byte frames show a stable HR progression at byte[16]
            // (87, 87, 88, 89 ... 77 bpm); byte[12] is a sequence/header field, not HR.
            // RR count is byte[17], followed by little-endian 1/1024-second tick words.
            guard let bpm = try? Whoop5RRDecoder.decodeRealtimeHeartRate(b) else {
                whoopRealtimeCandidateByteAt16 = b.count > 16 ? Int(b[16]) : nil
                whoopRealtimeCandidateRRWords.removeAll(keepingCapacity: true)
                whoopRealtimeCandidateStatus = "Type-40 frame retained · HR candidate rejected by range/frame validation"
                return "REALTIME_DATA · raw retained · HR candidate rejected · CRC valid"
            }

            whoopRealtimeCandidateByteAt16 = bpm
            lastWhoopRealtimeHRAt = receivedAt
            if !whoop5HRDataObserved {
                whoop5HRDataObserved = true
                recordVendorTimeline("WHOOP Type-40 realtime HR data observed · event 33 confirmation \(whoop5HRStreamConfirmed ? "present" : "not yet received")")
            }
            if !whoop5HRStreamConfirmed {
                whoopSessionPhase = "Realtime HR data observed · event 33 not received · generation \(whoopConnectionGeneration)"
            }

            // HR is independently validated and remains usable even when an RR
            // batch is absent or fails its own interval checks.
            var rrSummary = "RR unavailable"
            do {
                let rr = try Whoop5RRDecoder.decodeRealtime(b)
                whoopRealtimeCandidateRRWords = rr
                if rr.isEmpty {
                    whoopRRSource = "WHOOP 5.0 realtime · latest Type-40 packet contained 0 RR intervals · retaining last valid RR batch"
                } else {
                    appendRRIntervals(rr, source: "WHOOP 5.0 realtime", receivedAt: receivedAt)
                    rrSummary = "RR \(rr.map(String.init).joined(separator: ",")) ms"
                }
                whoopRealtimeCandidateStatus = "Type-40 device-correlated · HR \(bpm) bpm · RR \(rr.count) interval(s) decoded"
            } catch {
                whoopRealtimeCandidateRRWords.removeAll(keepingCapacity: true)
                whoopRRSource = "Realtime RR decode rejected · \(error)"
                whoopRealtimeCandidateStatus = "Type-40 HR accepted · RR independently rejected · \(error)"
            }
            recordHeartRateSample(bpm, source: "WHOOP5 REALTIME_DATA")
            return "REALTIME_DATA · HR \(bpm) bpm · \(rrSummary) · CRC valid"

        case 53, 54: // PUFFIN event transports; preserve raw until their payload schemas are independently verified.
            whoopPuffinEventTypeCounts[type, default: 0] += 1
            whoopPuffinEventCountsByChannel[channel, default: 0] += 1
            let capturedAt = ISO8601DateFormatter().string(from: Date())
            let rawHex = b.map { String(format: "%02X", $0) }.joined(separator: " ")
            let candidateOffsets = b.indices.filter { index in
                index >= 10 && index < min(b.count - 4, 32) && (b[index] == 33 || b[index] == 34)
            }
            let candidateSummary = candidateOffsets.isEmpty
                ? "no byte-33/34 candidates in header/event prefix"
                : "byte-33/34 candidates at absolute offsets " + candidateOffsets.map(String.init).joined(separator: ",")
            whoopPuffinEventFrameHistory.append("\(capturedAt) · type=\(type) · channel=\(channel) · seq=\(b.count > 9 ? Int(b[9]) : -1) · \(candidateSummary) · HEX: \(rawHex)")
            if whoopPuffinEventFrameHistory.count > 24 {
                whoopPuffinEventFrameHistory.removeFirst(whoopPuffinEventFrameHistory.count - 24)
            }
            recordVendorTimeline("Puffin event transport packet · type=\(type) · channel=\(channel) · \(b.count) bytes · \(candidateSummary)")
            return "PUFFIN_EVENT_TRANSPORT(\(type)) · raw retained · \(b.count) bytes · \(candidateSummary) · CRC valid"

        case 48: // EVENT
            guard b.count >= 20 else { return "EVENT · truncated · CRC valid" }
            // Gen5 references place EventNumber at absolute offset 10 and the
            // u32 event timestamp at offset 12. Keep byte 11 separately visible
            // rather than silently folding it into a UInt16.
            let eventID = Int(b[10])
            let eventIDAdjacentByte = Int(b[11])
            let eventTimestampRaw = UInt32(b[12])
                | (UInt32(b[13]) << 8)
                | (UInt32(b[14]) << 16)
                | (UInt32(b[15]) << 24)
            whoopEventPacketCount += 1
            whoopEventCountsByChannel[channel, default: 0] += 1
            whoopLastEventID = eventID
            whoopLastEventChannel = channel
            let eventFrameHex = b.map { String(format: "%02X", $0) }.joined(separator: " ")
            whoopLastEventFrameHex = eventFrameHex
            recordVendorTimeline("Type-48 EVENT decoded · idByte@10=\(eventID) · adjacent@11=\(eventIDAdjacentByte) · timestamp@12=\(eventTimestampRaw) · channel=\(channel) · frame=\(b.count) bytes")
            if eventID == 33 {
                whoopEvent33Count += 1
                whoopLastEvent33At = Date()
                whoopLastEvent33FrameHex = eventFrameHex
                recordVendorTimeline("EVENT 33 observed · channel=\(channel) · CRC valid")
                if whoopEventProbeActive {
                    whoopEventProbeStatus = "Event 33 observed during controlled ON/OFF probe · Event34 delta \(whoopEvent34Count - whoopEventProbeStart34Count)"
                }
                whoop5HRStreamConfirmed = true
                whoopSessionPhase = "Realtime HR stream confirmed · generation \(whoopConnectionGeneration)"
                recordVendorTimeline("WHOOP realtime HR active event 33 received")
                lastBLEEvent = "WHOOP event 33 · BLE_REALTIME_HR_ON · stream activation confirmed"
                statusText = "Connected · WHOOP realtime HR stream confirmed · waiting for sample"

                // Event 33 gates motion capture, but is not itself motion evidence.
                // Gen5 hardware-verified order: START_RAW_DATA [01], then IMU mode ON.
                if !whoop5AutoIMUStartRequested && !whoop5AutoIMUEnabled,
                   whoop5HelloWriteAcknowledged,
                   whoop5IMUModeEnableSequence == nil {
                    recordVendorTimeline("IMU startup gate · Event 33 confirmed · requesting START_RAW_DATA [01] before IMU mode ON")
                    sendWhoop5RawDataStart(to: peripheral)
                }
                return "EVENT · BLE_REALTIME_HR_ON(33) · CRC valid · realtime HR active; Gen5 IMU mode gate evaluated"
            }
            if eventID == 34 {
                whoopEvent34Count += 1
                whoopLastEvent34At = Date()
                whoopLastEvent34FrameHex = eventFrameHex
                recordVendorTimeline("EVENT 34 observed · channel=\(channel) · CRC valid")
                if whoopEventProbeActive {
                    whoopEventProbeStatus = "Event 34 observed during controlled ON/OFF probe · Event33 delta \(whoopEvent33Count - whoopEventProbeStart33Count)"
                }
                whoop5HRStreamConfirmed = false
                whoopSessionPhase = "Realtime HR stream stopped · event 34 received · generation \(whoopConnectionGeneration)"
                lastBLEEvent = "WHOOP event 34 · BLE_REALTIME_HR_OFF"
                return "EVENT · BLE_REALTIME_HR_OFF(34) · CRC valid"
            }
            if eventID == 3 {
                guard b.count > 22 else {
                    return "BATTERY_EVENT(3) · truncated frame · \(b.count) bytes · CRC valid · raw captured"
                }
                let socRaw = Int(b[21]) | (Int(b[22]) << 8)
                let percentage = Double(socRaw) / 10.0
                guard (0.0...100.0).contains(percentage) else {
                    return "EVENT · BATTERY_LEVEL(3) · raw \(socRaw) · out of range · CRC valid"
                }
                whoopBatteryPercent = percentage
                whoopBatteryLastUpdatedAt = Date()
                UserDefaults.standard.set(percentage, forKey: "pulseforge.whoop.batteryPercent")
                UserDefaults.standard.set(whoopBatteryLastUpdatedAt, forKey: "pulseforge.whoop.batteryUpdatedAt")
                return "EVENT · BATTERY_LEVEL(3) · \(String(format: "%.1f", percentage))% · UI value updated · CRC valid"
            }
            return "EVENT · id \(eventID) · CRC valid · not a realtime HR sample"

        default:
            return "WHOOP5 packet type \(type) · \(b.count) bytes · CRC valid · no HR decoded"
        }
    }

    private func isValidWhoop5Frame(_ b: [UInt8]) -> Bool {
        guard b.count >= 12, b[0] == 0xAA, b[1] == 0x01 else { return false }
        let declared = Int(b[2]) | (Int(b[3]) << 8)
        guard declared >= 4, 8 + declared == b.count else { return false }
        let storedHeaderCRC = UInt16(b[6]) | (UInt16(b[7]) << 8)
        guard crc16Modbus(Array(b[0..<6])) == storedHeaderCRC else { return false }
        let payloadEnd = b.count - 4
        let paddedInner = Array(b[8..<payloadEnd])
        let storedPayloadCRC = UInt32(b[payloadEnd])
            | (UInt32(b[payloadEnd + 1]) << 8)
            | (UInt32(b[payloadEnd + 2]) << 16)
            | (UInt32(b[payloadEnd + 3]) << 24)
        return crc32(paddedInner) == storedPayloadCRC
    }

    private func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xA001 : (crc >> 1)
            }
        }
        return crc
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Gen5 IMU mode toggle (0x6A), revision 1: [0x01, on/off].
    /// START_RAW_DATA must be accepted first on WHOOP 5.0.
    private func sendWhoop5IMUModeToggle(to peripheral: CBPeripheral, enabled: Bool) {
        guard whoop5IMUModeEnableSequence == nil,
              whoop5AutoIMUStartRequested,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else { return }
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        whoop5IMUModeEnableSequence = sequence
        whoop5IMUModeTargetEnabled = enabled
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x6A,
                                            payload: [0x01, enabled ? 0x01 : 0x00])
        whoop5PendingWrites.append(enabled ? "TOGGLE_IMU_MODE_ON" : "TOGGLE_IMU_MODE_OFF")
        let hex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        recordVendorTimeline("TOGGLE_IMU_MODE write requested · opcode 6A · revision 1 \(enabled ? "ON" : "OFF") · seq=\(sequence) · HEX: \(hex)")
        whoopIMUStatus = "Gen5 IMU mode \(enabled ? "ON" : "OFF") requested · awaiting band response"
        peripheral.writeValue(frame, for: command, type: .withResponse)
    }

    /// WHOOP 5 Gen5 hardware-verified START_RAW_DATA (0x51) body is [0x01].
    /// A separate 60-second STOP_RAW_DATA safety command bounds each capture window.
    private func sendWhoop5RawDataStart(to peripheral: CBPeripheral) {
        guard !whoop5AutoIMUStartRequested,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else { return }
        whoop5AutoIMUStartRequested = true
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        whoop5RawStartSequence = sequence
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x51, payload: [0x01])
        whoop5PendingWrites.append("START_RAW_DATA_60S")
        let hex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        recordVendorTimeline("START_RAW_DATA write requested · opcode 51 · Gen5 revision 1 [01] · seq=\(sequence) · HEX: \(hex)")
        whoopIMUStatus = "START_RAW_DATA [01] requested · awaiting band response"
        peripheral.writeValue(frame, for: command, type: .withResponse)
    }

    /// Schedule an explicit STOP_RAW_DATA (0x52) after the bounded stream.
    /// This is a safety stop even though START_RAW_DATA carries its own duration.
    private func scheduleWhoop5RawStreamStop(for peripheral: CBPeripheral, after seconds: TimeInterval) {
        whoop5RawStreamStopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  self.whoop5AutoIMUEnabled else { return }
            self.sendWhoop5RawDataStop(to: peripheral)
        }
        whoop5RawStreamStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        recordVendorTimeline("STOP_RAW_DATA safety stop scheduled · after \(Int(seconds))s")
    }

    /// Restart the bounded raw stream after a confirmed safety stop.
    /// Each window remains limited to 60 seconds; reconnect/disconnect cancels re-arm.
    private func scheduleWhoop5RawStreamRearm(for peripheral: CBPeripheral, after seconds: TimeInterval) {
        whoop5RawStreamRearmWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  peripheral.state == .connected,
                  self.whoop5HRStreamConfirmed,
                  self.whoop5HelloWriteAcknowledged,
                  !self.whoop5AutoIMUEnabled,
                  !self.whoop5AutoIMUStartRequested else { return }
            self.recordVendorTimeline("Bounded motion stream re-arm · START_RAW_DATA [01] first")
            self.sendWhoop5RawDataStart(to: peripheral)
        }
        whoop5RawStreamRearmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Stop Gen5 raw streaming (STOP_RAW_DATA = 0x52, body [0x01]).
    private func sendWhoop5RawDataStop(to peripheral: CBPeripheral) {
        guard whoop5AutoIMUEnabled,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else { return }
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        whoop5RawStopSequence = sequence
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x52, payload: [0x01])
        whoop5PendingWrites.append("STOP_RAW_DATA_60S")
        recordVendorTimeline("STOP_RAW_DATA write requested · opcode 52 · revision 1 · seq=\(sequence)")
        whoopIMUStatus = "60-second raw stream elapsed · STOP_RAW_DATA requested"
        peripheral.writeValue(frame, for: command, type: .withResponse)
    }

    /// A single bounded recovery for the WHOOP 5.0 HR stream if it goes silent
    /// after producing data. Do not reconnect or loop retries; preserve the GATT session.
    private func scheduleWhoop5HRStallRecovery(from sampleTime: Date) {
        // HR arrives frequently; replace the quiet-period timer on each sample,
        // but emit only one "scheduled" diagnostic per GATT connection.
        let shouldLogSchedule = whoop5HRStallRecoveryWorkItem == nil
        whoop5HRStallRecoveryWorkItem?.cancel()
        guard !whoop5HRStallRecoveryAttempted else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let peripheral = self.connectedPeripheral,
                  peripheral.state == .connected,
                  self.connectedName != nil,
                  self.whoop5HRStreamConfirmed,
                  let lastSample = self.lastHeartRateAt,
                  Date().timeIntervalSince(lastSample) >= 5 * 60,
                  !self.whoop5PendingWrites.contains("REALTIME_HR_ON") else { return }
            self.whoop5HRStallRecoveryAttempted = true
            self.whoop5HRStreamEnableSent = false
            self.recordVendorTimeline("HR stall recovery · no sample for 5 min · one REALTIME_HR_ON re-arm")
            self.lastBLEEvent = "WHOOP HR stream silent for 5 min · one recovery request sent"
            self.statusText = "Connected · recovering silent WHOOP HR stream"
            self.sendRealtimeHrEnable(to: peripheral)
        }
        whoop5HRStallRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60, execute: work)
        if shouldLogSchedule {
            recordVendorTimeline("HR stall watchdog armed · fires only after 5 min without a new HR sample")
        }
    }

    /// Enable WHOOP 5.0 live HR (opcode 0x03, body [0x01]).
    /// This is separate from subscribing to 180D/2A37 and FD4B notify CCCDs.
    private func sendRealtimeHrEnable(to peripheral: CBPeripheral) {
        guard !whoop5HRStreamEnableSent,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else { return }
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x03, payload: [0x01])
        whoop5HRStreamEnableSent = true
        if whoopEventProbeActive {
            whoopEventProbeOnSequence = sequence
            whoopEventProbeStatus = "ON command sent · waiting for Event 33 and restored Type-40 HR"
            recordVendorTimeline("Event probe ON write requested · seq=\(sequence)")
            whoopEventProbeFinishWorkItem?.cancel()
            let finish = DispatchWorkItem { [weak self] in
                guard let self, self.whoopEventProbeActive else { return }
                let onDelta = self.whoopEvent33Count - self.whoopEventProbeStart33Count
                let offDelta = self.whoopEvent34Count - self.whoopEventProbeStart34Count
                let restoredSample = self.lastHeartRateAt.map { sampleAt in
                    self.whoopEventProbeStartedAt.map { sampleAt > $0 } ?? false
                } ?? false
                self.whoopEventProbeStatus = "Probe complete · Event33 +\(onDelta) · Event34 +\(offDelta) · HR \(restoredSample ? "sample restored" : "not yet restored")"
                self.whoopEventProbeActive = false
                self.whoopEventProbeOffSequence = nil
                self.whoopEventProbeOnSequence = nil
                self.recordVendorTimeline("Event probe complete · Event33 delta=\(onDelta) · Event34 delta=\(offDelta)")
            }
            whoopEventProbeFinishWorkItem = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: finish)
        }
        whoop5PendingWrites.append("REALTIME_HR_ON")
        let frameHex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        lastBLEEvent = "WHOOP realtime HR ON command requested · opcode 03 · sequence \(sequence)"
        recordVendorTimeline("REALTIME_HR_ON write requested · FD4B0002 · seq=\(sequence) · \(frame.count) bytes · HEX: \(frameHex)")
        statusText = "Connected · requesting WHOOP live HR stream"
        peripheral.writeValue(frame, for: command, type: .withResponse)
    }

    /// User-triggered, bounded OFF→ON test to elicit both Gen5 realtime-HR events.
    /// It briefly pauses live HR, then automatically restores the stream.
    func runWhoopEventProbe() {
        guard let peripheral = connectedPeripheral,
              peripheral.state == .connected,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write),
              whoop5HelloWriteAcknowledged,
              !whoopEventProbeActive,
              !whoop5PendingWrites.contains("REALTIME_HR_ON"),
              !whoop5PendingWrites.contains("REALTIME_HR_OFF_PROBE") else {
            whoopEventProbeStatus = "Probe unavailable · connect WHOOP 5.0 and wait until handshake is ready"
            return
        }
        whoopEventProbeActive = true
        whoopEventProbeOffSequence = whoop5NextCommandSequence
        whoopEventProbeOnSequence = nil
        whoopEventProbeStart33Count = whoopEvent33Count
        whoopEventProbeStart34Count = whoopEvent34Count
        whoopEventProbeStartedAt = Date()
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x03, payload: [0x00])
        whoop5HRStreamEnableSent = false
        whoop5HRStreamConfirmed = false
        whoop5PendingWrites.append("REALTIME_HR_OFF_PROBE")
        whoopEventProbeStatus = "OFF command sent · 1.5s event observation window, then automatic ON"
        recordVendorTimeline("Event probe OFF write requested · opcode=03 payload=00 · seq=\(sequence)")
        peripheral.writeValue(frame, for: command, type: .withResponse)
        // Independent failsafe: restore HR even if the write/response callback is delayed or absent.
        scheduleWhoopEventProbeRearm(after: 2.0)
    }

    private func scheduleWhoopEventProbeRearm(after delay: TimeInterval) {
        guard whoopEventProbeActive else { return }
        whoopEventProbeRearmWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.whoopEventProbeActive,
                  let peripheral = self.connectedPeripheral,
                  peripheral.state == .connected else { return }
            self.whoop5HRStreamEnableSent = false
            self.sendRealtimeHrEnable(to: peripheral)
        }
        whoopEventProbeRearmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Begin the Gen5 flash-history request after the realtime-HR command write.
    /// Use the revision-1 HELLO RTC when plausible; correct it only at >=2 s drift.
    /// Unknown HELLO layouts are never read through guessed offsets.
    private func startWhoop5HistoricalSync(to peripheral: CBPeripheral) {
        guard !whoop5HistorySyncStarted,
              connectedPeripheral?.identifier == peripheral.identifier,
              peripheral.state == .connected,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else { return }
        whoop5HistorySyncStarted = true
        whoop5HistorySyncRequested = false

        if whoop5HelloRevision == 1,
           let seconds = whoop5HelloTimestampSeconds,
           let subseconds = whoop5HelloTimestampSubseconds,
           seconds >= 1_600_000_000,
           subseconds < 32_768 {
            let strapMilliseconds = Double(seconds) * 1000.0
                + Double(subseconds) * 1000.0 / 32_768.0
            let driftMilliseconds = abs(Date().timeIntervalSince1970 * 1000.0 - strapMilliseconds)
            if driftMilliseconds < 2_000 {
                whoopHistorySyncStatus = "HELLO RTC in sync · requesting GET_DATA_RANGE"
                recordVendorTimeline("Historical sync clock gate · HELLO RTC drift \(Int(driftMilliseconds))ms · no SET_CLOCK needed")
                requestWhoop5HistoricalDataRange(to: peripheral)
                return
            }
            recordVendorTimeline("Historical sync clock gate · HELLO RTC drift \(Int(driftMilliseconds))ms · SET_CLOCK required")
        } else {
            recordVendorTimeline("Historical sync clock gate · HELLO timestamp unavailable/untrusted · SET_CLOCK required")
        }

        let nowMilliseconds = Date().timeIntervalSince1970 * 1000.0
        let epochSeconds = UInt32(nowMilliseconds / 1000.0)
        let subsecondTicks = UInt32((nowMilliseconds.truncatingRemainder(dividingBy: 1000.0) * 32_768.0) / 1000.0)
        let payload: [UInt8] = [
            UInt8(epochSeconds & 0xFF),
            UInt8((epochSeconds >> 8) & 0xFF),
            UInt8((epochSeconds >> 16) & 0xFF),
            UInt8((epochSeconds >> 24) & 0xFF),
            UInt8(subsecondTicks & 0xFF),
            UInt8((subsecondTicks >> 8) & 0xFF),
            0, 0
        ]
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        whoop5HistoryClockSequence = sequence
        whoop5PendingWrites.append("SET_CLOCK_FOR_HISTORY")
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x0A, payload: payload)
        whoopHistorySyncStatus = "SET_CLOCK sent · waiting for WHOOP command response"
        recordVendorTimeline("Historical sync SET_CLOCK(10) requested · 8-byte Gen5 RTC payload · seq=\(sequence)")
        peripheral.writeValue(frame, for: command, type: .withResponse)
    }

    /// Gen5 GET_DATA_RANGE (0x22) uses an empty semantic body.
    private func requestWhoop5HistoricalDataRange(to peripheral: CBPeripheral) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              peripheral.state == .connected,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else {
            whoopHistorySyncStatus = "GET_DATA_RANGE unavailable · command characteristic missing"
            return
        }
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        whoop5HistoryRangeSequence = sequence
        whoop5PendingWrites.append("GET_DATA_RANGE_FOR_HISTORY")
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x22, payload: [])
        whoopHistorySyncStatus = "GET_DATA_RANGE sent · waiting for BLE write acknowledgement"
        recordVendorTimeline("Historical sync GET_DATA_RANGE(34) requested · Gen5 empty body · seq=\(sequence)")
        peripheral.writeValue(frame, for: command, type: .withResponse)
    }

    /// Gen5 SEND_HISTORICAL_DATA (0x16) uses an empty semantic body.
    /// Do not reuse the Gen4 one-byte 0x00 payload on a Gen5 strap.
    private func sendWhoop5HistoricalData(to peripheral: CBPeripheral) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              peripheral.state == .connected,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else {
            whoopHistorySyncStatus = "SEND_HISTORICAL_DATA unavailable · command characteristic missing"
            return
        }
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        whoop5HistoryRequestSequence = sequence
        whoop5PendingWrites.append("SEND_HISTORICAL_DATA")
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x16, payload: [])
        whoopHistorySyncStatus = "SEND_HISTORICAL_DATA sent · waiting for WHOOP history stream"
        recordVendorTimeline("SEND_HISTORICAL_DATA(22) requested · Gen5 empty body · seq=\(sequence)")
        peripheral.writeValue(frame, for: command, type: .withResponse)
    }

    /// Gen5 outbound command envelope: CRC16-Modbus header + CRC32 padded inner.
    private func buildWhoop5CommandFrame(sequence: UInt8, opcode: UInt8, payload: [UInt8]) -> Data {
        var inner: [UInt8] = [0x23, sequence, opcode] + payload
        while inner.count % 4 != 0 { inner.append(0) }
        let declared = UInt16(inner.count + 4)
        var header: [UInt8] = [0xAA, 0x01, UInt8(declared & 0xFF), UInt8((declared >> 8) & 0xFF), 0x00, 0x01]
        let headerCRC = crc16Modbus(header)
        header.append(UInt8(headerCRC & 0xFF))
        header.append(UInt8((headerCRC >> 8) & 0xFF))
        let payloadCRC = crc32(inner)
        let tail: [UInt8] = [UInt8(payloadCRC & 0xFF), UInt8((payloadCRC >> 8) & 0xFF), UInt8((payloadCRC >> 16) & 0xFF), UInt8((payloadCRC >> 24) & 0xFF)]
        return Data(header + inner + tail)
    }

    /// Route every validated HR source through the same live UI, chart and workout pipeline.
    private func recordHeartRateSample(_ bpm: Int, source: String) {
        let timestamp = Date()
        liveHeartRateBPM = bpm
        lastHeartRateAt = timestamp
        scheduleWhoop5HRStallRecovery(from: timestamp)
        if hrTimingFirstSampleAt == nil {
            hrTimingFirstSampleAt = timestamp
            let elapsed = hrTimingConnectionAt.map { timestamp.timeIntervalSince($0) } ?? 0
            hrTimingEvents.append(String(format: "first HR +%.3fs (%@)", elapsed, source))
            recordVendorTimeline("first accepted HR sample · \(source) · \(bpm) bpm · +\(String(format: "%.3f", elapsed))s")
        }
        let sample = LiveHeartRateSample(timestamp: timestamp, bpm: bpm)
        liveHeartRateSamples.append(sample)
        dashboardHeartRateHistory.append(sample)
        if dashboardHeartRateHistory.count > 20_000 { dashboardHeartRateHistory.removeFirst(dashboardHeartRateHistory.count - 20_000) }
        persistDashboardHistory()
        liveHeartRateSamples.removeAll { timestamp.timeIntervalSince($0.timestamp) > 60 }
        if liveHeartRateSamples.count > 120 {
            liveHeartRateSamples.removeFirst(liveHeartRateSamples.count - 120)
        }
        evaluateAutomaticWorkoutDetection(bpm: bpm, at: timestamp)
        if workoutIsRecording {
            workoutHeartRateSamples.append(sample)
            if workoutHeartRateSamples.count > 14_400 {
                workoutHeartRateSamples.removeFirst(workoutHeartRateSamples.count - 14_400)
            }
            // Checkpoint periodically so an iOS process termination does not
            // discard the entire in-progress workout.
            if workoutHeartRateSamples.count.isMultiple(of: 10) {
                // HR checkpoints must not re-encode the growing 100 Hz IMU buffer.
                persistWorkoutSession(includeIMU: false)
            }
        }
        heartRateUpdateCount += 1
        lastBLEEvent = "\(source) · \(bpm) bpm · \(ISO8601DateFormatter().string(from: timestamp)) · sample #\(heartRateUpdateCount)"
        statusText = "Live HR · \(bpm) bpm · \(heartRateUpdateCount) update(s)"
    }

    private func appendRRIntervals(_ intervals: [Int], source: String, receivedAt: Date = Date()) {
        guard !intervals.isEmpty else { return }
        whoopRRIntervalsMilliseconds = intervals
        if source == "WHOOP 5.0 realtime" {
            dashboardRRHistory.append(contentsOf: intervals.map { PersistedRRIntervalSample(timestamp: receivedAt, intervalMilliseconds: $0) })
            if dashboardRRHistory.count > 20_000 { dashboardRRHistory.removeFirst(dashboardRRHistory.count - 20_000) }
            persistDashboardHistory()
        }

        // Standard 2A37 is a fallback stream, not WHOOP type-40. Never mix its
        // intervals into the WHOOP realtime window or calculate Type-40 RMSSD
        // from a fallback packet.
        guard source == "WHOOP 5.0 realtime" else {
            whoopRRWindowMilliseconds.removeAll(keepingCapacity: true)
            whoopLiveRMSSDMilliseconds = nil
            whoopRRLastUpdatedAt = receivedAt
            whoopRRSource = "\(source) · \(intervals.count) fallback interval(s) · excluded from Type-40 RMSSD"
            return
        }

        if let previousUpdate = whoopRRLastUpdatedAt,
           receivedAt.timeIntervalSince(previousUpdate) > 30 {
            whoopRRWindowMilliseconds.removeAll(keepingCapacity: true)
        }
        whoopRRWindowMilliseconds.append(contentsOf: intervals)
        persistDashboardHistory()
        if whoopRRWindowMilliseconds.count > 60 {
            whoopRRWindowMilliseconds.removeFirst(whoopRRWindowMilliseconds.count - 60)
        }
        // Short rolling estimate only; never used as overnight HRV or Recovery input.
        whoopLiveRMSSDMilliseconds = RealtimeRMSSDCalculator.calculate(
            intervalsMilliseconds: whoopRRWindowMilliseconds
        )
        whoopRRLastUpdatedAt = receivedAt
        whoopRRSource = "\(source) · \(intervals.count) new interval(s) · rolling \(whoopRRWindowMilliseconds.count) · milliseconds"
    }

    private func parseStandardHeartRateMeasurement(_ data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        let flags = data[data.startIndex]
        let isUInt16 = (flags & 0x01) != 0
        if isUInt16 {
            guard data.count >= 3 else { return nil }
            let low = UInt16(data[data.startIndex + 1])
            let high = UInt16(data[data.startIndex + 2]) << 8
            return Int(low | high)
        }
        return Int(data[data.startIndex + 1])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              isCurrentGattService(service, on: peripheral) else { return }
        if let error {
            let failure = "\(service.uuid.uuidString): \(error.localizedDescription)"
            // Only a failed discovery inside the WHOOP Gen5 service can
            // invalidate its command/notification profile. An unrelated
            // ancillary GATT service must not block the FD4B handshake.
            if service.uuid == whoop5ServiceUUID {
                gattCharacteristicDiscoveryErrors.append(failure)
            }
            discoveredProfile.append("Service error · \(failure)")
            lastBLEEvent = "Characteristic discovery error · service \(failure)"
            recordVendorTimeline("characteristic discovery failed · \(failure)")
        } else {
            for characteristic in service.characteristics ?? [] {
                discoveredProfile.append("Characteristic · service \(service.uuid.uuidString) → \(characteristic.uuid.uuidString) · \(propertyNames(characteristic.properties))")
                if service.uuid == CBUUID(string: "180D"),
                   characteristic.uuid == CBUUID(string: "2A37"),
                   characteristic.properties.contains(.notify) {
                    hrTimingStandardNotifyRequestedAt = Date()
                    let elapsed = hrTimingConnectionAt.map { Date().timeIntervalSince($0) } ?? 0
                    hrTimingEvents.append(String(format: "180D/2A37 notify requested +%.3fs", elapsed))
                    peripheral.setNotifyValue(true, for: characteristic)
                    lastBLEEvent = "Subscribed to standard Bluetooth Heart Rate Measurement (180D/2A37)"
                }
                let fd4bNotifyUUIDs: Set<String> = [
                    "FD4B0003-CCE1-4033-93CE-002D5875F58A",
                    "FD4B0004-CCE1-4033-93CE-002D5875F58A",
                    "FD4B0005-CCE1-4033-93CE-002D5875F58A",
                    "FD4B0007-CCE1-4033-93CE-002D5875F58A"
                ]
                let characteristicUUID = characteristic.uuid.uuidString.uppercased()
                if motionProbeUUIDPrefixes.contains(where: { characteristicUUID.hasPrefix($0) }),
                   characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    // Archive string clusters are discovery leads, not a verified
                    // subscription map. Record capability and parent service, but
                    // do not enable notifications on every candidate family.
                    candidateNotificationStates[characteristicUUID] =
                        "discovered under \(service.uuid.uuidString.uppercased()) · \(propertyNames(characteristic.properties)) · subscription withheld pending role verification"
                }
                if service.uuid == whoop5ServiceUUID && characteristic.uuid == whoop5CommandUUID {
                    whoop5CommandCharacteristic = characteristic
                }
                if service.uuid == whoop5ServiceUUID,
                   fd4bNotifyUUIDs.contains(characteristicUUID),
                   characteristic.properties.contains(.notify) {
                    vendorNotificationStates[characteristicUUID] = "subscription requested"
                    recordVendorTimeline("pre-hello notify request · \(characteristicUUID)")
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                let key = ObjectIdentifier(characteristic)
                pendingDescriptorCharacteristics.insert(key)
                peripheral.discoverDescriptors(for: characteristic)
            }
        }
        pendingCharacteristicServices.remove(ObjectIdentifier(service))
        if pendingCharacteristicServices.isEmpty {
            recordVendorTimeline("all service characteristic discovery callbacks completed · descriptors may still be pending")
            // Do not start the WHOOP session while CoreBluetooth is still
            // discovering characteristics on other GATT services. The old
            // per-service trigger could send CLIENT_HELLO before the complete
            // profile (including any companion service) was known.
            startWhoopHelloAfterGattDiscovery(peripheral)
        }
        if pendingCharacteristicServices.isEmpty && pendingDescriptorCharacteristics.isEmpty {
            updateGattDiscoveryCompletionStatus()
        } else if pendingCharacteristicServices.isEmpty {
            statusText = "Inspecting GATT descriptors · \(pendingDescriptorCharacteristics.count) remaining"
        } else {
            statusText = "Inspecting characteristics · \(pendingCharacteristicServices.count) service(s) remaining"
        }
    }

    /// Starts exactly one existing CLIENT_HELLO only after every discovered
    /// service has completed characteristic discovery. Packet bytes and write
    /// type remain unchanged; this fixes the cross-service discovery race.
    private func startWhoopHelloAfterGattDiscovery(_ peripheral: CBPeripheral) {
        guard !whoop5HelloSent else { return }
        guard gattCharacteristicDiscoveryErrors.isEmpty else {
            whoopSessionPhase = "GATT discovery incomplete · protocol handshake withheld"
            let failures = gattCharacteristicDiscoveryErrors.joined(separator: " | ")
            lastBLEEvent = "CLIENT_HELLO withheld · incomplete characteristic discovery · \(failures)"
            statusText = "WHOOP GATT discovery incomplete · reconnect to retry"
            recordVendorTimeline("CLIENT_HELLO withheld · GATT discovery errors · \(failures)")
            return
        }
        guard let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else {
            let hasWhoopService = discoveredProfile.contains {
                $0.contains("Service · \(whoop5ServiceUUID.uuidString)")
            }
            if hasWhoopService {
                lastBLEEvent = "WHOOP Gen5 service found, but command characteristic FD4B0002 is unavailable"
                recordVendorTimeline("CLIENT_HELLO withheld · FD4B0002 unavailable after all services discovered")
            } else {
                // Do not send the Gen5 CLIENT_HELLO to a different WHOOP GATT
                // family. Keep discovery passive until that model's protocol is
                // identified from its own service/characteristic capture.
                let serviceLines = discoveredProfile.filter { $0.hasPrefix("Service ·") }
                let serviceSummary = serviceLines.map {
                    $0.replacingOccurrences(of: "Service · ", with: "")
                }.joined(separator: ", ")
                whoopSessionPhase = "Non-FD4B WHOOP profile · protocol mapping pending"
                lastBLEEvent = "WHOOP candidate has no FD4B Gen5 service · \(serviceSummary)"
                statusText = "WHOOP detected · non-Gen5 GATT profile · protocol mapping pending"
            }
            return
        }

        let hello: [UInt8] = [
            0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
            0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D
        ]
        whoop5HelloSent = true
        whoop5HelloWritePending = true
        whoop5PendingWrites.append("CLIENT_HELLO")
        lastBLEEvent = "WHOOP 5.0 CLIENT_HELLO write requested · FD4B0002 · 16 bytes · all services discovered"
        recordVendorTimeline("CLIENT_HELLO write requested · FD4B0002 · 16 bytes · all service characteristics discovered")
        whoopSessionPhase = "CLIENT_HELLO write pending · generation \(whoopConnectionGeneration)"
        statusText = "Connected · starting WHOOP 5.0 secure session"
        peripheral.writeValue(Data(hello), for: command, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              isCurrentGattCharacteristic(characteristic, on: peripheral),
              characteristic.uuid == whoop5CommandUUID,
              !whoop5PendingWrites.isEmpty else { return }
        let kind = whoop5PendingWrites.removeFirst()

        if kind == "TOGGLE_IMU_MODE_ON" || kind == "TOGGLE_IMU_MODE_OFF" {
            if let error {
                whoop5IMUModeEnableSequence = nil
                whoop5IMUModeTargetEnabled = nil
                whoopIMUStatus = "Gen5 IMU mode write failed · \(error.localizedDescription)"
                recordVendorTimeline("TOGGLE_IMU_MODE write callback · failed · \(error.localizedDescription)")
            } else {
                whoopIMUStatus = "Gen5 IMU mode write acknowledged · awaiting band response"
                recordVendorTimeline("TOGGLE_IMU_MODE write callback · acknowledged by CoreBluetooth")
            }
            return
        }
        if kind == "START_RAW_DATA_60S" {
            if let error {
                whoop5RawStartSequence = nil
                whoop5AutoIMUStartRequested = false
                whoopIMUStatus = "START_RAW_DATA write failed · \(error.localizedDescription)"
                recordVendorTimeline("START_RAW_DATA write callback · failed · \(error.localizedDescription)")
            } else {
                whoopIMUStatus = "START_RAW_DATA write acknowledged · awaiting strap response"
                recordVendorTimeline("START_RAW_DATA write callback · acknowledged by CoreBluetooth")
            }
            return
        }
        if kind == "STOP_RAW_DATA_60S" {
            if let error {
                whoop5RawStopSequence = nil
                whoopIMUStatus = "STOP_RAW_DATA write failed · \(error.localizedDescription)"
                recordVendorTimeline("STOP_RAW_DATA write callback · failed · \(error.localizedDescription)")
            } else {
                whoopIMUStatus = "STOP_RAW_DATA write acknowledged · awaiting strap response"
                recordVendorTimeline("STOP_RAW_DATA write callback · acknowledged by CoreBluetooth")
            }
            return
        }
        if kind == "REALTIME_HR_OFF_PROBE" {
            if let error {
                whoopEventProbeStatus = "OFF write callback failed · \(error.localizedDescription) · restoring HR"
                recordVendorTimeline("Event probe OFF write callback failed · \(error.localizedDescription)")
                scheduleWhoopEventProbeRearm(after: 0.25)
            } else {
                whoopEventProbeStatus = "OFF write acknowledged · waiting up to 1.5s for Event 34"
                recordVendorTimeline("Event probe OFF write acknowledged by CoreBluetooth")
                scheduleWhoopEventProbeRearm(after: 1.5)
            }
            return
        }
        if kind == "REALTIME_HR_ON" {
            if let error {
                recordVendorTimeline("REALTIME_HR_ON write callback · failed · \(error.localizedDescription)")
                whoop5HRStreamEnableSent = false
                lastBLEEvent = "WHOOP realtime HR ON write failed · \(error.localizedDescription)"
                statusText = "Connected · live HR command failed"
                return
            }
            recordVendorTimeline("REALTIME_HR_ON write callback · acknowledged by CoreBluetooth")
            lastBLEEvent = "WHOOP realtime HR ON write acknowledged by CoreBluetooth · opcode 03"
            if whoop5HistorySyncRequested {
                startWhoop5HistoricalSync(to: peripheral)
            }
            statusText = whoop5HRStreamConfirmed
                ? "Connected · WHOOP realtime HR stream confirmed"
                : "Connected · HR stream requested · awaiting WHOOP confirmation/data"
            return
        }

        if kind == "SET_CLOCK_FOR_HISTORY" {
            if let error {
                whoopHistorySyncStatus = "SET_CLOCK write failed · \(error.localizedDescription)"
                recordVendorTimeline("Historical sync SET_CLOCK write failed · \(error.localizedDescription)")
                return
            }
            recordVendorTimeline("Historical sync SET_CLOCK write acknowledged · awaiting command response")
            return
        }
        if kind == "GET_DATA_RANGE_FOR_HISTORY" {
            if let error {
                whoopHistorySyncStatus = "GET_DATA_RANGE write failed · \(error.localizedDescription)"
                recordVendorTimeline("Historical sync GET_DATA_RANGE write failed · \(error.localizedDescription)")
                return
            }
            whoopHistorySyncStatus = "GET_DATA_RANGE written · settling before historical request"
            recordVendorTimeline("Historical sync GET_DATA_RANGE write acknowledged · 120ms settle")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.connectedPeripheral?.identifier == peripheral.identifier,
                      peripheral.state == .connected else { return }
                self.sendWhoop5HistoricalData(to: peripheral)
            }
            return
        }
        if kind == "SEND_HISTORICAL_DATA" {
            if let error {
                whoopHistorySyncStatus = "SEND_HISTORICAL_DATA write failed · \(error.localizedDescription)"
                recordVendorTimeline("Historical sync SEND_HISTORICAL_DATA write failed · \(error.localizedDescription)")
            } else {
                whoopHistorySyncStatus = "Historical request sent · waiting for HISTORY_START / Type-47"
                recordVendorTimeline("SEND_HISTORICAL_DATA write acknowledged by CoreBluetooth · waiting for WHOOP history stream")
            }
            return
        }

        if kind == "HISTORICAL_DATA_RESULT" {
            switch HistoricalAckWriteState.resolve(errorDescription: error?.localizedDescription) {
            case .failed(let message):
                whoopHistorySyncStatus = "HISTORY_END ACK write failed · \(message) · no band progress inferred"
                recordVendorTimeline("HISTORICAL_DATA_RESULT(23) write callback · failed · \(message) · awaiting retry")
            case .acknowledgedAwaitingBandProgress:
                whoopHistorySyncStatus = "HISTORY_END ACK write acknowledged by CoreBluetooth · awaiting band-side history progress"
                recordVendorTimeline("HISTORICAL_DATA_RESULT(23) write callback · CoreBluetooth acknowledged · awaiting HISTORY_START / next Type-47 / cursor evidence")
            }
            return
        }

        guard kind == "CLIENT_HELLO" else { return }
        whoop5HelloWritePending = false
        if let error {
            lastBLEEvent = "WHOOP 5.0 CLIENT_HELLO write failed · \(error.localizedDescription)"
            statusText = "Connected · WHOOP session handshake failed"
            recordVendorTimeline("CLIENT_HELLO write callback · failed · \(error.localizedDescription)")
            return
        }
        whoop5HelloWriteAcknowledged = true
        whoopSessionPhase = "CLIENT_HELLO write acknowledged · awaiting strap response"
        lastBLEEvent = "WHOOP 5.0 CLIENT_HELLO write acknowledged by CoreBluetooth · FD4B0002"
        recordVendorTimeline("CLIENT_HELLO write callback · acknowledged")
        statusText = "Connected · WHOOP 5.0 hello write acknowledged · awaiting response"
        // Re-arm vendor notifications after the command write callback, matching
        // the NOOP post-hello sequence. The callback confirms the write operation,
        // not independently that the strap accepted or encrypted the session.
        guard let service = characteristic.service else { return }
        for item in service.characteristics ?? [] {
            let uuid = item.uuid.uuidString.uppercased()
            if ["FD4B0003-CCE1-4033-93CE-002D5875F58A",
                "FD4B0004-CCE1-4033-93CE-002D5875F58A",
                "FD4B0005-CCE1-4033-93CE-002D5875F58A",
                "FD4B0007-CCE1-4033-93CE-002D5875F58A"].contains(uuid),
               item.properties.contains(.notify) {
                let priorState = vendorNotificationStates[uuid] ?? ""
                // The pre-hello request may still be awaiting CoreBluetooth's
                // notification-state callback. Do not enqueue a duplicate CCCD
                // operation; only retry channels that actually ended disabled
                // or failed, and leave already-enabled channels untouched.
                let requestAlreadyPending =
                    priorState == "subscription requested" ||
                    priorState == "post-hello subscription requested"
                guard !item.isNotifying, !requestAlreadyPending else {
                    recordVendorTimeline("post-hello notify skipped · \(uuid) · \(item.isNotifying ? "already enabled" : "request pending")")
                    continue
                }
                whoop5PostHelloNotifyRetryAttempted.insert(uuid)
                vendorNotificationStates[uuid] = "post-hello subscription requested"
                recordVendorTimeline("post-hello notify request · \(uuid)")
                peripheral.setNotifyValue(true, for: item)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              isCurrentGattCharacteristic(characteristic, on: peripheral) else { return }
        let notificationUUID = characteristic.uuid.uuidString.uppercased()
        if motionProbeUUIDPrefixes.contains(where: { notificationUUID.hasPrefix($0) }) {
            candidateNotificationStates[notificationUUID] = error.map { "failed · \($0.localizedDescription)" }
                ?? (characteristic.isNotifying ? "enabled" : "disabled")
            lastBLEEvent = "WHOOP candidate notification \(candidateNotificationStates[notificationUUID] ?? "updated") · \(notificationUUID)"
            return
        }
        if characteristic.service?.uuid == CBUUID(string: "FD4B0001-CCE1-4033-93CE-002D5875F58A") {
            let uuid = characteristic.uuid.uuidString.uppercased()
            vendorNotificationStates[uuid] = error.map { "failed · \($0.localizedDescription)" }
                ?? (characteristic.isNotifying ? "enabled" : "disabled")
            recordVendorTimeline("notify callback · \(uuid) · \(vendorNotificationStates[uuid] ?? "updated") · error=\(error?.localizedDescription ?? "none")")
            lastBLEEvent = "WHOOP vendor notification \(vendorNotificationStates[uuid] ?? "updated") · \(uuid)"
            // If the pre-hello CCCD operation completes disabled after the
            // hello write acknowledgement, retry that channel exactly once.
            // If it completed before the acknowledgement, didWriteValueFor
            // handles the retry instead. This closes the callback-order race
            // without creating an unbounded notification retry loop.
            if !characteristic.isNotifying,
               (error != nil || vendorNotificationStates[uuid] == "disabled"),
               whoop5HelloWriteAcknowledged,
               !whoop5PostHelloNotifyRetryAttempted.contains(uuid),
               characteristic.properties.contains(.notify) {
                whoop5PostHelloNotifyRetryAttempted.insert(uuid)
                vendorNotificationStates[uuid] = "post-hello subscription requested"
                recordVendorTimeline("post-hello notify retry · \(uuid) · initial callback disabled/failed")
                peripheral.setNotifyValue(true, for: characteristic)
            }
            return
        }
        guard characteristic.service?.uuid == CBUUID(string: "180D"),
              characteristic.uuid == CBUUID(string: "2A37") else { return }
        if let error {
            isStandardHeartRateNotifying = false
            lastBLEEvent = "Standard HR subscription failed · \(error.localizedDescription)"
            recordVendorTimeline("standard HR notify callback · failed · \(error.localizedDescription)")
            return
        }
        isStandardHeartRateNotifying = characteristic.isNotifying
        recordVendorTimeline("standard HR notify callback · \(characteristic.isNotifying ? "enabled" : "disabled")")
        if characteristic.isNotifying {
            hrTimingStandardNotifyEnabledAt = Date()
            let elapsed = hrTimingConnectionAt.map { Date().timeIntervalSince($0) } ?? 0
            hrTimingEvents.append(String(format: "180D/2A37 notify enabled +%.3fs", elapsed))
        }
        lastBLEEvent = characteristic.isNotifying
            ? "Standard Heart Rate Measurement notifications enabled · waiting for first sample"
            : "Standard Heart Rate Measurement notifications disabled"
        if characteristic.isNotifying && liveHeartRateBPM == nil {
            statusText = "Connected · HR notifications enabled · waiting for first sample"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              isCurrentGattCharacteristic(characteristic, on: peripheral) else { return }
        let serviceUUID = characteristic.service?.uuid.uuidString ?? "Unknown service"
        let displayKey = "\(serviceUUID)|\(characteristic.uuid.uuidString)"
        let key = ObjectIdentifier(characteristic)
        if let error {
            discoveredProfile.append("Descriptor error · \(displayKey) · \(error.localizedDescription)")
            lastBLEEvent = "Descriptor discovery error · \(displayKey) · \(error.localizedDescription)"
        } else {
            let descriptors = characteristic.descriptors ?? []
            if descriptors.isEmpty {
                discoveredProfile.append("Descriptors · \(displayKey) · none exposed")
            } else {
                for descriptor in descriptors {
                    discoveredProfile.append("Descriptor · service \(serviceUUID) → characteristic \(characteristic.uuid.uuidString) → \(descriptor.uuid.uuidString)")
                }
            }
        }
        pendingDescriptorCharacteristics.remove(key)
        if pendingCharacteristicServices.isEmpty && pendingDescriptorCharacteristics.isEmpty {
            updateGattDiscoveryCompletionStatus()
        } else if pendingCharacteristicServices.isEmpty {
            statusText = "Inspecting GATT descriptors · \(pendingDescriptorCharacteristics.count) remaining"
        }
    }

}
