import Foundation

public struct TelemetryUpdate: Sendable {
    public var serial: String
    public var telemetry: BatteryTelemetry
}

/// One captured MQTT frame, for the protocol-investigation view.
public struct CapturedFrame: Identifiable, Sendable, Hashable {
    public enum Direction: String, Sendable { case inbound = "←", outbound = "→" }
    public var id = UUID()
    public var time = Date()
    public var direction: Direction
    public var serial: String
    public var topic: String
    public var msgType: String
    public var hex: String
    public var decoded: [String: Double]
    /// Field names (hex) whose bytes differ from the previous frame of the same message type.
    public var changedFields: [String]
    public var note: String?
}

public enum BackendError: Error, CustomStringConvertible, Sendable {
    case notSignedIn, mqttUnavailable, unsupportedCommand(String)
    public var description: String {
        switch self {
        case .notSignedIn: "Not signed in to the Anker cloud."
        case .mqttUnavailable: "MQTT command channel is not connected."
        case .unsupportedCommand(let s): "Refusing to send an undocumented command: \(s)"
        }
    }
}

public actor CloudBackend: TOUBackend, CloudStatusProviding {
    private var client: AnkerCloudClient?
    private let mqtt = MQTTClient()
    private var info: MQTTInfo?
    private var devices: [String: SOLIXDevice] = [:]
    private var store: [String: BatteryTelemetry] = [:]
    private var modeFrameStamp: [String: Date] = [:]
    private var frameStamp: [String: Date] = [:]
    private var lastFields: [String: [UInt8: Data]] = [:]
    private var captured: [CapturedFrame] = []
    private var pump: Task<Void, Never>?
    private var trigger: Task<Void, Never>?
    private let log: @Sendable (String) -> Void
    private var updateContinuation: AsyncStream<TelemetryUpdate>.Continuation?
    public nonisolated let updates: AsyncStream<TelemetryUpdate>
    private let http: HTTPTransporting

    public init(http: HTTPTransporting = URLSessionTransport(), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.http = http; self.log = log
        var c: AsyncStream<TelemetryUpdate>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        updateContinuation = c
    }

    public var cloudSignedIn: Bool { get async { await client?.isLoggedIn ?? false } }
    public var mqttConnected: Bool { get async { await mqtt.isConnected } }
    public var capturedFrames: [CapturedFrame] { captured }
    public func clearCapture() { captured.removeAll() }

    // MARK: Session

    public func signIn(email: String, password: String, country: String) async throws -> [CloudDevice] {
        let c = AnkerCloudClient(country: country, http: http, audit: log)
        try await c.login(email: email, password: password)
        client = c
        return try await c.listDevices()
    }

    public func signOut() async {
        pump?.cancel(); trigger?.cancel()
        await mqtt.disconnect()
        await client?.logout(); client = nil; info = nil
    }

    /// Connect the MQTT channel and start real-time telemetry for the given devices.
    public func startMonitoring(_ list: [SOLIXDevice]) async throws {
        guard let client else { throw BackendError.notSignedIn }
        for d in list { devices[d.serial] = d }
        let i = try await client.mqttInfo()
        info = i
        try await mqtt.connect(info: i)
        for d in list { try await mqtt.subscribe(AnkerEnvelope.subscribeTopics(info: i, pn: d.partNumber, sn: d.serial)) }
        if pump == nil {
            let stream = mqtt.messages
            pump = Task { [weak self] in
                for await m in stream { await self?.handle(m) }
            }
        }
        trigger?.cancel()
        trigger = Task { [weak self] in
            while !Task.isCancelled {
                for d in list { try? await self?.requestTelemetry(d) }
                try? await Task.sleep(nanoseconds: 50_000_000_000)
            }
        }
        log("MQTT connected; monitoring \(list.count) device(s)")
    }

    // MARK: Inbound

    private func handle(_ m: MQTTMessage) {
        guard let env = AnkerEnvelope.decode(topic: m.topic, payload: m.payload),
              let sn = env.serial, let pn = env.partNumber else { return }
        let hex = env.frame.map { String(format: "%02x", $0) }.joined()
        let msg: HexMessage
        do { msg = try HexMessage.parse(env.frame) } catch {
            record(CapturedFrame(direction: .inbound, serial: sn, topic: m.topic, msgType: "?", hex: hex, decoded: [:],
                                 changedFields: [], note: "unparseable frame: \(error)"))
            return
        }
        let values = TelemetryDecoder.values(partNumber: pn, message: msg)
        let key = "\(sn)/\(msg.msgTypeHex)"
        let prev = lastFields[key] ?? [:]
        var now: [UInt8: Data] = [:]
        for f in msg.fields { now[f.name] = f.value }
        let changed = msg.fields.filter { prev.isEmpty ? false : prev[$0.name] != $0.value }.map(\.nameHex)
        lastFields[key] = now
        record(CapturedFrame(direction: .inbound, serial: sn, topic: m.topic, msgType: msg.msgTypeHex, hex: hex,
                             decoded: values, changedFields: changed,
                             note: msg.encrypted ? "encrypted payload (not decoded)" : nil))
        guard let t = TelemetryDecoder.telemetry(partNumber: pn, message: msg) else { return }
        var merged = store[sn] ?? BatteryTelemetry()
        merged.merge(t)
        store[sn] = merged
        frameStamp[sn] = Date()
        if msg.field(0xd9) != nil { modeFrameStamp[sn] = Date() }
        updateContinuation?.yield(TelemetryUpdate(serial: sn, telemetry: merged))
    }

    private func record(_ f: CapturedFrame) {
        captured.append(f)
        if captured.count > 600 { captured.removeFirst(captured.count - 600) }
    }

    // MARK: TOUBackend

    public func fetchCloudPlan(serial: String) async throws -> TOUPlan? {
        guard let client else { throw BackendError.notSignedIn }
        let attrs = try await client.deviceAttributes(serial: serial, names: ["pps_use_time", "currency"])
        guard let s = attrs["pps_use_time"], !s.isEmpty else { return nil }
        return TOUPlan(cloudJSON: s)
    }

    public func pushCloudPlan(serial: String, plan: TOUPlan) async throws {
        guard let client else { throw BackendError.notSignedIn }
        try await client.setDeviceAttributes(serial: serial, attributes: ["pps_use_time": try plan.cloudJSONString()])
    }

    private func publish(_ device: SOLIXDevice, _ message: HexMessage, note: String) async throws {
        guard let info else { throw BackendError.mqttUnavailable }
        let frame = message.encode()
        let payload = try AnkerEnvelope.command(info: info, pn: device.partNumber, sn: device.serial, frame: frame)
        try await mqtt.publish(topic: AnkerEnvelope.commandTopic(info: info, pn: device.partNumber, sn: device.serial), payload: payload)
        record(CapturedFrame(direction: .outbound, serial: device.serial, topic: "cmd", msgType: message.msgTypeHex,
                             hex: frame.map { String(format: "%02x", $0) }.joined(), decoded: [:], changedFields: [], note: note))
    }

    public func sendUsageMode(_ device: SOLIXDevice, mode: UsageMode) async throws {
        guard device.profile?.settableUsageModes.contains(mode) == true else {
            throw BackendError.unsupportedCommand("usage mode \(mode.label) for \(device.partNumber)")
        }
        try await publish(device, SOLIXCommand.setUsageMode(mode), note: "set usage mode → \(mode.label)")
    }

    public func sendBackupSOC(_ device: SOLIXDevice, soc: Int) async throws {
        guard device.profile?.capabilities.supportsReserveSOC == true else {
            throw BackendError.unsupportedCommand("backup SOC for \(device.partNumber)")
        }
        try await publish(device, try SOLIXCommand.setBackupSOC(soc), note: "set backup SOC → \(soc)%")
    }

    public func requestTelemetry(_ device: SOLIXDevice) async throws {
        // Realtime trigger (0057) is mapped for every supported PPS model.
        try await publish(device, SOLIXCommand.realtimeTrigger(timeout: 60), note: "realtime trigger")
    }

    public func latestTelemetry(serial: String) async -> BatteryTelemetry? { store[serial] }

    public func awaitTelemetry(serial: String, since: Date, timeout: TimeInterval,
                               where predicate: @Sendable (BatteryTelemetry) -> Bool) async -> BatteryTelemetry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let t = store[serial], (modeFrameStamp[serial] ?? frameStamp[serial] ?? .distantPast) > since, predicate(t) { return t }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }
}
