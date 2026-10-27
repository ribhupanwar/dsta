import Foundation
import CoreBluetooth
import Combine

struct DiscoveredWearable: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var id: UUID { peripheral.identifier }
}

final class WhoopBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var devices: [DiscoveredWearable] = []
    @Published private(set) var statusText = "Bluetooth is starting"
    @Published private(set) var connectedName: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var discoveredProfile: [String] = []

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var pendingCharacteristicServices = Set<String>()

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
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
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
            central.cancelPeripheralConnection(peripheral)
            statusText = "Disconnecting…"
        } else {
            clearConnectionState()
            statusText = "Disconnected"
        }
    }

    func connect(to device: DiscoveredWearable) {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        central.stopScan()
        discoveredProfile.removeAll()
        connectedPeripheral = device.peripheral
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
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            statusText = connectedPeripheral == nil ? "Bluetooth ready" : "Bluetooth ready · restoring connection state"
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

    private func clearConnectionState() {
        connectedName = nil
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
        let hasCandidateService = advertisedServices.contains {
            candidateUUIDs.contains($0.uuidString.uppercased())
        }
        guard name.localizedCaseInsensitiveContains("whoop") || hasCandidateService else { return }

        let item = DiscoveredWearable(peripheral: peripheral, name: name, rssi: RSSI.intValue)
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
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        connectedName = nil
        isConnecting = false
        connectedPeripheral = nil
        discoveredProfile.removeAll()
        statusText = error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected"
    }
}

extension WhoopBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        let invalidatedIDs = Set(invalidatedServices.map { $0.uuid.uuidString })
        discoveredProfile.removeAll { line in
            invalidatedIDs.contains { line.contains($0) }
        }
        pendingCharacteristicServices.subtract(invalidatedIDs)
        statusText = "GATT services changed · refreshing profile"
        pendingCharacteristicServices.removeAll()
        discoveredProfile.removeAll()
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if let error {
            statusText = "Service discovery failed: \(error.localizedDescription)"
            return
        }
        guard let services = peripheral.services else { return }
        pendingCharacteristicServices = Set(services.map { $0.uuid.uuidString })
        guard !services.isEmpty else {
            statusText = "Connected · no GATT services exposed"
            return
        }
        for service in services {
            discoveredProfile.append("Service · \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        statusText = "Found \(services.count) service(s) · inspecting characteristics"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if let error {
            discoveredProfile.append("Service error · \(error.localizedDescription)")
            return
        }
        if let error {
            discoveredProfile.append("Service error · \(service.uuid.uuidString) · \(error.localizedDescription)")
        } else {
            for characteristic in service.characteristics ?? [] {
                discoveredProfile.append("  \(characteristic.uuid.uuidString) · \(propertyNames(characteristic.properties))")
            }
        }
        pendingCharacteristicServices.remove(service.uuid.uuidString)
        if pendingCharacteristicServices.isEmpty {
            statusText = "GATT profile inspected · no commands sent"
        } else {
            statusText = "Inspecting characteristics · \(pendingCharacteristicServices.count) service(s) remaining"
        }
    }
}
