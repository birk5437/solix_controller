import Foundation

// Wire format ported from thomluther/anker-solix-api (MIT), mqtttypes.py / mqtt.py:
//   ff 09 | total length (LE16, incl. checksum) | 03 00 0f (send) / 03 01 0f (receive) | msg type (2) |
//   [status byte, responses only] | fields... | XOR checksum over all preceding bytes
// Field: name(1) | length(1) | [type(1)] | value   — 'length' counts type + value bytes.
// Large str/bin fields use name | length(LE16) | type | value.

public enum HexFieldType: UInt8, Sendable {
    case str = 0x00, ui = 0x01, sile = 0x02, v32 = 0x03, bin = 0x04, sfle = 0x05, strb = 0x06
}

public struct HexField: Hashable, Sendable {
    public var name: UInt8
    public var type: UInt8?
    public var value: Data

    public init(name: UInt8, type: UInt8?, value: Data) { self.name = name; self.type = type; self.value = value }

    public var nameHex: String { String(format: "%02x", name) }
    /// Type byte (if any) followed by the value — the representation SolixBLE calls `value_legacy`.
    public var valueLegacy: Data { (type.map { Data([$0]) } ?? Data()) + value }

    func encoded() -> Data {
        var d = Data([name])
        let body = (type.map { [$0] } ?? []) + [UInt8](value)
        if body.count > 255 {
            d.append(UInt8(body.count & 0xff)); d.append(UInt8(body.count >> 8))
        } else {
            d.append(UInt8(body.count))
        }
        d.append(contentsOf: body)
        return d
    }

    // Convenience builders
    static func raw(_ name: UInt8, _ bytes: [UInt8]) -> HexField { .init(name: name, type: nil, value: Data(bytes)) }
    static func ui(_ name: UInt8, _ v: UInt8) -> HexField { .init(name: name, type: HexFieldType.ui.rawValue, value: Data([v])) }
    static func var32(_ name: UInt8, _ v: UInt32) -> HexField {
        .init(name: name, type: HexFieldType.v32.rawValue,
              value: Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]))
    }
    static func str(_ name: UInt8, _ s: String) -> HexField { .init(name: name, type: HexFieldType.str.rawValue, value: Data(s.utf8)) }
}

public struct HexMessage: Sendable {
    public var msgType: UInt16
    public var isResponse: Bool
    public var encrypted: Bool
    public var status: UInt8?
    public var fields: [HexField]

    public init(msgType: UInt16, isResponse: Bool = false, encrypted: Bool = false, status: UInt8? = nil, fields: [HexField]) {
        self.msgType = msgType; self.isResponse = isResponse; self.encrypted = encrypted
        self.status = status; self.fields = fields
    }

    public var msgTypeHex: String { String(format: "%04x", msgType) }
    public func field(_ name: UInt8) -> HexField? { fields.first { $0.name == name } }

    public static func xorChecksum(_ bytes: [UInt8]) -> UInt8 { bytes.reduce(0, ^) }

    /// Build a *command* frame. Fields are sorted by name, as the reference implementation does.
    public func encode() -> Data {
        var body = Data()
        for f in fields.sorted(by: { $0.name < $1.name }) { body.append(f.encoded()) }
        let total = 9 + body.count + 1
        var d = Data([0xff, 0x09, UInt8(total & 0xff), UInt8(total >> 8), 0x03, 0x00, 0x0f,
                      UInt8(msgType >> 8), UInt8(msgType & 0xff)])
        d.append(body)
        d.append(Self.xorChecksum([UInt8](d)))
        return d
    }

    public enum ParseError: Error, Equatable { case tooShort, badPrefix, badLength, badChecksum, truncatedField }

    /// Parse a received frame. Encrypted (0x40 flag) frames are returned with `encrypted = true` and no fields.
    public static func parse(_ data: Data, verifyChecksum: Bool = true) throws -> HexMessage {
        let b = [UInt8](data)
        guard b.count >= 10 else { throw ParseError.tooShort }
        guard b[0] == 0xff, b[1] == 0x09 else { throw ParseError.badPrefix }
        let declared = Int(b[2]) | Int(b[3]) << 8
        guard declared == b.count else { throw ParseError.badLength }
        if verifyChecksum, xorChecksum(b) != 0 { throw ParseError.badChecksum }
        let type = UInt16(b[7]) << 8 | UInt16(b[8])
        let encrypted = (b[7] & 0x40) != 0
        let response = b[5] == 0x01
        var pos = 9
        var status: UInt8?
        // A status byte precedes the fields in responses unless the next byte is already a field name (a0...a9 range start).
        if pos < b.count - 1, !(0xa0...0xff).contains(b[pos]) { status = b[pos]; pos += 1 }
        if encrypted { return HexMessage(msgType: type, isResponse: response, encrypted: true, status: status, fields: []) }
        let end = b.count - 1  // exclude checksum
        var fields: [HexField] = []
        while pos < end {
            let name = b[pos]
            guard pos + 1 < end else { throw ParseError.truncatedField }
            let l1 = Int(b[pos + 1])
            // Prefer the 1-byte-length reading when it lands on a plausible field boundary.
            func boundaryOK(_ next: Int) -> Bool {
                next == end || (next < end && b[next] > name && b[next] >= 0xa0)
            }
            if pos + 2 + l1 <= end, boundaryOK(pos + 2 + l1) {
                if l1 >= 2, b[pos + 2] < 0x10 {
                    fields.append(HexField(name: name, type: b[pos + 2], value: Data(b[(pos + 3)..<(pos + 2 + l1)])))
                } else {
                    fields.append(HexField(name: name, type: nil, value: Data(b[(pos + 2)..<(pos + 2 + l1)])))
                }
                pos += 2 + l1
            } else if pos + 3 < end {
                let l2 = l1 | Int(b[pos + 2]) << 8
                guard l2 >= 1, pos + 3 + l2 <= end, boundaryOK(pos + 3 + l2) else { throw ParseError.truncatedField }
                fields.append(HexField(name: name, type: b[pos + 3], value: Data(b[(pos + 4)..<(pos + 3 + l2)])))
                pos += 3 + l2
            } else { throw ParseError.truncatedField }
        }
        return HexMessage(msgType: type, isResponse: response, encrypted: false, status: status, fields: fields)
    }
}

// MARK: - Commands (only those described in the reference maps for the supported models)

public enum SOLIXCommand {
    /// Ask the device to publish real-time telemetry for `timeout` seconds (msg 0057, all PPS models).
    public static func realtimeTrigger(timeout: Int = 60, now: Date = Date()) -> HexMessage {
        HexMessage(msgType: 0x0057, fields: [
            .raw(0xa1, [0x22]),
            .ui(0xa2, 1),
            .var32(0xa3, UInt32(max(30, min(600, timeout)))),
            .var32(0xfe, UInt32(now.timeIntervalSince1970)),
        ])
    }

    /// TOU command group 0090, field a2: usage mode (A1783 maps 0=standard, 1=time_of_use).
    public static func setUsageMode(_ mode: UsageMode, now: Date = Date()) -> HexMessage {
        HexMessage(msgType: 0x0090, fields: [
            .raw(0xa1, [0x22]), .ui(0xa2, UInt8(mode.rawValue)), msTimestamp(now),
        ])
    }

    /// TOU command group 0090, field a5: backup SOC. Range per CMD_PPS_BACKUP_SOC_V2: 5...100.
    public static func setBackupSOC(_ soc: Int, now: Date = Date()) throws -> HexMessage {
        guard (5...100).contains(soc) else { throw CommandError.outOfRange("backup SOC", 5, 100) }
        return HexMessage(msgType: 0x0090, fields: [
            .raw(0xa1, [0x22]), .ui(0xa5, UInt8(soc)), msTimestamp(now),
        ])
    }

    /// AC command group 0101, field ab (2-byte LE): Battery-Only Power. 0 = off (AC input accepted), 1 = on (AC input disabled).
    /// Documented for A1783 (mqttcmdmap.CMD_BATTERY_ONLY_SWITCH_V2). Turning it on also switches off Ultrafast Charge.
    public static func setBatteryOnly(_ on: Bool, now: Date = Date()) -> HexMessage {
        HexMessage(msgType: 0x0101, fields: [
            .raw(0xa1, [0x22]),
            HexField(name: 0xab, type: HexFieldType.sile.rawValue, value: Data([on ? 1 : 0, 0])),
            msTimestamp(now),
        ])
    }

    static func msTimestamp(_ d: Date) -> HexField { .str(0xfd, String(Int(d.timeIntervalSince1970 * 1000))) }

    public enum CommandError: Error, CustomStringConvertible {
        case outOfRange(String, Int, Int)
        public var description: String {
            switch self { case .outOfRange(let n, let a, let b): "\(n) must be within \(a)–\(b)" }
        }
    }
}

// MARK: - Telemetry decoding

/// Decodes telemetry for models whose layouts are described in anker-solix-api mqttmap.py.
public enum TelemetryDecoder {
    struct Spec { let offset: Int; let kind: Kind; let signed: Bool; let factor: Double; let key: String
        init(_ o: Int, _ k: Kind, _ key: String, signed: Bool? = nil, factor: Double = 1) {
            offset = o; kind = k; self.key = key; self.factor = factor
            self.signed = signed ?? (k == .sile)
        }
    }
    enum Kind { case ui, sile, var32 }

    /// `_A1763_0421` / `_A1783_0421`: shared offsets for the fields used here.
    static let layout0421: [UInt8: [Spec]] = [
        0xa3: [Spec(0, .ui, "working_status")],
        0xa4: [Spec(4, .sile, "ac_input_limit", signed: false), Spec(0x23, .ui, "max_soc"), Spec(0x24, .ui, "min_soc")],
        0xa5: [Spec(0, .ui, "temperature", signed: true), Spec(1, .ui, "battery_status"), Spec(2, .ui, "battery_soc")],
        0xa6: [Spec(0, .sile, "output_power_total"), Spec(2, .sile, "ac_input_power_total"),
               Spec(4, .sile, "dc_input_power_total"), Spec(6, .sile, "remaining_hours", signed: false, factor: 0.1),
               Spec(8, .ui, "main_battery_soc")],
        0xa7: [Spec(0, .ui, "ac_output_switch"), Spec(1, .sile, "ac_output_power"),
               Spec(3, .ui, "ac_input_plug_status"), Spec(4, .sile, "ac_input_power")],
        0xa8: [Spec(0, .ui, "dc_input_plug_status"), Spec(1, .sile, "dc_input_power")],
    ]

    /// `_A1790_0405`: flat typed fields.
    static let flat0405: [UInt8: (key: String, signed: Bool, factor: Double)] = [
        0xa4: ("remaining_hours", false, 0.1), 0xa5: ("ac_input_power", true, 1), 0xa6: ("ac_output_power", true, 1),
        0xad: ("battery_soc", false, 1), 0xae: ("photovoltaic_power", true, 1), 0xb1: ("bat_charge_power", true, 1),
        0xb2: ("output_power_total", true, 1), 0xbe: ("temperature", true, 1), 0xcd: ("ac_input_limit", false, 1),
    ]

    static func read(_ d: Data, at o: Int, _ kind: Kind, signed: Bool) -> Double? {
        let b = [UInt8](d)
        switch kind {
        case .ui: guard o < b.count else { return nil }; return signed ? Double(Int8(bitPattern: b[o])) : Double(b[o])
        case .sile:
            guard o + 1 < b.count else { return nil }
            let v = UInt16(b[o]) | UInt16(b[o + 1]) << 8
            return signed ? Double(Int16(bitPattern: v)) : Double(v)
        case .var32:
            guard o + 3 < b.count else { return nil }
            let v = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
            return signed ? Double(Int32(bitPattern: v)) : Double(v)
        }
    }

    /// Little-endian integer of 1...4 bytes (SolixBLE `_parse_int` semantics for flat fields).
    static func littleEndian(_ d: Data, signed: Bool) -> Double? {
        let b = [UInt8](d)
        guard (1...4).contains(b.count) else { return nil }
        var v: UInt64 = 0
        for (i, x) in b.enumerated() { v |= UInt64(x) << (8 * UInt64(i)) }
        if signed, b.last.map({ $0 & 0x80 != 0 }) == true {
            return Double(Int64(bitPattern: v) - (Int64(1) << (8 * Int64(b.count))))
        }
        return Double(v)
    }

    /// Decode a message into named values (also used by the protocol capture view).
    public static func values(partNumber: String, message: HexMessage) -> [String: Double] {
        var out: [String: Double] = [:]
        switch (partNumber, message.msgType) {
        case ("A1763", 0x0421), ("A1783", 0x0421):
            for f in message.fields {
                for s in layout0421[f.name] ?? [] {
                    if let v = read(f.value, at: s.offset, s.kind, signed: s.signed) { out[s.key] = v * s.factor }
                }
            }
        case ("A1790P", 0x0405), ("A1790", 0x0405), ("A1790P", 0x0402), ("A1790", 0x0402), ("A1790P", 0x0840), ("A1790", 0x0840):
            for f in message.fields {
                guard let m = flat0405[f.name] else { continue }
                if let v = littleEndian(f.value, signed: m.signed) { out[m.key] = v * m.factor }
            }
        default: break
        }
        return out
    }

    /// Full telemetry (including the A1783 `d9` TOU block) from a message.
    public static func telemetry(partNumber: String, message: HexMessage) -> BatteryTelemetry? {
        let v = values(partNumber: partNumber, message: message)
        guard !v.isEmpty || message.field(0xd9) != nil else { return nil }
        var t = BatteryTelemetry()
        t.rawFieldCount = message.fields.count
        t.socPercent = v["battery_soc"] ?? v["main_battery_soc"]
        t.temperatureC = v["temperature"]
        t.remainingHours = v["remaining_hours"]
        t.minSOC = v["min_soc"].map(Int.init)
        t.maxSOC = v["max_soc"].map(Int.init)
        t.acInputW = v["ac_input_power_total"] ?? v["ac_input_power"]
        t.dcInputW = v["dc_input_power_total"] ?? v["dc_input_power"] ?? v["photovoltaic_power"]
        t.acOutputW = v["ac_output_power"]
        t.outputPowerW = v["output_power_total"]
        t.acPlugStatus = v["ac_input_plug_status"].map(Int.init)
        if t.acInputW != nil || t.dcInputW != nil { t.inputPowerW = (t.acInputW ?? 0) + (t.dcInputW ?? 0) }
        if let c = v["bat_charge_power"], t.inputPowerW == nil { t.inputPowerW = c }

        if partNumber == "A1783", let a4 = message.field(0xa4), a4.value.count > 0x31 {
            // a4[0x31] bits 0x0C = battery_only_switch (mqttmap.py): non-zero ⇒ AC input disabled; TOU does not run.
            t.batteryOnlySwitch = (a4.value[a4.value.startIndex + 0x31] & 0x0C) != 0 ? 1 : 0
        }
        if partNumber == "A1763", let d9 = message.field(0xd9), d9.value.count >= 5 {
            // SolixBLE c1000g2: d9[4:5] = max SOC, d9[5:6] = min SOC (type byte counted) → value offsets 3 and 4.
            let b = [UInt8](d9.value)
            t.maxSOC = Int(b[3]); t.minSOC = Int(b[4])
        }
        if partNumber == "A1783", let d9 = message.field(0xd9), d9.value.count >= 6 {
            let b = [UInt8](d9.value)
            t.activeTariff = Int(b[0]); t.usageMode = Int(b[1]); t.backupSOC = Int(b[2])
            t.touSchedule = TOUPlan.slots(fromMQTTSchedule: Data(b[5...]))
        }
        return t
    }
}
