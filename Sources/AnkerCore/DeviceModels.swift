import Foundation

// MARK: - Transports & operations

public enum TransportKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case localWiFi, bluetooth, cloud
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .localWiFi: "Local Wi-Fi"
        case .bluetooth: "Bluetooth"
        case .cloud: "Anker Cloud"
        }
    }
}

/// Operations a driver may support over a transport.
public enum DeviceOperation: String, Codable, CaseIterable, Sendable {
    case monitor
    case readTOUPlan
    case writeTOUPlan
    case setUsageMode
    case setBackupSOC
}

extension DeviceOperation {
    /// Reads are safe to fail over between transports; writes are never retried across transports.
    public var isIdempotentRead: Bool { self == .monitor || self == .readTOUPlan }
}

// MARK: - Capabilities

/// Capabilities per device. Populated from `ModelRegistry`, which only contains what the
/// reference implementations (see `sources`) document for the model — never inferred from the name.
public struct DeviceCapabilities: Codable, Hashable, Sendable {
    public var supportsBluetoothMonitoring: Bool
    public var supportsBluetoothControl: Bool
    public var supportsLocalWiFiMonitoring: Bool
    public var supportsLocalWiFiControl: Bool
    public var supportsCloudMonitoring: Bool
    public var supportsCloudControl: Bool
    public var supportsTOU: Bool
    public var supportsTOUScheduling: Bool
    public var supportsGridCharging: Bool
    public var supportsReserveSOC: Bool

    public static let none = DeviceCapabilities(
        supportsBluetoothMonitoring: false, supportsBluetoothControl: false,
        supportsLocalWiFiMonitoring: false, supportsLocalWiFiControl: false,
        supportsCloudMonitoring: false, supportsCloudControl: false,
        supportsTOU: false, supportsTOUScheduling: false,
        supportsGridCharging: false, supportsReserveSOC: false)
}

public enum UsageMode: Int, Codable, CaseIterable, Sendable, Identifiable {
    case standard = 0
    case timeOfUse = 1
    case selfConsumption = 2
    case custom = 3
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .standard: "Standard (UPS)"
        case .timeOfUse: "Time of Use"
        case .selfConsumption: "Self-Consumption"
        case .custom: "Custom"
        }
    }
}

// MARK: - Model registry

public enum ModelCategory: String, Codable, CaseIterable, Sendable {
    case portablePowerStation, expansionBattery, solarbank, powerBank, poweredCooler, homeBackup, homeEnergy
    case microinverter, smartMeter, smartPlug, charger, evCharger, generator, other
    public var label: String {
        switch self {
        case .portablePowerStation: "Portable power station"
        case .expansionBattery: "Expansion battery"
        case .solarbank: "Solarbank"
        case .powerBank: "Power bank"
        case .poweredCooler: "Powered cooler"
        case .homeBackup: "Home backup"
        case .homeEnergy: "Home energy system"
        case .microinverter: "Microinverter"
        case .smartMeter: "Smart meter"
        case .smartPlug: "Smart plug"
        case .charger: "Charger"
        case .evCharger: "EV charger"
        case .generator: "Generator"
        case .other: "Anker SOLIX device"
        }
    }
}

public struct ModelProfile: Sendable, Hashable {
    public let partNumber: String
    public let marketingName: String
    public var category: ModelCategory = .portablePowerStation
    public let capacityWh: Int
    /// A telemetry layout for this model is implemented (cloud MQTT and/or Bluetooth). Without one the device is
    /// listed and its raw frames can be captured, but no values are decoded.
    public var telemetryDocumented: Bool = false
    public let capabilities: DeviceCapabilities
    /// Usage modes the *reference implementations* can set for this model over MQTT.
    public let settableUsageModes: [UsageMode]
    /// The documented Battery-Only ("AC input disabled") switch exists and is described for this model.
    public let supportsBatteryOnlyControl: Bool
    /// BLE advertised product_type (hex) when SolixBLE maps it.
    public let bleProductType: String?
    /// Why TOU is or is not available — shown verbatim in the UI.
    public let touNote: String
    public let sources: [String]
}

extension ModelProfile {
    fileprivate func documented() -> ModelProfile { var p = self; p.telemetryDocumented = true; return p }
}

public enum ModelRegistry {
    static let sourceAPI = "thomluther/anker-solix-api"
    static let sourceBLE = "flip-dots/SolixBLE"

    static func pps(
        _ pn: String, _ name: String, _ wh: Int, ble: String?, tou: Bool,
        modes: [UsageMode], note: String, extra: [String], batteryOnly: Bool = false
    ) -> ModelProfile {
        ModelProfile(
            partNumber: pn, marketingName: name, capacityWh: wh,
            capabilities: DeviceCapabilities(
                supportsBluetoothMonitoring: ble != nil,
                // SolixBLE controls only output switches/light/display, none of which this app drives yet.
                supportsBluetoothControl: ble != nil,
                supportsLocalWiFiMonitoring: false, supportsLocalWiFiControl: false,
                supportsCloudMonitoring: true,  // via Anker MQTT (mqttmap.py), cloud REST has no live PPS data
                supportsCloudControl: tou,
                supportsTOU: tou, supportsTOUScheduling: tou,
                supportsGridCharging: false,  // AC charge limit is mapped, but TOU-driven grid charging is device-side
                supportsReserveSOC: tou),
            settableUsageModes: modes, supportsBatteryOnlyControl: batteryOnly, bleProductType: ble, touNote: note,
            sources: [sourceAPI + " src/anker_solix_api/mqttmap.py"] + extra)
            .documented()
    }

    public static let profiles: [String: ModelProfile] = {
        let list = [
            pps("A1763", "SOLIX C1000 Gen 2", 1024, ble: "b118", tou: false, modes: [],
                note: "The reference MQTT map for A1763 contains no usage-mode / TOU command group (message 0090). Without a documented command this app will not send one.",
                extra: [sourceBLE + " SolixBLE/factory.py (b118 → C1000G2)"]),
            pps("A1765", "SOLIX C1000X Gen 2", 1024, ble: "b119", tou: false, modes: [],
                note: "Shares the C1000 Gen 2 class in SolixBLE (b119). No usage-mode / TOU command group is documented, so this app will not send one.",
                extra: [sourceBLE + " SolixBLE/factory.py (b119 → C1000G2)"]),
            pps("A1783", "SOLIX C2000 Gen 2", 2048, ble: nil, tou: true, modes: [.standard, .timeOfUse],
                note: "TOU plan is stored via cloud attribute pps_use_time; the mode is switched with MQTT command group 0090 (field a2). Both are described for A1783.",
                extra: ["anker-solix-api mqttmap.py A1783 group 0090 / 0421 field d9", "anker-solix-api schedule.py set_pps_use_time",
                        "mqttmap.py A1783 a4[0x31] battery_only_switch; group 0101 field ab"], batteryOnly: true),
            pps("A1790", "SOLIX F3800", 3840, ble: "b106", tou: false, modes: [],
                note: "The reference MQTT map for A1790 contains no usage-mode / TOU command group, so TOU control is unsupported here.",
                extra: [sourceBLE + " SolixBLE/factory.py (b106 → F3800)"]),
            pps("A1790P", "SOLIX F3800 Plus", 3840, ble: "b112", tou: false, modes: [],
                note: "The reference MQTT map for A1790P contains no usage-mode / TOU command group. The cloud pps_use_time attribute may exist but the mode switch is undocumented, so TOU control is unsupported here.",
                extra: [sourceBLE + " SolixBLE/factory.py (b112 → F3800)"]),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.partNumber, $0) })
    }()

    /// Every other SOLIX model known to the reference projects (`apitypes.py`, SolixBLE `factory.py`). These are listed,
    /// named and sized correctly, but nothing is decoded or sent: no telemetry layout or command is documented for them.
    static func listed(_ pn: String, _ name: String, _ category: ModelCategory = .portablePowerStation, wh: Int = 0, ble: String? = nil) -> ModelProfile {
        var p = ModelProfile(
            partNumber: pn, marketingName: name, category: category, capacityWh: wh,
            capabilities: DeviceCapabilities(
                supportsBluetoothMonitoring: false, supportsBluetoothControl: false,
                supportsLocalWiFiMonitoring: false, supportsLocalWiFiControl: false,
                supportsCloudMonitoring: false, supportsCloudControl: false,
                supportsTOU: false, supportsTOUScheduling: false, supportsGridCharging: false, supportsReserveSOC: false),
            settableUsageModes: [], supportsBatteryOnlyControl: false, bleProductType: ble, touNote: Self.listedNote,
            sources: [sourceAPI + " src/anker_solix_api/apitypes.py"])
        p.telemetryDocumented = false
        return p
    }

    static let listedNote = "This model is recognised, but the reference projects document no telemetry layout or control command for it, so the app only lists it and captures raw MQTT frames (Diagnostics → Protocol Capture). It will not send commands it cannot verify."

    static let catalog: [ModelProfile] = {
        typealias C = ModelCategory
        return [
            listed("A110A", "Prime Power Bank 300 W", .powerBank, wh: 100), listed("A110B", "Prime Power Bank 220 W (20K)", .powerBank, wh: 72),
            listed("A110G", "Prime Power Bank 220 W (20K)", .powerBank, wh: 72), listed("A1340", "Prime Power Bank 250 W", .powerBank, wh: 100),
            listed("A17C0", "Solarbank E1600 (Gen 1)", .solarbank, wh: 1600), listed("A17C1", "Solarbank 2 E1600 Pro", .solarbank, wh: 1600, ble: "b006"),
            listed("A17C2", "Solarbank 2 E1600 AC", .solarbank, wh: 1600), listed("A17C3", "Solarbank 2 E1600 Plus", .solarbank, wh: 1600),
            listed("A17C5", "Solarbank 3 E2700 Pro", .solarbank, wh: 2688), listed("AE103", "Solarbank 4 E5000 Pro", .solarbank, wh: 5024),
            listed("A17E2", "Solarbank Max AC", .solarbank, wh: 7000), listed("AE111", "Solarbank Max", .solarbank, wh: 7000),
            listed("A1720", "PowerHouse 521", wh: 256), listed("A1722", "SOLIX C300", wh: 288), listed("A1723", "SOLIX C300X", wh: 288),
            listed("A1725", "SOLIX C200(X)", wh: 230), listed("A1726", "SOLIX C300 DC", wh: 288), listed("A1727", "SOLIX C200 DC", wh: 192),
            listed("A1728", "SOLIX C300X DC", wh: 288), listed("A1729", "SOLIX C200X DC", wh: 230),
            listed("A1751", "PowerHouse 535", wh: 512), listed("A1753", "SOLIX C800", wh: 768, ble: "b103"),
            listed("A1754", "SOLIX C800 Plus", wh: 768, ble: "b103"), listed("A1755", "SOLIX C800X", wh: 768, ble: "b103"),
            listed("A1760", "PowerHouse 555", wh: 1024), listed("A1761", "SOLIX C1000(X)", wh: 1056),
            listed("A1762", "SOLIX Portable Power Station 1000", wh: 1056), listed("AS100", "SOLIX C1000 Gen 2 LE", wh: 1024),
            listed("AS220", "SOLIX S2000", wh: 2010), listed("A1770", "PowerHouse 757 / F1200", wh: 1229), listed("A1771", "SOLIX F1200", wh: 1229),
            listed("A1772", "SOLIX F1500", wh: 1536), listed("A1780", "SOLIX F2000", wh: 2048), listed("A1780P", "SOLIX F2000 (WLAN)", wh: 2048),
            listed("A1781", "SOLIX F2600", wh: 2560), listed("A1782", "SOLIX F3000", wh: 3072), listed("A1785", "SOLIX C2000X Gen 2", wh: 2048),
            listed("AS510", "SOLIX S5000", wh: 5000),
            listed("A17A0", "Powered Cooler 30", .poweredCooler, wh: 299), listed("A17A1", "Powered Cooler 40", .poweredCooler, wh: 299),
            listed("A17A2", "Powered Cooler 50", .poweredCooler, wh: 299), listed("A17A3", "SOLIX Everfrost 2 23L", .poweredCooler, wh: 288),
            listed("A17A4", "SOLIX Everfrost 2 40L", .poweredCooler, wh: 288), listed("A17A5", "SOLIX Everfrost 2 58L", .poweredCooler, wh: 288),
            listed("A1780_1", "F2000 expansion battery", .expansionBattery, wh: 2048), listed("A1790_1", "BP3800 expansion battery", .expansionBattery, wh: 3840),
            listed("A5220", "X1 battery module", .homeEnergy, wh: 5000), listed("AE113", "SOLIX XE 6/8kW", .homeEnergy, wh: 7000),
            listed("A17E1", "E10 controller", .homeBackup, wh: 6144), listed("DJXM", "E10 expansion battery", .expansionBattery, wh: 6144),
            listed("A5140", "MI60 microinverter", .microinverter), listed("A5143", "MI80 microinverter", .microinverter),
            listed("A5101", "X1 energy module", .homeEnergy), listed("A5102", "X1 energy module", .homeEnergy), listed("A5103", "X1 energy module", .homeEnergy),
            listed("A5150", "X1 microinverter", .homeEnergy), listed("A5450", "X1 Zigbee dongle", .homeEnergy), listed("A17B1", "Home Power Panel", .homeBackup),
            listed("A17X7", "Smart Meter", .smartMeter), listed("A17X7US", "Smart Meter (US)", .smartMeter), listed("AE1X0", "Smart Meter", .smartMeter),
            listed("AE1R0", "Smart Meter", .smartMeter), listed("SHEM3", "Shelly 3EM", .smartMeter), listed("SHEMP3", "Shelly Pro 3EM", .smartMeter),
            listed("ECOIR", "EcoTracker", .smartMeter), listed("A17X8", "Smart Plug", .smartPlug), listed("SHPPS", "Shelly Plus Plug S", .smartPlug),
            listed("AE100", "Power Dock", .homeBackup), listed("AX1S0", "Power Dock Pro", .homeBackup), listed("AX170", "Power Dock", .homeBackup),
            listed("A1903", "Charger 150 W", .charger), listed("A2345", "Prime Charger 250 W", .charger, ble: "b402"), listed("A2687", "Charger 160 W", .charger),
            listed("A25X7", "Wireless charger", .charger), listed("A91B2", "Charger 240 W", .charger), listed("AS200", "Alternator charger", .charger),
            listed("A5191", "V1 Smart EV Charger", .evCharger), listed("A7320", "SOLIX Smart Generator 5500", .generator),
        ]
    }()

    /// Documented profiles first, then the listed catalog.
    public static func profile(for partNumber: String) -> ModelProfile? {
        profiles[partNumber] ?? catalogByPN[partNumber]
    }

    static let catalogByPN: [String: ModelProfile] = Dictionary(catalog.map { ($0.partNumber, $0) }, uniquingKeysWith: { a, _ in a })

    /// Always returns a profile: unknown Anker part numbers get a generic listed-only profile named after the part number.
    public static func resolve(partNumber: String, name: String? = nil) -> ModelProfile {
        profile(for: partNumber) ?? {
            var p = listed(partNumber, name.flatMap { $0.isEmpty ? nil : $0 } ?? (partNumber.isEmpty ? "Anker SOLIX device" : "Anker SOLIX \(partNumber)"), .other)
            p.telemetryDocumented = false
            return p
        }()
    }

    /// Map a BLE advertised product_type (hex) back to a model.
    public static func profile(bleProductType: String) -> ModelProfile? {
        let t = bleProductType.lowercased()
        return profiles.values.first { $0.bleProductType == t } ?? catalog.first { $0.bleProductType == t }
    }
}

// MARK: - Device

public enum ConnectionStatus: String, Codable, Sendable {
    case online, offline, connecting, unknown
}

public struct SOLIXDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: String { serial }
    public var serial: String
    public var partNumber: String
    public var name: String
    public var isOwner: Bool
    public var firmware: String?
    public var status: ConnectionStatus = .unknown
    public var activeTransports: [TransportKind] = []
    public var preferredTransport: TransportKind?  // user override
    /// CoreBluetooth peripheral identifier when this device was added (or linked) over Bluetooth.
    public var bleIdentifier: UUID?
    /// Bluetooth MAC (no separators) from the advertisement or the cloud; used to match one physical battery across both.
    public var bluetoothMAC: String?
    /// Bluetooth-only entries have no Anker serial; they use a synthetic `ble-<uuid>` id.
    public var isBluetoothOnly: Bool { serial.hasPrefix("ble-") }

    /// Never nil: part numbers outside the catalog resolve to a generic listed-only profile.
    public var profile: ModelProfile? { ModelRegistry.resolve(partNumber: partNumber, name: nil) }
    public var capabilities: DeviceCapabilities { ModelRegistry.resolve(partNumber: partNumber).capabilities }

    public init(serial: String, partNumber: String, name: String, isOwner: Bool, firmware: String? = nil) {
        self.serial = serial; self.partNumber = partNumber; self.name = name
        self.isOwner = isOwner; self.firmware = firmware
    }
}

// MARK: - Telemetry

public struct BatteryTelemetry: Codable, Hashable, Sendable {
    public var timestamp: Date = Date()
    public var socPercent: Double?
    public var inputPowerW: Double?
    public var outputPowerW: Double?
    public var acInputW: Double?
    public var dcInputW: Double?
    public var acOutputW: Double?
    public var temperatureC: Double?
    public var remainingHours: Double?
    public var minSOC: Int?
    public var maxSOC: Int?
    public var firmware: String?
    public var usageMode: Int?
    public var activeTariff: Int?
    public var backupSOC: Int?
    public var touSchedule: [TOUSlot]?
    public var acPlugStatus: Int?
    public var batteryOnlySwitch: Int?
    public var rawFieldCount: Int = 0

    public init() {}

    /// Net battery power: positive = charging.
    public var netChargingW: Double? {
        guard let i = inputPowerW, let o = outputPowerW else { return nil }
        return i - o
    }

    /// Estimated runtime in hours: from device when available, else from capacity and load.
    public func estimatedRuntimeHours(capacityWh: Int) -> Double? {
        if let r = remainingHours, r > 0 { return r }
        guard let soc = socPercent, let net = netChargingW, net < -1 else { return nil }
        return (Double(capacityWh) * soc / 100) / -net
    }

    public mutating func merge(_ other: BatteryTelemetry) {
        func pick<T>(_ a: T?, _ b: T?) -> T? { b ?? a }
        timestamp = other.timestamp
        socPercent = pick(socPercent, other.socPercent)
        inputPowerW = pick(inputPowerW, other.inputPowerW)
        outputPowerW = pick(outputPowerW, other.outputPowerW)
        acInputW = pick(acInputW, other.acInputW)
        dcInputW = pick(dcInputW, other.dcInputW)
        acOutputW = pick(acOutputW, other.acOutputW)
        temperatureC = pick(temperatureC, other.temperatureC)
        remainingHours = pick(remainingHours, other.remainingHours)
        minSOC = pick(minSOC, other.minSOC)
        maxSOC = pick(maxSOC, other.maxSOC)
        firmware = pick(firmware, other.firmware)
        usageMode = pick(usageMode, other.usageMode)
        activeTariff = pick(activeTariff, other.activeTariff)
        backupSOC = pick(backupSOC, other.backupSOC)
        touSchedule = pick(touSchedule, other.touSchedule)
        acPlugStatus = pick(acPlugStatus, other.acPlugStatus)
        batteryOnlySwitch = pick(batteryOnlySwitch, other.batteryOnlySwitch)
        rawFieldCount += other.rawFieldCount
    }
}
