import Foundation

/// A communication path to a device. `supports` must reflect *verified and implemented* protocol support only.
public protocol SOLIXTransport: Sendable {
    var kind: TransportKind { get }
    func isAvailable() async -> Bool
    /// `nil` when supported, otherwise the human-readable reason it is not.
    func unsupportedReason(for op: DeviceOperation, device: SOLIXDevice) -> String?
}

public struct NoTransportError: Error, CustomStringConvertible, Sendable {
    public let operation: DeviceOperation
    public let reasons: [TransportKind: String]
    public var description: String {
        "No transport can perform “\(operation.rawValue)”: "
            + TransportKind.allCases.compactMap { k in reasons[k].map { "\(k.label) — \($0)" } }.joined(separator: "; ")
    }
}

/// Selects transports in the order Local Wi-Fi → Bluetooth → Cloud (or the user's override first).
/// Failover happens only for idempotent reads. A write is attempted on exactly one transport, once.
public struct TransportManager: Sendable {
    public static let defaultOrder: [TransportKind] = [.localWiFi, .bluetooth, .cloud]
    private let transports: [TransportKind: any SOLIXTransport]

    public init(transports: [any SOLIXTransport]) {
        self.transports = Dictionary(uniqueKeysWithValues: transports.map { ($0.kind, $0) })
    }

    public struct Selection: Sendable {
        public var ordered: [TransportKind]
        public var rejected: [TransportKind: String]
    }

    public func select(for op: DeviceOperation, device: SOLIXDevice) async -> Selection {
        var order = Self.defaultOrder
        if let p = device.preferredTransport, let i = order.firstIndex(of: p) { order.remove(at: i); order.insert(p, at: 0) }
        var ok: [TransportKind] = []; var rejected: [TransportKind: String] = [:]
        for k in order {
            guard let t = transports[k] else { rejected[k] = "not configured"; continue }
            if let reason = t.unsupportedReason(for: op, device: device) { rejected[k] = reason; continue }
            guard await t.isAvailable() else { rejected[k] = "currently unavailable"; continue }
            ok.append(k)
        }
        return Selection(ordered: ok, rejected: rejected)
    }

    /// Run `body` on the best transport. Returns the result and which transport produced it.
    public func run<T: Sendable>(
        _ op: DeviceOperation, device: SOLIXDevice,
        body: @Sendable (TransportKind) async throws -> T
    ) async throws -> (value: T, via: TransportKind) {
        let sel = await select(for: op, device: device)
        guard let first = sel.ordered.first else { throw NoTransportError(operation: op, reasons: sel.rejected) }
        if !op.isIdempotentRead {
            return (try await body(first), first)  // single attempt, no cross-transport retry
        }
        var lastError: Error?
        for k in sel.ordered {
            do { return (try await body(k), k) } catch { lastError = error }
        }
        throw lastError ?? NoTransportError(operation: op, reasons: sel.rejected)
    }
}

// MARK: - Concrete transports

/// Anker cloud: REST for the stored TOU plan, MQTT broker for live telemetry and device commands.
public struct CloudTransport: SOLIXTransport {
    public let kind = TransportKind.cloud
    let backend: any CloudStatusProviding
    public init(backend: any CloudStatusProviding) { self.backend = backend }

    public func isAvailable() async -> Bool { await backend.cloudSignedIn }

    public func unsupportedReason(for op: DeviceOperation, device: SOLIXDevice) -> String? {
        let p = ModelRegistry.resolve(partNumber: device.partNumber)
        switch op {
        case .monitor: return p.telemetryDocumented ? nil : "no documented telemetry layout for \(p.marketingName) (\(device.partNumber))"
        case .readTOUPlan: return nil  // read-only attribute query
        case .writeTOUPlan, .setUsageMode, .setBackupSOC:
            return p.capabilities.supportsTOU ? nil : p.touNote
        }
    }
}

/// BLE: encrypted-session telemetry is implemented for the models SolixBLE documents (A1763, A1790/A1790P).
/// There are no TOU / mode / reserve commands over Bluetooth.
public struct BluetoothTransport: SOLIXTransport {
    public let kind = TransportKind.bluetooth
    let availability: @Sendable () async -> Bool
    public init(availability: @escaping @Sendable () async -> Bool = { false }) { self.availability = availability }
    public func isAvailable() async -> Bool { await availability() }
    public func unsupportedReason(for op: DeviceOperation, device: SOLIXDevice) -> String? {
        switch op {
        case .monitor:
            return BLESession.supports(partNumber: device.partNumber) ? nil : "no documented Bluetooth telemetry layout for \(device.partNumber)"
        default: return "SolixBLE exposes no TOU / mode / reserve commands over Bluetooth"
        }
    }
}

/// Local Wi-Fi: no documented local protocol exists for these models (X1 Modbus TCP is the only known one).
public struct LocalWiFiTransport: SOLIXTransport {
    public let kind = TransportKind.localWiFi
    public init() {}
    public func isAvailable() async -> Bool { false }
    public func unsupportedReason(for op: DeviceOperation, device: SOLIXDevice) -> String? {
        "no documented local API for \(device.partNumber) (Modbus TCP is documented only for the X1 series)"
    }
}

public protocol CloudStatusProviding: Sendable {
    var cloudSignedIn: Bool { get async }
}
