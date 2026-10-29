import Foundation
import CryptoKit

// Encrypted BLE session for the Anker "ff09" GATT transport. Ported from flip-dots/SolixBLE (MIT):
// device.py (negotiation), constructs.py (packet / TLV), const.py (UUIDs, fixed client key), devices/c1000g2.py,
// devices/f3800.py (subscribe command, telemetry command codes).
//
// This is a pure state machine: it consumes notification bytes and returns bytes to write plus decoded telemetry.
// CoreBluetooth I/O lives in `BluetoothService`.

public enum BLEUUID {
    public static let service = "0000FF09-0000-1000-8000-00805F9B34FB"
    public static let command = "8C850002-0302-41C5-B46E-CF057C562025"
    public static let telemetry = "8C850003-0302-41C5-B46E-CF057C562025"
}

struct BLEPacket {
    var pattern: [UInt8]   // 3 bytes: family, composer, channel
    var cmd: UInt16
    var payload: Data

    var channel: UInt8 { pattern[2] }
    var fragmented: Bool { cmd & 0x8000 != 0 }
    var encrypted: Bool { cmd & 0x4000 != 0 }
    var msgType: UInt16 { cmd & 0x0FFF }

    /// ff09 | length LE16 (whole packet) | pattern(3) | cmd(2) BE | payload | xor checksum
    static func parse(_ data: Data) -> BLEPacket? {
        let b = [UInt8](data)
        guard b.count >= 10, b[0] == 0xff, b[1] == 0x09, Int(b[2]) | Int(b[3]) << 8 == b.count, b.reduce(0, ^) == 0 else { return nil }
        return BLEPacket(pattern: Array(b[4..<7]), cmd: UInt16(b[7]) << 8 | UInt16(b[8]), payload: Data(b[9..<(b.count - 1)]))
    }

    func encode() -> Data {
        let total = 10 + payload.count
        var d = Data([0xff, 0x09, UInt8(total & 0xff), UInt8(total >> 8)])
        d.append(contentsOf: pattern)
        d.append(contentsOf: [UInt8(cmd >> 8), UInt8(cmd & 0xff)])
        d.append(payload)
        d.append(d.reduce(0, ^))
        return d
    }
}

enum BLETLV {
    /// TLV rule from SolixBLE `Parameter`: length > 1 ⇒ first byte is a type; a first byte < 0xa1 on a reply is a status.
    static func parse(_ data: Data) -> (prefix: UInt8?, fields: [HexField]) {
        let b = [UInt8](data)
        var pos = 0; var prefix: UInt8?
        if let f = b.first, f < 0xa1 { prefix = f; pos = 1 }
        var out: [HexField] = []
        while pos + 2 <= b.count {
            let key = b[pos], len = Int(b[pos + 1])
            guard pos + 2 + len <= b.count else { break }
            if len > 1 { out.append(HexField(name: key, type: b[pos + 2], value: Data(b[(pos + 3)..<(pos + 2 + len)]))) }
            else { out.append(HexField(name: key, type: nil, value: Data(b[(pos + 2)..<(pos + 2 + len)]))) }
            pos += 2 + len
        }
        return (prefix, out)
    }

    /// Fields are encoded in the given order; `type == nil` ⇒ no type byte.
    static func encode(_ fields: [HexField]) -> Data {
        var d = Data()
        for f in fields {
            let body = (f.type.map { [$0] } ?? []) + [UInt8](f.value)
            d.append(f.name); d.append(UInt8(body.count)); d.append(contentsOf: body)
        }
        return d
    }
}

public final class BLESession {
    public enum Event: Equatable {
        case negotiated
        case telemetry(BatteryTelemetry)
        case ignored(String)
    }
    public struct Output {
        public var writes: [Data] = []
        public var events: [Event] = []
    }

    // SolixBLE const.py
    static let uuidString = "b2dc0b17-b75d-4abf-ba6e-ec7c997c23e7"
    static let clientPrivateKeyHex = "7dfbea61cd95cee49c458ad7419e817f1ade9a66136de3c7d5787af1458e39f4"
    /// X‖Y of the public key matching `clientPrivateKeyHex`, sent in negotiation stage 4 (verified by a unit test).
    static let clientPublicKeyXY = AnkerCrypto.data(hex: "060ea168f232aedb37fb2d120c49180329ac72ab5ec3eb8fd30a2f252dc5e151dabccd9b1dc1e288704ca760a0d8c918e5c94823a1f609a4bf07fb4c33ee2190")!

    static let negotiationPattern: [UInt8] = [0x03, 0x00, 0x01]
    static let sessionPattern: [UInt8] = [0x03, 0x00, 0x0f]
    static let channelNegotiation: UInt8 = 0x01
    static let channelSession: UInt8 = 0x0f
    static let channelApp: UInt8 = 0x11

    public let partNumber: String
    public private(set) var negotiated = false
    public private(set) var deviceMTU: Int?
    private var secret: Data?
    private var fragments: [Data: [Data]] = [:]
    private let clock: () -> Date
    private let posixTZ: String

    public init(partNumber: String, posixTimeZone: String = BLESession.currentPOSIXTimeZone(), clock: @escaping () -> Date = { Date() }) {
        self.partNumber = partNumber; self.posixTZ = posixTimeZone; self.clock = clock
    }

    /// Models whose BLE telemetry layout is documented by SolixBLE (A1763 confirmed on hardware there, F3800 "not tested").
    public static func supports(partNumber: String) -> Bool { ["A1763", "A1765", "A1790P", "A1790"].contains(partNumber) }

    /// Message types carrying telemetry (SolixBLE `_TELEMETRY_COMMANDS` plus the generic 0x300).
    var telemetryMsgTypes: Set<UInt16> {
        switch partNumber {
        case "A1763", "A1765": [0x421, 0x900, 0x300]
        default: [0x840, 0x402, 0x300, 0x405]
        }
    }

    /// Canonical message type used to reuse the MQTT telemetry layouts (they are identical for these models).
    var canonicalType: UInt16 { ["A1763", "A1765"].contains(partNumber) ? 0x0421 : 0x0405 }

    // MARK: Start / commands

    public func start() -> [Data] {
        negotiated = false; secret = nil; fragments = [:]
        return [negotiationPacket(cmd: 0x0001, [ts(0xa1), .raw(0xa2, uuidBytes)])]
    }

    /// Subscribe command that makes the device stream telemetry (c1000g2 / f3800: cmd 4100, a1 = 0x21).
    public func subscribeCommand() -> Data? {
        guard negotiated else { return nil }
        return sessionPacket(cmd: 0x4100, [.raw(0xa1, [0x21])])
    }

    private func sessionPacket(cmd: UInt16, _ fields: [HexField]) -> Data? {
        guard let secret else { return nil }
        let plain = BLETLV.encode(fields + [.var32(0xfe, UInt32(clock().timeIntervalSince1970))])
        guard let enc = try? AnkerCrypto.aesCBC(plain, key: secret.prefix(16), iv: secret.suffix(16), encrypt: true) else { return nil }
        return BLEPacket(pattern: Self.sessionPattern, cmd: cmd, payload: enc).encode()
    }

    // MARK: Helpers

    private var uuidBytes: [UInt8] { [UInt8](Self.uuidString.utf8) }
    private func ts(_ key: UInt8) -> HexField {
        let t = UInt32(clock().timeIntervalSince1970)
        return .raw(key, [UInt8(t & 0xff), UInt8((t >> 8) & 0xff), UInt8((t >> 16) & 0xff), UInt8(t >> 24)])
    }

    /// Negotiation packets are plaintext until the secret exists; the stage-5 reply (cmd 4022) is already encrypted.
    private func negotiationPacket(cmd: UInt16, _ fields: [HexField]) -> Data {
        var payload = BLETLV.encode(fields)
        if let secret, let enc = try? AnkerCrypto.aesCBC(payload, key: secret.prefix(16), iv: secret.suffix(16), encrypt: true) { payload = enc }
        return BLEPacket(pattern: Self.negotiationPattern, cmd: cmd, payload: payload).encode()
    }

    private func decrypt(_ d: Data) -> Data? {
        guard let secret else { return d }
        return try? AnkerCrypto.aesCBC(d, key: secret.prefix(16), iv: secret.suffix(16), encrypt: false)
    }

    // MARK: Inbound

    public func handle(notification data: Data) -> Output {
        var out = Output()
        guard let p = BLEPacket.parse(data) else { out.events.append(.ignored("malformed packet")); return out }
        var payload = p.payload
        if p.fragmented {
            guard let whole = reassemble(p) else { return out }
            payload = whole
        }
        switch p.channel {
        case Self.channelNegotiation:
            guard let plain = decrypt(payload) else { out.events.append(.ignored("negotiation payload failed to decrypt")); return out }
            negotiate(cmd: p.cmd, plain: plain, into: &out)
        case Self.channelSession, Self.channelApp:
            if p.encrypted {
                guard secret != nil, let plain = decrypt(payload) else { out.events.append(.ignored("encrypted frame before key exchange or bad padding")); return out }
                payload = plain
            }
            guard telemetryMsgTypes.contains(p.msgType) else {
                out.events.append(.ignored(String(format: "message %04x", p.cmd))); return out
            }
            let fields = BLETLV.parse(payload).fields
            let msg = HexMessage(msgType: canonicalType, isResponse: true, fields: fields)
            if let t = TelemetryDecoder.telemetry(partNumber: partNumber, message: msg) { out.events.append(.telemetry(t)) }
            else { out.events.append(.ignored("telemetry frame without recognised fields")) }
        default:
            out.events.append(.ignored(String(format: "channel %02x", p.channel)))
        }
        return out
    }

    private func reassemble(_ p: BLEPacket) -> Data? {
        guard let first = p.payload.first else { return nil }
        let index = Int(first >> 4), total = Int(first & 0x0f)
        let key = Data(p.pattern + [UInt8(p.cmd >> 8), UInt8(p.cmd & 0xff)])
        var list = fragments[key] ?? []
        list.append(p.payload.dropFirst())
        guard index == list.count else { fragments[key] = []; return nil }     // out of order → restart
        guard total == list.count else { fragments[key] = list; return nil }
        fragments[key] = []
        return list.reduce(Data(), +)
    }

    private func negotiate(cmd: UInt16, plain: Data, into out: inout Output) {
        let f = Dictionary(BLETLV.parse(plain).fields.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        func send(_ c: UInt16, _ fields: [HexField]) { out.writes.append(negotiationPacket(cmd: c, fields)) }
        switch cmd {
        case 0x0801:
            send(0x0003, [ts(0xa1), .raw(0xa2, uuidBytes), .raw(0xa3, [0x20]), .raw(0xa4, [0x00, 0xf0])])
        case 0x0803:
            if let a2 = f[0xa2] { deviceMTU = [UInt8](a2.valueLegacy).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
            send(0x0029, [ts(0xa1), .raw(0xa2, uuidBytes)])
        case 0x0829:
            send(0x0005, [ts(0xa1), .raw(0xa2, uuidBytes), .raw(0xa3, [0x20]), .raw(0xa4, [0x00, 0xf0]), .raw(0xa5, [0x40])])
        case 0x0805:
            send(0x0021, [HexField(name: 0xa1, type: nil, value: Self.clientPublicKeyXY)])
        case 0x0821:
            guard let a1 = f[0xa1], a1.valueLegacy.count == 64,
                  let devKey = try? P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + a1.valueLegacy),
                  let privData = AnkerCrypto.data(hex: Self.clientPrivateKeyHex),
                  let priv = try? P256.KeyAgreement.PrivateKey(rawRepresentation: privData),
                  let shared = try? priv.sharedSecretFromKeyAgreement(with: devKey) else {
                out.events.append(.ignored("stage 5: invalid device public key")); return
            }
            secret = shared.withUnsafeBytes { Data($0) }
            send(0x4022, [ts(0xa1), .raw(0xa2, uuidBytes), .raw(0xa3, [0x20]), .raw(0xa4, [0, 0, 0, 0]), .raw(0xa5, [UInt8](posixTZ.utf8))])
            negotiated = true
            out.events.append(.negotiated)
        case 0x4822:
            break   // optional trailing message on some models; no reply needed
        default:
            out.events.append(.ignored(String(format: "unexpected negotiation message %04x", cmd)))
        }
    }

    // MARK: Time zone

    /// POSIX TZ string (e.g. "EST5EDT,M3.2.0,M11.1.0") from the TZif footer of the system zone file.
    public static func currentPOSIXTimeZone() -> String {
        let id = TimeZone.current.identifier
        for base in ["/var/db/timezone/zoneinfo/", "/usr/share/zoneinfo/"] {
            if let d = FileManager.default.contents(atPath: base + id) {
                let lines = String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
                if let last = lines.last, last.count < 80, !last.contains("\u{0}"), last.first?.isLetter == true { return String(last) }
            }
        }
        return "UTC0"
    }
}
