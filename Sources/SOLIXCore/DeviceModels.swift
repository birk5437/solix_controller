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

public struct ModelProfile: Sendable, Hashable {
    public let partNumber: String
    public let marketingName: String
    public let capacityWh: Int
    public let capabilities: DeviceCapabilities
    /// Usage modes the *reference implementations* can set for this model over MQTT.
    public let settableUsageModes: [UsageMode]
    /// BLE advertised product_type (hex) when SolixBLE maps it.
    public let bleProductType: String?
    /// Why TOU is or is not available — shown verbatim in the UI.
    public let touNote: String
    public let sources: [String]
}

public enum ModelRegistry {
    static let sourceAPI = "thomluther/anker-solix-api"
    static let sourceBLE = "flip-dots/SolixBLE"

    static func pps(
        _ pn: String, _ name: String, _ wh: Int, ble: String?, tou: Bool,
        modes: [UsageMode], note: String, extra: [String]
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
            settableUsageModes: modes, bleProductType: ble, touNote: note,
            sources: [sourceAPI + " src/anker_solix_api/mqttmap.py"] + extra)
    }

    public static let profiles: [String: ModelProfile] = {
        let list = [
            pps("A1763", "SOLIX C1000 Gen 2", 1024, ble: "b118", tou: false, modes: [],
                note: "The reference MQTT map for A1763 contains no usage-mode / TOU command group (message 0090). Without a documented command this app will not send one.",
                extra: [sourceBLE + " SolixBLE/factory.py (b118 → C1000G2)"]),
            pps("A1783", "SOLIX C2000 Gen 2", 2048, ble: nil, tou: true, modes: [.standard, .timeOfUse],
                note: "TOU plan is stored via cloud attribute pps_use_time; the mode is switched with MQTT command group 0090 (field a2). Both are described for A1783.",
                extra: ["anker-solix-api mqttmap.py A1783 group 0090 / 0421 field d9", "anker-solix-api schedule.py set_pps_use_time"]),
            pps("A1790P", "SOLIX F3800 Plus", 3840, ble: "b112", tou: false, modes: [],
                note: "The reference MQTT map for A1790P contains no usage-mode / TOU command group. The cloud pps_use_time attribute may exist but the mode switch is undocumented, so TOU control is unsupported here.",
                extra: [sourceBLE + " SolixBLE/factory.py (b112 → F3800)"]),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.partNumber, $0) })
    }()

    public static func profile(for partNumber: String) -> ModelProfile? { profiles[partNumber] }

    /// Map a BLE advertised product_type (hex) back to a model.
    public static func profile(bleProductType: String) -> ModelProfile? {
        profiles.values.first { $0.bleProductType == bleProductType.lowercased() }
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

    public var profile: ModelProfile? { ModelRegistry.profile(for: partNumber) }
    public var capabilities: DeviceCapabilities { profile?.capabilities ?? .none }

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
