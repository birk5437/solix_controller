import Testing
import Foundation
import CryptoKit
@testable import AnkerCore

/// Plays the battery's side of the SolixBLE negotiation with its own key pair. Passing proves the session logic is
/// self-consistent and follows the documented sequence; it does NOT prove the real battery behaves identically.
final class MockBattery {
    let priv = P256.KeyAgreement.PrivateKey()
    var secret: Data?
    var sawTimezone: String?
    var received: [UInt16] = []

    func packet(cmd: UInt16, channel: UInt8, fields: [HexField], encrypt: Bool = false) -> Data {
        var payload = BLETLV.encode(fields)
        if encrypt, let s = secret { payload = try! AnkerCrypto.aesCBC(payload, key: s.prefix(16), iv: s.suffix(16), encrypt: true) }
        return BLEPacket(pattern: [0x03, 0x01, channel], cmd: cmd, payload: payload).encode()
    }

    func respond(to data: Data) -> [Data] {
        let p = BLEPacket.parse(data)!
        received.append(p.cmd)
        var payload = p.payload
        if let s = secret { payload = try! AnkerCrypto.aesCBC(payload, key: s.prefix(16), iv: s.suffix(16), encrypt: false) }
        let fields = BLETLV.parse(payload).fields
        func n(_ c: UInt16, _ f: [HexField] = []) -> [Data] { [packet(cmd: c, channel: 0x01, fields: f)] }
        switch p.cmd {
        case 0x0001: return n(0x0801, [.raw(0xa1, [1, 2, 3, 4])])
        case 0x0003: return n(0x0803, [.raw(0xa1, [1, 2, 3, 4]), .raw(0xa2, [0xfd, 0x00])])
        case 0x0029: return n(0x0829, [.raw(0xa1, [1, 2, 3, 4])])
        case 0x0005: return n(0x0805, [.raw(0xa1, [1, 2, 3, 4])])
        case 0x0021:
            let clientXY = fields.first { $0.name == 0xa1 }!.valueLegacy
            let clientPub = try! P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + clientXY)
            secret = try! priv.sharedSecretFromKeyAgreement(with: clientPub).withUnsafeBytes { Data($0) }
            let xy = priv.publicKey.x963Representation.dropFirst()
            return n(0x0821, [HexField(name: 0xa1, type: nil, value: Data(xy))])
        case 0x4022:
            sawTimezone = fields.first { $0.name == 0xa5 }.map { String(decoding: $0.valueLegacy, as: UTF8.self) }
            return []
        default: return []
        }
    }
}

@Suite("BLE session")
struct BLESessionTests {
    func handshake(_ s: BLESession, _ b: MockBattery) -> [BLESession.Event] {
        var queue = s.start(); var events: [BLESession.Event] = []
        var guardCount = 0
        while !queue.isEmpty, guardCount < 20 {
            guardCount += 1
            let pkt = queue.removeFirst()
            for reply in b.respond(to: pkt) {
                let out = s.handle(notification: reply)
                queue += out.writes; events += out.events
            }
        }
        return events
    }

    static func c1000Fields() -> [HexField] {
        var a5 = [UInt8](repeating: 0, count: 5); a5[0] = 25; a5[2] = 73; a5[3] = 99
        var a6 = [UInt8](repeating: 0, count: 5); a6[0] = 0x2c; a6[1] = 0x01; a6[2] = 0x96; a6[3] = 0x00
        var a7 = [UInt8](repeating: 0, count: 5); a7[0] = 1; a7[1] = 0x90; a7[2] = 0x01
        var d9 = [UInt8](repeating: 0, count: 6); d9[3] = 100; d9[4] = 10
        return [HexField(name: 0xa5, type: 4, value: Data(a5)), HexField(name: 0xa6, type: 4, value: Data(a6)),
                HexField(name: 0xa7, type: 4, value: Data(a7)), HexField(name: 0xd9, type: 4, value: Data(d9))]
    }

    @Test func clientPublicKeyConstantMatchesPrivateKey() throws {
        let priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: AnkerCrypto.data(hex: BLESession.clientPrivateKeyHex)!)
        #expect(Data(priv.publicKey.x963Representation.dropFirst()) == BLESession.clientPublicKeyXY)
        #expect(BLESession.clientPublicKeyXY.count == 64)
    }

    @Test func fullNegotiationDerivesSameSecretAndSendsTimezone() {
        let s = BLESession(partNumber: "A1763", posixTimeZone: "EST5EDT,M3.2.0,M11.1.0")
        let b = MockBattery()
        let events = handshake(s, b)
        #expect(events.contains(.negotiated) && s.negotiated)
        #expect(s.deviceMTU == 253)
        #expect(b.received == [0x0001, 0x0003, 0x0029, 0x0005, 0x0021, 0x4022], "exact stage order")
        #expect(b.sawTimezone == "EST5EDT,M3.2.0,M11.1.0", "stage 5 reply is encrypted with the shared secret and carries the zone")
    }

    @Test func subscribeCommandIsEncryptedAndWellFormed() throws {
        let s = BLESession(partNumber: "A1763", clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        #expect(s.subscribeCommand() == nil, "no commands before the key exists")
        let b = MockBattery(); _ = handshake(s, b)
        let cmd = try #require(s.subscribeCommand())
        let pkt = try #require(BLEPacket.parse(cmd))
        #expect(pkt.cmd == 0x4100 && pkt.pattern == [3, 0, 0x0f] && pkt.encrypted)
        let plain = try AnkerCrypto.aesCBC(pkt.payload, key: b.secret!.prefix(16), iv: b.secret!.suffix(16), encrypt: false)
        let f = BLETLV.parse(plain).fields
        #expect(f.first { $0.name == 0xa1 }?.value == Data([0x21]))
        #expect(f.first { $0.name == 0xfe }?.valueLegacy == Data([3, 0x00, 0xf1, 0x53, 0x65]))
    }

    @Test func decodesEncryptedC1000Telemetry() throws {
        let s = BLESession(partNumber: "A1763"); let b = MockBattery(); _ = handshake(s, b)
        let frame = b.packet(cmd: 0x4421, channel: 0x0f, fields: Self.c1000Fields(), encrypt: true)
        let out = s.handle(notification: frame)
        guard case .telemetry(let t)? = out.events.first else { Issue.record("no telemetry: \(out.events)"); return }
        #expect(t.socPercent == 73 && t.temperatureC == 25)
        #expect(t.outputPowerW == 300 && t.acInputW == 150)
        #expect(t.acOutputW == 400)
        #expect(t.maxSOC == 100 && t.minSOC == 10)
    }

    @Test func reassemblesFragmentedTelemetry() throws {
        let s = BLESession(partNumber: "A1763"); let b = MockBattery(); _ = handshake(s, b)
        let plain = BLETLV.encode(Self.c1000Fields())
        let enc = try AnkerCrypto.aesCBC(plain, key: b.secret!.prefix(16), iv: b.secret!.suffix(16), encrypt: true)
        let mid = enc.count / 2
        func frag(_ i: Int, _ data: Data) -> Data {
            BLEPacket(pattern: [3, 1, 0x0f], cmd: 0xC421, payload: Data([UInt8(i << 4 | 2)]) + data).encode()
        }
        #expect(s.handle(notification: frag(1, enc.prefix(mid))).events.isEmpty)
        let out = s.handle(notification: frag(2, enc.suffix(from: mid)))
        guard case .telemetry(let t)? = out.events.first else { Issue.record("no telemetry"); return }
        #expect(t.socPercent == 73)
    }

    @Test func decodesF3800FlatTelemetry() {
        let s = BLESession(partNumber: "A1790P"); let b = MockBattery(); _ = handshake(s, b)
        let fields = [HexField(name: 0xad, type: 1, value: Data([88])), HexField(name: 0xa6, type: 2, value: Data([0xc8, 0x00])),
                      HexField(name: 0xae, type: 3, value: Data([0x2c, 0x01, 0, 0])), HexField(name: 0xbe, type: 1, value: Data([0xfb]))]
        let out = s.handle(notification: b.packet(cmd: 0x4405, channel: 0x0f, fields: fields, encrypt: true))
        guard case .telemetry(let t)? = out.events.first else { Issue.record("no telemetry"); return }
        #expect(t.socPercent == 88 && t.acOutputW == 200 && t.dcInputW == 300 && t.temperatureC == -5)
    }

    @Test func rejectsGarbageAndUnknownFrames() {
        let s = BLESession(partNumber: "A1763"); let b = MockBattery()
        #expect(s.handle(notification: Data([1, 2, 3])).events == [.ignored("malformed packet")])
        // Encrypted frame before a key exists must not be treated as telemetry.
        let early = BLEPacket(pattern: [3, 1, 0x0f], cmd: 0x4421, payload: Data(repeating: 7, count: 32)).encode()
        #expect(s.handle(notification: early).events.allSatisfy { if case .telemetry = $0 { false } else { true } })
        _ = handshake(s, b)
        let unknown = b.packet(cmd: 0x4123, channel: 0x0f, fields: [.raw(0xa1, [1])], encrypt: true)
        #expect(s.handle(notification: unknown).events == [.ignored("message 4123")])
        var bad = b.packet(cmd: 0x4421, channel: 0x0f, fields: Self.c1000Fields(), encrypt: true)
        bad[bad.count - 1] ^= 0xff
        #expect(s.handle(notification: bad).events == [.ignored("malformed packet")])
    }

    @Test func onlyDocumentedModelsGetASession() {
        #expect(BLESession.supports(partNumber: "A1763") && BLESession.supports(partNumber: "A1790P"))
        #expect(!BLESession.supports(partNumber: "A1783"), "C2000 Gen 2 has no documented BLE telemetry layout")
    }

    @Test func posixTimeZoneLooksLikeAPosixString() {
        let tz = BLESession.currentPOSIXTimeZone()
        #expect(!tz.isEmpty && tz.count < 80)
    }
}
