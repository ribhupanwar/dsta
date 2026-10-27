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
    @Published private(set) var discoveredProfile: [String] = []

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?

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
        devices.removeAll()
        discoveredProfile.removeAll()
        statusText = "Scanning nearby devices…"
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScan() {
        central.stopScan()
        if connectedPeripheral == nil { statusText = "Scan stopped" }
    }

    func disconnect() {
        central.stopScan()
        if let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            connectedName = nil
            discoveredProfile.removeAll()
            statusText = "Disconnected"
        }
    }

    func connect(to device: DiscoveredWearable) {
        central.stopScan()
        discoveredProfile.removeAll()
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
        statusText = "Connecting to \(device.name)…"
        central.connect(device.peripheral, options: nil)
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
        case .poweredOn: statusText = "Bluetooth ready"
        case .poweredOff: statusText = "Bluetooth is off"
        case .unauthorized: statusText = "Bluetooth permission not granted"
        case .unsupported: statusText = "Bluetooth LE is unavailable"
        case .resetting: statusText = "Bluetooth is resetting"
        case .unknown: statusText = "Bluetooth state unknown"
        @unknown default: statusText = "Bluetooth state unavailable"
        }
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
        connectedName = peripheral.name ?? "WHOOP candidate"
        statusText = "Connected · discovering GATT profile"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusText = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
        connectedPeripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        connectedName = nil
        connectedPeripheral = nil
        discoveredProfile.removeAll()
        statusText = error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected"
    }
}

extension WhoopBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            statusText = "Service discovery failed: \(error.localizedDescription)"
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            discoveredProfile.append("Service · \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        statusText = "Found \(services.count) service(s) · inspecting characteristics"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            discoveredProfile.append("Service error · \(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            discoveredProfile.append("  \(characteristic.uuid.uuidString) · \(propertyNames(characteristic.properties))")
        }
        statusText = "GATT profile inspected · no commands sent"
    }
}
