import Foundation
import CoreBluetooth
import Combine

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
    @Published private(set) var heartRateUpdateCount = 0
    @Published private(set) var liveHeartRateSamples: [LiveHeartRateSample] = []
    @Published private(set) var workoutHeartRateSamples: [LiveHeartRateSample] = []
    @Published private(set) var workoutStartedAt: Date?
    @Published private(set) var workoutIsRecording = false
    @Published private(set) var lastWorkoutDurationSeconds: TimeInterval?
    @Published private(set) var whoopIMUFrameCount = 0
    @Published private(set) var whoopIMUSampleCount = 0
    @Published private(set) var whoopIMULastFrameAt: Date?
    @Published private(set) var whoopIMUStatus = "Waiting for WHOOP motion stream"

    var freshHeartRateBPM: Int? {
        guard connectedName != nil, let lastHeartRateAt,
              Date().timeIntervalSince(lastHeartRateAt) <= 8 else { return nil }
        return liveHeartRateBPM
    }

    func startWorkoutRecording() {
        guard connectedName != nil, !workoutIsRecording else { return }
        workoutHeartRateSamples.removeAll()
        workoutStartedAt = Date()
        lastWorkoutDurationSeconds = nil
        workoutIsRecording = true
        statusText = "Workout recording · waiting for HR samples"
    }

    func stopWorkoutRecording() {
        guard workoutIsRecording else { return }
        if let workoutStartedAt {
            lastWorkoutDurationSeconds = Date().timeIntervalSince(workoutStartedAt)
        }
        workoutIsRecording = false
        workoutStartedAt = nil
        persistWorkoutSession()
        statusText = "Workout saved on this iPhone · \(workoutHeartRateSamples.count) HR samples"
    }

    private func persistWorkoutSession() {
        if let data = try? JSONEncoder().encode(workoutHeartRateSamples) {
            UserDefaults.standard.set(data, forKey: "pulseforge.whoop.lastWorkoutSamples")
        }
        if let duration = lastWorkoutDurationSeconds {
            UserDefaults.standard.set(duration, forKey: "pulseforge.whoop.lastWorkoutDuration")
        }
    }

    private var vendorNotificationStates: [String: String] = [:]
    private var vendorNotificationPayloads: [String: String] = [:]
    private var vendorNotificationHistory: [String] = []
    private var candidateNotificationStates: [String: String] = [:]
    private var candidateNotificationHistory: [String] = []
    private let motionProbeUUIDPrefixes = ["8A58", "5983", "6108", "1150"]
    private let whoop5ServiceUUID = CBUUID(string: "FD4B0001-CCE1-4033-93CE-002D5875F58A")
    private let whoop5CommandUUID = CBUUID(string: "FD4B0002-CCE1-4033-93CE-002D5875F58A")
    private var whoop5CommandCharacteristic: CBCharacteristic?
    private var whoop5HelloSent = false
    private var whoop5HelloWritePending = false
    private var whoop5HRStreamEnableSent = false
    private var whoop5HRStreamConfirmed = false
    private var whoop5AutoIMUStartRequested = false
    private var whoop5AutoIMUEnabled = false
    private var whoop5PendingWrites: [String] = []
    private var whoop5NextCommandSequence: UInt8 = 2
    private var hrTimingConnectionAt: Date?
    private var hrTimingStandardNotifyRequestedAt: Date?
    private var hrTimingStandardNotifyEnabledAt: Date?
    private var hrTimingFirstSampleAt: Date?
    private var hrTimingEvents: [String] = []

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var connectedDeviceSnapshot: DiscoveredWearable?
    private var pendingRestoredPeripheral: CBPeripheral?
    private let rememberedPeripheralKey = "pulseforge.whoop.lastPeripheralUUID"
    private var isAutomaticReconnectScan = false
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
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
        if let data = UserDefaults.standard.data(forKey: "pulseforge.whoop.lastWorkoutSamples"),
           let savedSamples = try? JSONDecoder().decode([LiveHeartRateSample].self, from: data) {
            workoutHeartRateSamples = savedSamples
        }
        lastWorkoutDurationSeconds = UserDefaults.standard.object(forKey: "pulseforge.whoop.lastWorkoutDuration") as? Double
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.ribhupanwar.pulseforge.bluetooth-central"]
        )
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
        central.stopScan()
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
        central.stopScan()
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
        central.stopScan()
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
            "WHOOP IMU frames: \(whoopIMUFrameCount) · samples: \(whoopIMUSampleCount) · status: \(whoopIMUStatus)",
            "WHOOP IMU last frame: \(whoopIMULastFrameAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
            "WHOOP protocol diagnosis: \(whoopProtocolDiagnostics)",
            "WHOOP packet counts · realtime: \(whoopRealtimePacketCount) · command responses: \(whoopCommandResponseCount)",
            "WHOOP last packet type: \(whoopLastPacketType)",
            "WHOOP FD4B vendor notification subscriptions:",
            "",
            "GATT profile:"
        ]
        lines.append(contentsOf: vendorNotificationStates.keys.sorted().map { "  \($0): \(vendorNotificationStates[$0] ?? "unknown")" })
        lines.append(contentsOf: vendorNotificationPayloads.keys.sorted().map { "  Latest full payload \($0): \(vendorNotificationPayloads[$0] ?? "none")" })
        lines.append("")
        lines.append("WHOOP vendor notification history (latest 40 events):")
        lines.append(contentsOf: vendorNotificationHistory.isEmpty ? ["  No vendor payload events captured"] : vendorNotificationHistory)
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
            central.stopScan()
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
                central.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, self.isAutomaticReconnectScan else { return }
                    self.central.stopScan()
                    self.isAutomaticReconnectScan = false
                    self.statusText = "WHOOP not found · open Device and tap Scan to retry"
                }
            }
            return
        }

        pendingRestoredPeripheral = nil
        connectedPeripheral = peripheral
        connectedDeviceSnapshot = nil
        peripheral.delegate = self
        connectedName = peripheral.name ?? "WHOOP"
        isConnecting = peripheral.state != .connected
        resetGattSessionForReconnect()

        if peripheral.state == .connected {
            statusText = "WHOOP connection recovered · rediscovering services"
            lastBLEEvent = "Recovered existing CoreBluetooth peripheral · refreshing GATT"
            peripheral.discoverServices(nil)
        } else {
            statusText = "Reconnecting to previously used WHOOP…"
            lastBLEEvent = "Automatic reconnect requested for remembered WHOOP peripheral"
            central.connect(peripheral, options: nil)
        }
    }

    private func resetGattSessionForReconnect() {
        pendingCharacteristicServices.removeAll()
        pendingDescriptorCharacteristics.removeAll()
        discoveredProfile.removeAll()
        vendorNotificationStates.removeAll()
        vendorNotificationPayloads.removeAll()
        vendorNotificationHistory.removeAll()
        candidateNotificationStates.removeAll()
        candidateNotificationHistory.removeAll()
        whoop5CommandCharacteristic = nil
        whoop5HelloSent = false
        whoop5HelloWritePending = false
        whoop5HRStreamEnableSent = false
        whoop5HRStreamConfirmed = false
        whoop5AutoIMUStartRequested = false
        whoop5AutoIMUEnabled = false
        whoopIMUFrameCount = 0
        whoopIMUSampleCount = 0
        whoopIMULastFrameAt = nil
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

    private func clearConnectionState() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        pendingCharacteristicServices.removeAll()
        pendingDescriptorCharacteristics.removeAll()
        connectedName = nil
        connectedDeviceSnapshot = nil
        if workoutIsRecording, let workoutStartedAt {
            lastWorkoutDurationSeconds = Date().timeIntervalSince(workoutStartedAt)
            persistWorkoutSession()
        }
        workoutIsRecording = false
        workoutStartedAt = nil
        liveHeartRateBPM = nil
        liveHeartRateSamples.removeAll()
        isStandardHeartRateNotifying = false
        lastHeartRateAt = nil
        heartRateUpdateCount = 0
        vendorNotificationStates.removeAll()
        vendorNotificationPayloads.removeAll()
        vendorNotificationHistory.removeAll()
        whoop5CommandCharacteristic = nil
        whoop5HelloSent = false
        whoop5HelloWritePending = false
        whoop5HRStreamEnableSent = false
        whoop5HRStreamConfirmed = false
        whoop5AutoIMUStartRequested = false
        whoop5AutoIMUEnabled = false
        whoopIMUFrameCount = 0
        whoopIMUSampleCount = 0
        whoopIMULastFrameAt = nil
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
            isAutomaticReconnectScan = false
            central.stopScan()
            connectedPeripheral = peripheral
            connectedDeviceSnapshot = nil
            peripheral.delegate = self
            isConnecting = true
            connectedName = peripheral.name ?? "WHOOP"
            resetGattSessionForReconnect()
            lastBLEEvent = "Remembered WHOOP found during automatic reconnect scan"
            statusText = "Reconnecting to WHOOP…"
            central.connect(peripheral, options: nil)
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
        isConnecting = false
        peripheral.delegate = self
        connectedName = peripheral.name ?? "WHOOP candidate"
        statusText = "Connected · discovering GATT profile"
        hrTimingConnectionAt = Date()
        hrTimingEvents = ["connected +0.000s"]
        lastBLEEvent = "Connected · waiting for characteristic value"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        clearConnectionState()
        statusText = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        clearConnectionState()
        statusText = error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected"
    }
}

extension WhoopBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        let invalidatedIDs = Array(Set(invalidatedServices.map { $0.uuid.uuidString })).sorted()
        pendingCharacteristicServices.removeAll()
        pendingDescriptorCharacteristics.removeAll()
        discoveredProfile.removeAll()
        let invalidatedSummary = invalidatedIDs.isEmpty ? "unspecified services" : invalidatedIDs.joined(separator: ", ")
        lastBLEEvent = "GATT services invalidated · \(invalidatedSummary) · refreshing profile"
        statusText = "GATT services changed · refreshing profile"
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
            whoopProtocolDiagnostics = diagnoseWhoop5Frame(data, peripheral: peripheral)
            vendorNotificationPayloads[uuid] = "\(data.count) bytes · \(hex.isEmpty ? "empty" : hex)"
            vendorNotificationHistory.append("\(timestamp) · \(uuid) · \(data.count) bytes · HEX: \(hex.isEmpty ? "empty" : hex)")
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
        case 36: // COMMAND_RESPONSE
            whoopCommandResponseCount += 1
            let command = Int(b[10])
            guard b.count > 12 else { return "COMMAND_RESPONSE · cmd \(command) · truncated" }
            let echoedSequence = Int(b[11])
            let result = Int(b[12])
            let resultName = [0: "FAILURE", 1: "SUCCESS", 2: "PENDING", 3: "UNSUPPORTED"][result] ?? "UNKNOWN(\(result))"
            if command == 81 {
                if result == 1 {
                    sendWhoopAutoIMUEnable(to: peripheral)
                    return "COMMAND_RESPONSE · START_RAW_DATA(81) SUCCESS · requesting IMU mode"
                }
                whoopIMUStatus = "WHOOP rejected START_RAW_DATA · result \(resultName)"
                return "COMMAND_RESPONSE · START_RAW_DATA(81) · result \(resultName)"
            }
            if command == 106 {
                whoop5AutoIMUEnabled = result == 1
                whoopIMUStatus = result == 1 ? "IMU mode accepted · awaiting motion frames" : "IMU mode rejected · \(resultName)"
                return "COMMAND_RESPONSE · TOGGLE_IMU_MODE(106) · result \(resultName)"
            }
            if command == 145 {
                guard result == 1, echoedSequence == 1 else {
                    return "COMMAND_RESPONSE · GET_HELLO · seq echo \(echoedSequence) · result \(resultName) · CRC valid"
                }
                // Gen5 HELLO revision-1 semantic body spans 104 bytes.
                guard b.count >= 121 else {
                    return "COMMAND_RESPONSE · GET_HELLO success but body too short (\(b.count) bytes)"
                }
                sendRealtimeHrEnable(to: peripheral)
                return "COMMAND_RESPONSE · GET_HELLO(145) SUCCESS · CRC valid · realtime HR enable requested"
            }
            return "COMMAND_RESPONSE · command \(command) · seq echo \(echoedSequence) · result \(resultName) · CRC valid"

        case 47: // WHOOP 5/MG raw six-axis IMU buffer (type 0x2F; NOOP hardware decoder)
            // Exact 1244-byte frame layout: timestamp @15, accel count @24,
            // accel columns @28/@228/@428, gyro count @630, gyro columns @640/@840/@1040.
            guard b.count == 1244 else {
                whoopIMUStatus = "IMU type 47 · unexpected length \(b.count) bytes"
                return "RAW_IMU(0x2F) · unexpected length \(b.count) · CRC valid"
            }
            func u16(_ offset: Int) -> Int {
                Int(b[offset]) | (Int(b[offset + 1]) << 8)
            }
            func i16(_ offset: Int) -> Int {
                let value = u16(offset)
                return value >= 32768 ? value - 65536 : value
            }
            func u32(_ offset: Int) -> UInt32 {
                UInt32(b[offset]) | (UInt32(b[offset + 1]) << 8)
                    | (UInt32(b[offset + 2]) << 16) | (UInt32(b[offset + 3]) << 24)
            }
            let accelCount = u16(24)
            let gyroCount = u16(630)
            guard accelCount == 100, gyroCount == 100 else {
                whoopIMUStatus = "IMU layout not recognised · A:\(accelCount) G:\(gyroCount)"
                return "RAW_IMU(0x2F) · invalid counts A:\(accelCount) G:\(gyroCount)"
            }
            // Decode and sanity-check the six columnar channels using WHOOP's documented scales.
            // This avoids reporting an active stream based only on a matching packet length.
            let axes = [28, 228, 428, 640, 840, 1040]
            for index in 0..<100 {
                let ax = Double(i16(axes[0] + index * 2)) / 4096.0
                let ay = Double(i16(axes[1] + index * 2)) / 4096.0
                let az = Double(i16(axes[2] + index * 2)) / 4096.0
                let gx = Double(i16(axes[3] + index * 2)) * 2000.0 / 32768.0
                let gy = Double(i16(axes[4] + index * 2)) * 2000.0 / 32768.0
                let gz = Double(i16(axes[5] + index * 2)) * 2000.0 / 32768.0
                guard [ax, ay, az, gx, gy, gz].allSatisfy({ $0.isFinite }) else {
                    whoopIMUStatus = "IMU sample decode failed"
                    return "RAW_IMU(0x2F) · invalid sample values"
                }
            }
            let strapTimestamp = TimeInterval(u32(15))
            whoopIMUFrameCount += 1
            whoopIMUSampleCount += accelCount
            whoopIMULastFrameAt = strapTimestamp > 0 ? Date(timeIntervalSince1970: strapTimestamp) : Date()
            whoopIMUStatus = "Live motion active · \(whoopIMUFrameCount) one-second frames"
            return "RAW_IMU(0x2F) · 100 Hz six-axis · frame \(whoopIMUFrameCount) · CRC valid"

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
            if eventID == 33 {
                whoop5HRStreamConfirmed = true
                lastBLEEvent = "WHOOP event 33 · BLE_REALTIME_HR_ON · stream activation confirmed"
                statusText = "Connected · WHOOP realtime HR stream confirmed · waiting for sample"
                startWhoopAutoIMUIfNeeded()
                return "EVENT · BLE_REALTIME_HR_ON(33) · CRC valid · automatic IMU start requested"
            }
            if eventID == 34 {
                whoop5HRStreamConfirmed = false
                lastBLEEvent = "WHOOP event 34 · BLE_REALTIME_HR_OFF"
                return "EVENT · BLE_REALTIME_HR_OFF(34) · CRC valid"
            }
            if eventID == 3, b.count > 22 {
                let socRaw = Int(b[21]) | (Int(b[22]) << 8)
                return "EVENT · BATTERY_LEVEL(3) · \(Double(socRaw) / 10.0)% · CRC valid"
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

    /// Start the hardware-verified WHOOP 5/MG IMU producer after live HR is confirmed.
    /// Sequence: START_RAW_DATA (81) payload [01], then TOGGLE_IMU_MODE (106) [01,01].
    private func startWhoopAutoIMUIfNeeded() {
        guard !whoop5AutoIMUStartRequested,
              let peripheral = connectedPeripheral,
              let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else { return }
        whoop5AutoIMUStartRequested = true
        whoopIMUStatus = "Requesting automatic WHOOP motion stream"
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x51, payload: [0x01])
        whoop5PendingWrites.append("START_RAW_DATA")
        lastBLEEvent = "Automatic IMU START_RAW_DATA requested · sequence \(sequence)"
        peripheral.writeValue(frame, for: command, type: .withResponse)
    }

    private func sendWhoopAutoIMUEnable(to peripheral: CBPeripheral) {
        guard let command = whoop5CommandCharacteristic,
              command.properties.contains(.write) else { return }
        let sequence = whoop5NextCommandSequence
        whoop5NextCommandSequence &+= 1
        let frame = buildWhoop5CommandFrame(sequence: sequence, opcode: 0x6A, payload: [0x01, 0x01])
        whoop5PendingWrites.append("TOGGLE_IMU_MODE")
        lastBLEEvent = "Automatic IMU TOGGLE_IMU_MODE requested · sequence \(sequence)"
        peripheral.writeValue(frame, for: command, type: .withResponse)
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
        lastBLEEvent = "WHOOP realtime HR ON command requested · opcode 03 · sequence \(sequence)"
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
        if whoop5HRStreamConfirmed {
            startWhoopAutoIMUIfNeeded()
        }
        if workoutIsRecording {
            workoutHeartRateSamples.append(sample)
            if workoutHeartRateSamples.count > 14_400 {
                workoutHeartRateSamples.removeFirst(workoutHeartRateSamples.count - 14_400)
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
                if motionProbeUUIDPrefixes.contains(where: { characteristicUUID.hasPrefix($0) }), (characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)) {
                    candidateNotificationStates[characteristicUUID] = "passive subscription requested"
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if service.uuid == whoop5ServiceUUID && characteristic.uuid == whoop5CommandUUID {
                    whoop5CommandCharacteristic = characteristic
                }
                if service.uuid == whoop5ServiceUUID,
                   fd4bNotifyUUIDs.contains(characteristicUUID),
                   characteristic.properties.contains(.notify) {
                    vendorNotificationStates[characteristicUUID] = "subscription requested"
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                let key = ObjectIdentifier(characteristic)
                pendingDescriptorCharacteristics.insert(key)
                peripheral.discoverDescriptors(for: characteristic)
            }
            // WHOOP 5.0/MG requires its session hello on FD4B0002. The frame is
            // transcribed in NOOP's DeviceFamily.whoop5ClientHello constant.
            // Send once per connection, with response, after all characteristics
            // (including notify channels) have been discovered/requested.
            if service.uuid == whoop5ServiceUUID,
               !whoop5HelloSent,
               let command = whoop5CommandCharacteristic,
               command.properties.contains(.write) {
                let hello: [UInt8] = [
                    0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
                    0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D
                ]
                whoop5HelloSent = true
                whoop5HelloWritePending = true
                whoop5PendingWrites.append("CLIENT_HELLO")
                lastBLEEvent = "WHOOP 5.0 CLIENT_HELLO write requested · FD4B0002 · 16 bytes · with response"
                statusText = "Connected · starting WHOOP 5.0 secure session"
                peripheral.writeValue(Data(hello), for: command, type: .withResponse)
            } else if service.uuid == whoop5ServiceUUID,
                      whoop5CommandCharacteristic == nil {
                lastBLEEvent = "WHOOP 5.0 command characteristic FD4B0002 not found"
            }
        }
        pendingCharacteristicServices.remove(ObjectIdentifier(service))
        if pendingCharacteristicServices.isEmpty && pendingDescriptorCharacteristics.isEmpty {
            updateGattDiscoveryCompletionStatus()
        } else if pendingCharacteristicServices.isEmpty {
            statusText = "Inspecting GATT descriptors · \(pendingDescriptorCharacteristics.count) remaining"
        } else {
            statusText = "Inspecting characteristics · \(pendingCharacteristicServices.count) service(s) remaining"
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              characteristic.uuid == whoop5CommandUUID,
              !whoop5PendingWrites.isEmpty else { return }
        let kind = whoop5PendingWrites.removeFirst()

        if kind == "START_RAW_DATA" {
            if let error {
                whoop5AutoIMUStartRequested = false
                whoopIMUStatus = "START_RAW_DATA write failed · \(error.localizedDescription)"
                return
            }
            whoopIMUStatus = "START_RAW_DATA write acknowledged · awaiting strap response"
            return
        }
        if kind == "TOGGLE_IMU_MODE" {
            if let error {
                whoopIMUStatus = "IMU mode write failed · \(error.localizedDescription)"
            } else {
                whoopIMUStatus = "IMU mode write acknowledged · awaiting motion frames"
            }
            return
        }

        if kind == "REALTIME_HR_ON" {
            if let error {
                whoop5HRStreamEnableSent = false
                lastBLEEvent = "WHOOP realtime HR ON write failed · \(error.localizedDescription)"
                statusText = "Connected · live HR command failed"
                return
            }
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
        lastBLEEvent = "WHOOP 5.0 CLIENT_HELLO write acknowledged by CoreBluetooth · FD4B0002"
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
                vendorNotificationStates[uuid] = "post-hello subscription requested"
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
            lastBLEEvent = "WHOOP vendor notification \(vendorNotificationStates[uuid] ?? "updated") · \(uuid)"
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
