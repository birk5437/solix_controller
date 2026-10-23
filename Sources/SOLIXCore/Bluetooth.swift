import Foundation
import Observation
@preconcurrency import CoreBluetooth

/// Manufacturer record published under company id 0xFFFF (SolixBLE `advertisement.py`):
/// version(1) | mac(6) | bind_type(1) | product_type(2) | sku(3 if v1, 4 if v2) | capability(0-1)
public struct AnkerAdvertisement: Hashable, Sendable {
    public var version: Int
    public var mac: String
    public var bindType: Int
    public var productType: String   // hex, e.g. "b118"
    public var sku: String
    public var capability: UInt8?
    /// Capability bit 0x04: device accepts the encrypted ECDH negotiation.
    public var acceptsEncryptedNegotiation: Bool { (capability ?? 0) & 0x04 != 0 }

    /// `data` is the manufacturer payload *after* the 2-byte company identifier.
    public static func parse(_ data: Data) -> AnkerAdvertisement? {
        let b = [UInt8](data)
        guard b.count >= 11 else { return nil }
        let v = Int(b[0])
        let skuLen = v == 1 ? 3 : v == 2 ? 4 : 0
        guard skuLen > 0, b.count >= 10 + skuLen else { return nil }
        let mac = b[1...6].map { String(format: "%02X", $0) }.joined(separator: ":")
        let product = b[8...9].map { String(format: "%02x", $0) }.joined()
        let sku = String(decoding: b[10..<(10 + skuLen)].filter { $0 != 0 }, as: UTF8.self)
        return AnkerAdvertisement(version: v, mac: mac, bindType: Int(b[7]), productType: product, sku: sku,
                                  capability: b.count > 10 + skuLen ? b[10 + skuLen] : nil)
    }
}

public struct GATTCharacteristicInfo: Hashable, Sendable, Identifiable {
    public var id: String { uuid }
    public var uuid: String
    public var properties: [String]
    public var value: String?
}
public struct GATTServiceInfo: Hashable, Sendable, Identifiable {
    public var id: String { uuid }
    public var uuid: String
    public var characteristics: [GATTCharacteristicInfo]
}

public struct DiscoveredBLEDevice: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var rssi: Int
    public var advertisement: AnkerAdvertisement?
    public var serviceUUIDs: [String]
    public var lastSeen: Date
    public var connected = false
    public var connecting = false
    public var services: [GATTServiceInfo] = []
    public var modelGuess: ModelProfile? {
        advertisement.flatMap { ModelRegistry.profile(bleProductType: $0.productType) }
    }
    public var isKnownAnker: Bool { advertisement != nil || BLEConstants.identifiers.contains(where: serviceUUIDs.contains) }
}

public enum BLEConstants {
    // SolixBLE const.py
    public static let identifierServices = ["0000FF09-0000-1000-8000-00805F9B34FB", "00001780-0000-1000-8000-00805F9B34FB",
                                            "00002215-0000-1000-8000-00805F9B34FB"]
    public static var identifiers: [String] { identifierServices }
    public static let ankerCompanyID: UInt16 = 0xFFFF
    public static let infoCharacteristics: [String: String] = ["2A24": "Model number", "2A25": "Serial number", "2A26": "Firmware revision"]
}

@MainActor
@Observable
public final class BluetoothService: NSObject {
    public enum Availability: String, Sendable { case unknown, poweredOn, poweredOff, unauthorized, unsupported, resetting }

    public private(set) var availability: Availability = .unknown
    public private(set) var isScanning = false
    public private(set) var devices: [UUID: DiscoveredBLEDevice] = [:]
    public private(set) var log: [String] = []
    /// Peripheral identifiers to reconnect automatically (persisted by the app).
    public var trustedIdentifiers: Set<UUID> = []

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var wantConnected: Set<UUID> = []
    @ObservationIgnored private var pendingServices: [UUID: Int] = [:]
    @ObservationIgnored private var serviceBuffer: [UUID: [GATTServiceInfo]] = [:]

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    private func note(_ s: String) { log.append("\(Date().formatted(date: .omitted, time: .standard))  \(s)"); if log.count > 300 { log.removeFirst(100) } }

    public func startScan() {
        guard central.state == .poweredOn else { note("Cannot scan: Bluetooth is \(availability.rawValue)"); return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true; note("Scan started")
    }

    public func stopScan() { central.stopScan(); isScanning = false; note("Scan stopped") }

    public func connect(_ id: UUID) {
        guard let p = peripherals[id] else { return }
        wantConnected.insert(id)
        devices[id]?.connecting = true
        central.connect(p, options: nil)
        note("Connecting to \(p.name ?? id.uuidString)")
    }

    public func disconnect(_ id: UUID) {
        wantConnected.remove(id)
        if let p = peripherals[id] { central.cancelPeripheralConnection(p) }
    }

    private func reconnectTrusted() {
        guard central.state == .poweredOn, !trustedIdentifiers.isEmpty else { return }
        for p in central.retrievePeripherals(withIdentifiers: Array(trustedIdentifiers)) {
            peripherals[p.identifier] = p
            wantConnected.insert(p.identifier)
            if p.state == .disconnected { central.connect(p, options: nil); note("Reconnecting to \(p.name ?? p.identifier.uuidString)") }
        }
    }

    static func props(_ p: CBCharacteristicProperties) -> [String] {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoResp") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out
    }
}

extension BluetoothService: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            availability = switch central.state {
            case .poweredOn: .poweredOn
            case .poweredOff: .poweredOff
            case .unauthorized: .unauthorized
            case .unsupported: .unsupported
            case .resetting: .resetting
            default: .unknown
            }
            note("Bluetooth state: \(availability.rawValue)")
            if central.state == .poweredOn { reconnectTrusted() }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Extract Sendable values before hopping to the main actor.
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let uuids = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map(\.uuidString)
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unnamed"
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            var ad: AnkerAdvertisement?
            if let m = manufacturer, m.count > 2,
               UInt16(m[m.startIndex]) | UInt16(m[m.startIndex + 1]) << 8 == BLEConstants.ankerCompanyID {
                ad = AnkerAdvertisement.parse(Data(m.dropFirst(2)))
            }
            let looksAnker = ad != nil || uuids.contains(where: { BLEConstants.identifiers.contains($0.uppercased()) })
                || name.localizedCaseInsensitiveContains("solix") || name.localizedCaseInsensitiveContains("anker")
            guard looksAnker else { return }
            peripherals[peripheral.identifier] = peripheral
            var d = devices[peripheral.identifier] ?? DiscoveredBLEDevice(
                id: peripheral.identifier, name: name, rssi: rssi, advertisement: ad, serviceUUIDs: uuids, lastSeen: Date())
            d.name = name; d.rssi = rssi; d.lastSeen = Date()
            d.advertisement = ad ?? d.advertisement
            d.serviceUUIDs = Array(Set(d.serviceUUIDs + uuids))
            devices[peripheral.identifier] = d
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            devices[peripheral.identifier]?.connected = true
            devices[peripheral.identifier]?.connecting = false
            note("Connected to \(peripheral.name ?? "device")")
            peripheral.delegate = self
            serviceBuffer[peripheral.identifier] = []
            peripheral.discoverServices(nil)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            devices[peripheral.identifier]?.connecting = false
            note("Connect failed: \(error?.localizedDescription ?? "unknown error")")
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            devices[peripheral.identifier]?.connected = false
            note("Disconnected from \(peripheral.name ?? "device")\(error.map { ": \($0.localizedDescription)" } ?? "")")
            let id = peripheral.identifier
            if wantConnected.contains(id) || trustedIdentifiers.contains(id) {
                // Automatic reconnect after a short delay.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if self.wantConnected.contains(id) || self.trustedIdentifiers.contains(id), let p = self.peripherals[id], self.central.state == .poweredOn {
                        self.central.connect(p, options: nil)
                    }
                }
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let svcs = peripheral.services ?? []
            pendingServices[peripheral.identifier] = svcs.count
            for s in svcs { peripheral.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let chars = service.characteristics ?? []
            var info = GATTServiceInfo(uuid: service.uuid.uuidString, characteristics: chars.map {
                GATTCharacteristicInfo(uuid: $0.uuid.uuidString, properties: Self.props($0.properties), value: nil)
            })
            // Only the standard, read-only Device Information characteristics are read. Nothing is written.
            for c in chars where BLEConstants.infoCharacteristics[c.uuid.uuidString.uppercased()] != nil && c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
            info.characteristics = info.characteristics
            serviceBuffer[peripheral.identifier, default: []].append(info)
            devices[peripheral.identifier]?.services = serviceBuffer[peripheral.identifier] ?? []
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let data = characteristic.value, let str = String(data: data, encoding: .utf8) else { return }
            let id = peripheral.identifier
            guard var d = devices[id] else { return }
            for si in d.services.indices {
                for ci in d.services[si].characteristics.indices where d.services[si].characteristics[ci].uuid == characteristic.uuid.uuidString {
                    d.services[si].characteristics[ci].value = str
                }
            }
            devices[id] = d
            serviceBuffer[id] = d.services
            note("\(BLEConstants.infoCharacteristics[characteristic.uuid.uuidString.uppercased()] ?? characteristic.uuid.uuidString): \(str)")
        }
    }
}
