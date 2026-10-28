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
    @Published private(set) var whoopCommandResponseCount = 0
    @Published private(set) var whoopLastPacketType = "None"
    @Published private(set) var whoopBatteryPercent: Double?
    @Published private(set) var whoopBatteryLastUpdatedAt: Date?
    @Published private(set) var whoopEventPacketCount = 0
    @Published private(set) var whoopLastEventID: Int?
    @Published private(set) var whoopLastEventFrameHex = "none"
    @Published private(set) var whoopConnectionGeneration = 0
    @Published private(set) var whoopSessionPhase = "Disconnected"
    @Published private(set) var heartRateUpdateCount = 0
    @Published private(set) var liveHeartRateSamples: [LiveHeartRateSample] = []
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
    @Published private(set) var whoopIMUSampleCount = 0
    @Published private(set) var whoopIMULastFrameAt: Date?
    @Published private(set) var whoopIMUStatus = "Waiting for WHOOP motion stream"
    @Published private(set) var whoopIMULastRawFrameHex = "none"
    private var whoopIMURawFrameHistory: [String] = []
    @Published private(set) var liveWhoopIMUSamples: [WhoopIMUSample] = []
    @Published private(set) var workoutWhoopIMUSamples: [WhoopIMUSample] = []
    private var lastWhoopIMUPersistedSampleCount = 0

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
                            if let workout {
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
    private var whoop5RawStreamStopWorkItem: DispatchWorkItem?
    private var whoop5PendingWrites: [String] = []
    private var whoop5NextCommandSequence: UInt8 = 2
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
        let line = String(format: "%@ · +%.3fs · %@ · helloSent=%@ helloAckPending=%@ hrEnableSent=%@",
                          stamp, elapsed, event,
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
    private let automaticReconnectDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    private var pendingCharacteristicServices = Set<ObjectIdentifier>()
    private var pendingDescriptorCharacteristics = Set<ObjectIdentifier>()

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
            "WHOOP realtime HR ON event confirmed: \(whoop5HRStreamConfirmed ? "yes" : "no")",
            "WHOOP automatic IMU request: \(whoop5AutoIMUStartRequested ? "yes" : "no")",
            "WHOOP automatic IMU enabled: \(whoop5AutoIMUEnabled ? "yes" : "no")",
            "WHOOP IMU frames: \(whoopIMUFrameCount) · samples: \(whoopIMUSampleCount) · live buffer: \(liveWhoopIMUSamples.count) · workout samples: \(workoutWhoopIMUSamples.count) · status: \(whoopIMUStatus)",
            "WHOOP latest IMU sample: \(liveWhoopIMUSamples.last.map { String(format: "A %.3f, %.3f, %.3f g · G %.1f, %.1f, %.1f dps", $0.accelerationXG, $0.accelerationYG, $0.accelerationZG, $0.rotationXDPS, $0.rotationYDPS, $0.rotationZDPS) } ?? "none")",
            "WHOOP IMU last frame: \(whoopIMULastFrameAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
            "WHOOP latest CRC-valid raw IMU frame hex (type 47/51): \(whoopIMULastRawFrameHex)",
            "WHOOP IMU recent CRC-valid raw frames (oldest first):",
        ]
        lines.append(contentsOf: whoopIMURawFrameHistory.isEmpty ? ["  none"] : whoopIMURawFrameHistory.map { "  \($0)" })
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
        discoveredProfile.removeAll()
        vendorNotificationStates.removeAll()
        vendorNotificationPayloads.removeAll()
        vendorNotificationHistory.removeAll()
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
        whoop5HRStallRecoveryWorkItem?.cancel()
        whoop5HRStallRecoveryWorkItem = nil
        whoop5HRStallRecoveryAttempted = false
        whoop5HRStreamEnableSent = false
        whoop5HRStreamConfirmed = false
        whoop5AutoIMUStartRequested = false
        whoop5AutoIMUEnabled = false
        whoop5RawStreamStopWorkItem?.cancel()
        whoop5RawStreamStopWorkItem = nil
        // Keep the last known battery reading across BLE reconnects; WHOOP does not
        // necessarily emit BATTERY_LEVEL on every connection.
        whoopEventPacketCount = 0
        whoopLastEventID = nil
        whoopLastEventFrameHex = "none"
        whoopIMUFrameCount = 0
        whoopIMUSampleCount = 0
        whoopIMULastFrameAt = nil
        whoopIMULastRawFrameHex = "none"
        whoopIMURawFrameHistory.removeAll()
        liveWhoopIMUSamples.removeAll()
        whoopIMUStatus = "Waiting for WHOOP motion stream"
        whoop5PendingWrites.removeAll()
        whoop5NextCommandSequence = 2
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
        // A disconnect breaks detector continuity; discard the rolling baseline.
        workoutDetectionSamples.removeAll()
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
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
        whoop5AutoIMUStartRequested = false
        whoop5AutoIMUEnabled = false
        whoop5RawStreamStopWorkItem?.cancel()
        whoop5RawStreamStopWorkItem = nil
        whoopIMUFrameCount = 0
        whoopIMUSampleCount = 0
        whoopIMULastFrameAt = nil
        liveWhoopIMUSamples.removeAll()
        whoopIMUStatus = "Waiting for WHOOP motion stream"
        whoop5PendingWrites.removeAll()
        whoop5NextCommandSequence = 2
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
        guard automaticReconnectAttempt < automaticReconnectDelays.count else {
            statusText = "WHOOP reconnect paused after 6 attempts · tap Scan to retry"
            lastBLEEvent = "Automatic reconnect limit reached · \(reason)"
            return
        }
        reconnectWorkItem?.cancel()
        let delay = automaticReconnectDelays[automaticReconnectAttempt]
        automaticReconnectAttempt += 1
        let attempt = automaticReconnectAttempt
        connectedPeripheral = peripheral
        connectedDeviceSnapshot = nil
        peripheral.delegate = self
        connectedName = peripheral.name ?? "WHOOP"
        isConnecting = true
        resetGattSessionForReconnect()
        statusText = "WHOOP reconnecting · attempt \(attempt)/6 in \(Int(delay))s"
        lastBLEEvent = "Automatic reconnect scheduled · attempt \(attempt)/6 · \(reason)"
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  self.central.state == .poweredOn,
                  UserDefaults.standard.string(forKey: self.rememberedPeripheralKey) == peripheral.identifier.uuidString else { return }
            self.statusText = "WHOOP reconnecting · attempt \(attempt)/6"
            self.central.connect(peripheral, options: nil)
            self.scheduleReconnectTimeout(for: peripheral)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension WhoopBluetoothManager: CBPeripheralDelegate {
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
            return
        }
        guard let services = peripheral.services else {
            pendingCharacteristicServices.removeAll()
            pendingDescriptorCharacteristics.removeAll()
            statusText = "Connected · service list unavailable"
            return
        }
        pendingCharacteristicServices = Set(services.map { ObjectIdentifier($0) })
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
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if let error {
            lastBLEEvent = "Read/notification error · \(characteristic.uuid.uuidString) · \(error.localizedDescription)"
            return
        }
        if characteristic.service?.uuid == CBUUID(string: "FD4B0001-CCE1-4033-93CE-002D5875F58A") {
            let uuid = characteristic.uuid.uuidString.uppercased()
            let data = characteristic.value ?? Data()
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            let timestamp = ISO8601DateFormatter().string(from: Date())
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
        guard let data = characteristic.value,
              let bpm = parseStandardHeartRateMeasurement(data),
              (1...300).contains(bpm) else {
            lastBLEEvent = "Standard HR notification received · payload could not be parsed"
            return
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
        statusText = isStandardHeartRateNotifying
            ? "Connected · HR notifications enabled · waiting for first sample · \(inspection)"
            : "Connected · HR notification not enabled yet · \(inspection)"
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
                return diagnoseWhoop5Frame(chunk, peripheral: peripheral)
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
            diagnostics.append(diagnoseWhoop5Frame(completeFrame, peripheral: peripheral))
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
    private func diagnoseWhoop5Frame(_ data: Data, peripheral: CBPeripheral) -> String {
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
            return "WHOOP5 frame rejected · CRC16 header or CRC32 payload invalid"
        }

        let type = Int(b[8])
        whoopLastPacketType = "\(type)"
        switch type {
        // The NOOP Gen5 reference routes PUFFIN_COMMAND_RESPONSE (38) through the command-response decoder.
        case 36, 38: // COMMAND_RESPONSE / PUFFIN_COMMAND_RESPONSE share command, sequence and result fields.
            whoopCommandResponseCount += 1
            let command = Int(b[10])
            guard b.count > 12 else { return "COMMAND_RESPONSE · cmd \(command) · truncated" }
            let echoedSequence = Int(b[11])
            let result = Int(b[12])
            let resultName = [0: "FAILURE", 1: "SUCCESS", 2: "PENDING", 3: "UNSUPPORTED"][result] ?? "UNKNOWN(\(result))"
            recordVendorTimeline("COMMAND_RESPONSE · cmd=\(command) · seq=\(echoedSequence) · result=\(resultName) · frame=\(b.count) bytes · CRC valid")
            if command == 81 {
                if result == 2 {
                    whoopIMUStatus = "START_RAW_DATA pending · awaiting final response"
                    return "COMMAND_RESPONSE · START_RAW_DATA(81) · PENDING"
                }
                whoop5AutoIMUEnabled = result == 1
                if result == 1 {
                    whoopIMUStatus = "Bounded raw stream accepted · waiting for Gen5 R21 packets (type 43)"
                    scheduleWhoop5RawStreamStop(for: peripheral, after: 60)
                } else {
                    whoop5AutoIMUStartRequested = false
                    whoopIMUStatus = "START_RAW_DATA rejected · \(resultName)"
                }
                recordVendorTimeline("START_RAW_DATA(81) response · \(resultName)")
                return "COMMAND_RESPONSE · START_RAW_DATA(81) · \(resultName)"
            }
            if command == 82 {
                if result == 2 {
                    whoopIMUStatus = "STOP_RAW_DATA pending · awaiting final response"
                    return "COMMAND_RESPONSE · STOP_RAW_DATA(82) · PENDING"
                }
                whoop5AutoIMUEnabled = false
                whoop5AutoIMUStartRequested = false
                whoopIMUStatus = result == 1
                    ? "Bounded raw stream stopped · awaiting next session"
                    : "STOP_RAW_DATA rejected · \(resultName)"
                recordVendorTimeline("STOP_RAW_DATA(82) response · \(resultName)")
                return "COMMAND_RESPONSE · STOP_RAW_DATA(82) · \(resultName)"
            }
            if command == 145 {
                if result == 1 && echoedSequence == 1 {
                    let responseHex = b.map { String(format: "%02X", $0) }.joined(separator: " ")
                    recordVendorTimeline("GET_HELLO response raw HEX · \(responseHex)")
                }
                guard result == 1, echoedSequence == 1 else {
                    return "COMMAND_RESPONSE · GET_HELLO · seq echo \(echoedSequence) · result \(resultName) · CRC valid"
                }
                // Gen5 HELLO revision-1 semantic body spans 104 bytes.
                guard b.count >= 121 else {
                    recordVendorTimeline("GET_HELLO response rejected · body too short · \(b.count) bytes")
                    return "COMMAND_RESPONSE · GET_HELLO success but body too short (\(b.count) bytes)"
                }
                recordVendorTimeline("GET_HELLO response accepted · sequence 1 · success · minimum body length met")
                whoopSessionPhase = "GET_HELLO response parsed · requesting realtime HR"
                sendRealtimeHrEnable(to: peripheral)
                return "COMMAND_RESPONSE · GET_HELLO(145) SUCCESS · CRC valid · realtime HR enable requested"
            }
            if command == 3 {
                guard result == 1 else {
                    return "COMMAND_RESPONSE · REALTIME_HR_ON(3) · \(resultName) · bounded raw stream withheld"
                }
                whoopIMUStatus = "HR active · awaiting WHOOP 5 R22 historical R21 IMU buffers (type 47 / inner 0x2F)"
                recordVendorTimeline("IMU live raw commands 81/106 withheld · 5.0 firmware evidence shows accepted-but-inert; decode R22 R21 offload when present")
                return "COMMAND_RESPONSE · REALTIME_HR_ON(3) SUCCESS · HR active; high-rate IMU awaits R22 offload"
            }
            return "COMMAND_RESPONSE · command \(command) · seq echo \(echoedSequence) · result \(resultName) · CRC valid"

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
                liveWhoopIMUSamples.append(contentsOf: decoded)
                if liveWhoopIMUSamples.count > 2000 {
                    liveWhoopIMUSamples.removeFirst(liveWhoopIMUSamples.count - 2000)
                }
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

        case 47: // HISTORICAL_DATA; Gen5 R21 offload buffers share the R21 body layout.
            whoopIMUFrameCount += 1
            whoopIMULastFrameAt = Date()
            whoopIMULastRawFrameHex = b.map { String(format: "%02X", $0) }.joined()
            let capturedAt = ISO8601DateFormatter().string(from: Date())
            whoopIMURawFrameHistory.append("type=47 · \(capturedAt) · \(whoopIMULastRawFrameHex)")
            if whoopIMURawFrameHistory.count > 4 {
                whoopIMURawFrameHistory.removeFirst(whoopIMURawFrameHistory.count - 4)
            }

            // WHOOP 5 R22 can carry the same 1,244-byte R21 IMU body inside
            // historical type 47 (inner type 0x2F, revision 21). This is the
            // observed high-rate offload path; command ACKs alone do not prove
            // that live raw streaming (0x2B) or IMU mode (106) is active.
            if b.count == 1244, b[8] == 0x2F, b[9] == 21 {
                do {
                    let decoded = try Gen5R21IMUDecoder.decode(b)
                    guard !decoded.isEmpty else {
                        whoopIMUStatus = "Historical Gen5 R21 buffer valid · no paired samples"
                        return "HISTORICAL_R21_IMU(0x2F) · no paired samples · CRC valid"
                    }
                    liveWhoopIMUSamples.append(contentsOf: decoded)
                    if liveWhoopIMUSamples.count > 2000 {
                        liveWhoopIMUSamples.removeFirst(liveWhoopIMUSamples.count - 2000)
                    }
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

        case 40: // REALTIME_DATA; protocol inner[8] == complete-frame byte[16]
            whoopRealtimePacketCount += 1
            guard b.count > 16 else { return "REALTIME_DATA · too short for HR field · CRC valid" }
            let bpm = Int(b[16])
            guard (1...250).contains(bpm) else {
                return "REALTIME_DATA · HR byte \(bpm) outside plausible range · rejected · CRC valid"
            }
            recordHeartRateSample(bpm, source: "WHOOP5 REALTIME_DATA")
            return "REALTIME_DATA · HR \(bpm) bpm decoded at frame offset 16 · CRC valid"

        case 48: // EVENT
            guard b.count >= 20 else { return "EVENT · truncated · CRC valid" }
            let eventID = Int(b[10]) | (Int(b[11]) << 8)
            whoopEventPacketCount += 1
            whoopLastEventID = eventID
            whoopLastEventFrameHex = b.map { String(format: "%02X", $0) }.joined(separator: " ")
            if eventID == 33 {
                whoop5HRStreamConfirmed = true
                whoopSessionPhase = "Realtime HR stream confirmed · generation \(whoopConnectionGeneration)"
                recordVendorTimeline("WHOOP realtime HR active event 33 received")
                lastBLEEvent = "WHOOP event 33 · BLE_REALTIME_HR_ON · stream activation confirmed"
                statusText = "Connected · WHOOP realtime HR stream confirmed · waiting for sample"
                return "EVENT · BLE_REALTIME_HR_ON(33) · CRC valid · realtime HR active; IMU activation withheld pending protocol verification"
            }
            if eventID == 34 {
                whoop5HRStreamConfirmed = false
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

    /// Start Gen5 raw streaming with a bounded revision-2 duration.
    /// OpenStrap documents START_RAW_DATA (0x51) body [0x02][u32 duration-ms LE].
    /// Never use revision 1: the strap may default to a full 24-hour stream.
    private func sendWhoop5RawDataStart(to peripheral: CBPeripheral,
                                         durationMilliseconds: UInt32) {
        guard !whoop5AutoIMUStartRequested,
              durationMilliseconds > 0,
              durationMilliseconds <= 86_400_000,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else { return }
        whoop5AutoIMUStartRequested = true
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        let duration = durationMilliseconds
        let payload: [UInt8] = [
            0x02,
            UInt8(duration & 0xFF),
            UInt8((duration >> 8) & 0xFF),
            UInt8((duration >> 16) & 0xFF),
            UInt8((duration >> 24) & 0xFF)
        ]
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x51, payload: payload)
        whoop5PendingWrites.append("START_RAW_DATA_60S")
        let hex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        recordVendorTimeline("START_RAW_DATA write requested · opcode 51 · revision 2 · duration=\(durationMilliseconds)ms · seq=\(sequence) · HEX: \(hex)")
        whoopIMUStatus = "Bounded 60-second Gen5 raw stream requested · awaiting command response"
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

    /// Stop Gen5 raw streaming (STOP_RAW_DATA = 0x52, body [0x01]).
    private func sendWhoop5RawDataStop(to peripheral: CBPeripheral) {
        guard whoop5AutoIMUEnabled,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else { return }
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x52, payload: [0x01])
        whoop5PendingWrites.append("STOP_RAW_DATA_60S")
        recordVendorTimeline("STOP_RAW_DATA write requested · opcode 52 · revision 1 · seq=\(sequence)")
        whoopIMUStatus = "60-second raw stream elapsed · STOP_RAW_DATA requested"
        peripheral.writeValue(frame, for: command, type: .withResponse)
    }

    /// A single bounded recovery for the WHOOP 5.0 HR stream if it goes silent
    /// after producing data. Do not reconnect or loop retries; preserve the GATT session.
    private func scheduleWhoop5HRStallRecovery(from sampleTime: Date) {
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
        recordVendorTimeline("HR stall watchdog scheduled · 5 min after latest sample")
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
        whoop5PendingWrites.append("REALTIME_HR_ON")
        let frameHex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        lastBLEEvent = "WHOOP realtime HR ON command requested · opcode 03 · sequence \(sequence)"
        recordVendorTimeline("REALTIME_HR_ON write requested · FD4B0002 · seq=\(sequence) · \(frame.count) bytes · HEX: \(frameHex)")
        statusText = "Connected · requesting WHOOP live HR stream"
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
        }
        let sample = LiveHeartRateSample(timestamp: timestamp, bpm: bpm)
        liveHeartRateSamples.append(sample)
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
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if let error {
            discoveredProfile.append("Service error · \(service.uuid.uuidString) · \(error.localizedDescription)")
            lastBLEEvent = "Characteristic discovery error · service \(service.uuid.uuidString) · \(error.localizedDescription)"
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
        guard let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else {
            let hasWhoopService = discoveredProfile.contains {
                $0.contains("Service · \(whoop5ServiceUUID.uuidString)")
            }
            if hasWhoopService {
                lastBLEEvent = "WHOOP 5.0 command characteristic FD4B0002 not found after complete GATT discovery"
                recordVendorTimeline("CLIENT_HELLO withheld · FD4B0002 unavailable after all services discovered")
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
              characteristic.uuid == whoop5CommandUUID,
              !whoop5PendingWrites.isEmpty else { return }
        let kind = whoop5PendingWrites.removeFirst()

        if kind == "START_RAW_DATA_60S" {
            if let error {
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
                whoopIMUStatus = "STOP_RAW_DATA write failed · \(error.localizedDescription)"
                recordVendorTimeline("STOP_RAW_DATA write callback · failed · \(error.localizedDescription)")
            } else {
                whoopIMUStatus = "STOP_RAW_DATA write acknowledged · awaiting strap response"
                recordVendorTimeline("STOP_RAW_DATA write callback · acknowledged by CoreBluetooth")
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
            statusText = whoop5HRStreamConfirmed
                ? "Connected · WHOOP realtime HR stream confirmed"
                : "Connected · HR stream requested · awaiting WHOOP confirmation/data"
            return
        }

        guard kind == "CLIENT_HELLO" else { return }
        whoop5HelloWritePending = false
        if let error {
            lastBLEEvent = "WHOOP 5.0 CLIENT_HELLO write failed · \(error.localizedDescription)"
            statusText = "Connected · WHOOP session handshake failed"
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
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
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
            return
        }
        isStandardHeartRateNotifying = characteristic.isNotifying
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
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
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
