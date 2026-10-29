import Testing
import Foundation
@testable import AnkerCore

@Suite("Wire protocol")
struct ProtocolTests {
    /// Reference vector from anker-solix-api mqtt.py generate_mqtt_command docstring:
    /// timeout 300 s, timestamp 1756813256 → 31 byte frame.
    @Test func realtimeTriggerMatchesReferenceLayout() {
        let frame = SOLIXCommand.realtimeTrigger(timeout: 300, now: Date(timeIntervalSince1970: 1756813256)).encode()
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        #expect(frame.count == 31)
        #expect(hex.hasPrefix("ff091f0003000f0057a10122a2020101a305032c010000fe0503c8d7b668"))
        #expect(HexMessage.xorChecksum([UInt8](frame)) == 0)
    }

    @Test func usageModeCommandIsWellFormed() throws {
        let m = SOLIXCommand.setUsageMode(.timeOfUse, now: Date(timeIntervalSince1970: 1_700_000_000))
        let parsed = try HexMessage.parse(m.encode())
        #expect(parsed.msgType == 0x0090)
        #expect(parsed.field(0xa2)?.value == Data([1]))
        #expect(String(decoding: parsed.field(0xfd)!.value, as: UTF8.self) == "1700000000000")
    }

    @Test func backupSOCRangeIsEnforced() throws {
        #expect(throws: SOLIXCommand.CommandError.self) { _ = try SOLIXCommand.setBackupSOC(4) }
        #expect(throws: SOLIXCommand.CommandError.self) { _ = try SOLIXCommand.setBackupSOC(101) }
        let ok = try SOLIXCommand.setBackupSOC(25)
        #expect(try HexMessage.parse(ok.encode()).field(0xa5)?.value == Data([25]))
    }

    @Test func rejectsBadChecksumAndLength() {
        var f = SOLIXCommand.realtimeTrigger().encode()
        f[f.count - 1] ^= 0xff
        #expect(throws: HexMessage.ParseError.badChecksum) { _ = try HexMessage.parse(f) }
        #expect(throws: HexMessage.ParseError.badLength) { _ = try HexMessage.parse(f.dropLast()) }
        #expect(throws: HexMessage.ParseError.badPrefix) { _ = try HexMessage.parse(Data(repeating: 0, count: 12)) }
    }

    /// Synthetic (not recorded) C2000 Gen 2 0421 frame built per mqttmap.py offsets.
    static func a1783Frame(mode: UInt8, soc: UInt8 = 64, schedule: [UInt8] = [3, 3, 0, 8, 1, 8, 17, 3, 17, 24]) -> Data {
        var d5 = [UInt8](repeating: 0, count: 3); d5[0] = 21; d5[1] = 1; d5[2] = soc
        var a6 = [UInt8](repeating: 0, count: 9)
        a6[0] = 0x2c; a6[1] = 0x01   // out 300 W
        a6[2] = 0x00; a6[3] = 0x00   // ac in 0
        a6[4] = 0x64; a6[5] = 0x00   // dc in 100 W
        a6[6] = 0x32; a6[7] = 0x00   // 5.0 h
        a6[8] = soc
        var a4 = [UInt8](repeating: 0, count: 0x25); a4[0x23] = 100; a4[0x24] = 10
        var a7 = [UInt8](repeating: 0, count: 6); a7[3] = 1
        let d9: [UInt8] = [3, mode, 12, 100, 10] + schedule
        let msg = HexMessage(msgType: 0x0421, isResponse: true, fields: [
            HexField(name: 0xa4, type: 0x04, value: Data(a4)),
            HexField(name: 0xa5, type: 0x04, value: Data(d5)),
            HexField(name: 0xa6, type: 0x04, value: Data(a6)),
            HexField(name: 0xa7, type: 0x04, value: Data(a7)),
            HexField(name: 0xd9, type: 0x04, value: Data(d9)),
        ])
        var bytes = [UInt8](msg.encode())
        bytes[5] = 0x01 // response direction
        bytes[bytes.count - 1] = 0
        bytes[bytes.count - 1] = HexMessage.xorChecksum(bytes)
        return Data(bytes)
    }

    @Test func decodesC2000Telemetry() throws {
        let msg = try HexMessage.parse(Self.a1783Frame(mode: 1))
        let t = try #require(TelemetryDecoder.telemetry(partNumber: "A1783", message: msg))
        #expect(t.socPercent == 64)
        #expect(t.outputPowerW == 300)
        #expect(t.dcInputW == 100)
        #expect(t.inputPowerW == 100)
        #expect(t.remainingHours == 5.0)
        #expect(t.temperatureC == 21)
        #expect(t.minSOC == 10 && t.maxSOC == 100)
        #expect(t.usageMode == 1)
        #expect(t.backupSOC == 12)
        #expect(t.acPlugStatus == 1)
        #expect(t.touSchedule == [TOUSlot(startHour: 0, endHour: 8, tariff: .offPeak),
                                  TOUSlot(startHour: 8, endHour: 17, tariff: .peak),
                                  TOUSlot(startHour: 17, endHour: 24, tariff: .offPeak)])
    }

    @Test func decodesF3800FlatFields() throws {
        let msg = HexMessage(msgType: 0x0405, isResponse: true, fields: [
            HexField(name: 0xa5, type: 0x02, value: Data([0x00, 0x00])),
            HexField(name: 0xa6, type: 0x02, value: Data([0xc8, 0x00])),
            HexField(name: 0xad, type: 0x01, value: Data([87])),
            HexField(name: 0xae, type: 0x02, value: Data([0x2c, 0x01])),
            HexField(name: 0xbe, type: 0x01, value: Data([0xf6])),   // -10 °C signed
        ])
        let parsed = try HexMessage.parse(msg.encode())
        let t = try #require(TelemetryDecoder.telemetry(partNumber: "A1790P", message: parsed))
        #expect(t.socPercent == 87)
        #expect(t.acOutputW == 200)
        #expect(t.dcInputW == 300)
        #expect(t.temperatureC == -10)
    }

    @Test func mqttCodecRoundTrip() {
        #expect(MQTTCodec.remainingLength(0) == [0])
        #expect(MQTTCodec.remainingLength(127) == [127])
        #expect(MQTTCodec.remainingLength(128) == [0x80, 0x01])
        #expect(MQTTCodec.remainingLength(16384) == [0x80, 0x80, 0x01])
        let pub = MQTTCodec.publish(topic: "dt/a/b/c/x", payload: Data("hello".utf8))
        var buf = pub + MQTTCodec.pingReq
        buf.append(pub.prefix(5))   // partial trailing packet stays buffered
        let pk = MQTTCodec.drain(&buf)
        #expect(pk.count == 2)
        #expect(pk[0] == .publish(topic: "dt/a/b/c/x", payload: Data("hello".utf8), qos: 0, packetID: nil))
        #expect(buf.count == 5)
        var ack = Data([0x20, 0x02, 0x00, 0x05])
        #expect(MQTTCodec.drain(&ack) == [.connack(returnCode: 5)])
    }

    @Test func envelopeRoundTrip() throws {
        let info = MQTTInfo(userID: "u1", appName: "anker_power", thingName: "t", certificateID: "c9",
                            certificatePEM: "", privateKeyPEM: "", endpoint: "h")
        let frame = SOLIXCommand.setUsageMode(.standard).encode()
        let payload = try AnkerEnvelope.command(info: info, pn: "A1783", sn: "SN1234567890", frame: frame)
        let obj = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let head = try #require(obj["head"] as? [String: Any])
        #expect(head["client_id"] as? String == "android-anker_power-u1-c9")
        #expect(head["device_pn"] as? String == "A1783")
        #expect(AnkerEnvelope.commandTopic(info: info, pn: "A1783", sn: "S") == "cmd/anker_power/A1783/S/req")
        let inbound = AnkerEnvelope.decode(topic: "dt/anker_power/A1783/SN1234567890/param_info", payload: payload)
        #expect(inbound?.frame == frame)
        #expect(inbound?.serial == "SN1234567890")
    }
}

@Suite("Capabilities & identification")
struct CapabilityTests {
    @Test func capabilitiesComeFromVerifiedRegistry() {
        let c2000 = ModelRegistry.profile(for: "A1783")!
        #expect(c2000.capabilities.supportsTOU && c2000.capabilities.supportsTOUScheduling && c2000.capabilities.supportsReserveSOC)
        #expect(c2000.settableUsageModes == [.standard, .timeOfUse])
        for pn in ["A1763", "A1790P"] {
            let p = ModelRegistry.profile(for: pn)!
            #expect(!p.capabilities.supportsTOU, "\(pn) has no documented TOU command")
            #expect(p.settableUsageModes.isEmpty)
        }
        #expect(ModelRegistry.profile(for: "A9999") == nil)
        #expect(SOLIXDevice(serial: "x", partNumber: "A9999", name: "?", isOwner: true).capabilities == .none)
    }

    @Test func parsesBLEAdvertisement() throws {
        // v2 record: version, mac(6), bind, product_type b118 (C1000 Gen 2), sku "1763", capability 0x04
        let raw: [UInt8] = [2, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 1, 0xb1, 0x18] + Array("1763".utf8) + [0x04]
        let ad = try #require(AnkerAdvertisement.parse(Data(raw)))
        #expect(ad.mac == "AA:BB:CC:DD:EE:FF")
        #expect(ad.productType == "b118" && ad.sku == "1763")
        #expect(ad.acceptsEncryptedNegotiation)
        #expect(ModelRegistry.profile(bleProductType: ad.productType)?.partNumber == "A1763")
        #expect(ModelRegistry.profile(bleProductType: "b112")?.partNumber == "A1790P")
        #expect(AnkerAdvertisement.parse(Data([1, 2, 3])) == nil)
    }

    @Test func estimatedRuntime() {
        var t = BatteryTelemetry(); t.socPercent = 50; t.inputPowerW = 0; t.outputPowerW = 200
        #expect(t.estimatedRuntimeHours(capacityWh: 2048)! == 5.12)
        t.remainingHours = 3
        #expect(t.estimatedRuntimeHours(capacityWh: 2048) == 3)
        t.remainingHours = nil; t.outputPowerW = 0
        #expect(t.estimatedRuntimeHours(capacityWh: 2048) == nil)
    }
}

@Suite("TOU plan")
struct PlanTests {
    static let good = TOUPlan(slots: [TOUSlot(startHour: 0, endHour: 9, tariff: .peak),
                                      TOUSlot(startHour: 9, endHour: 19, tariff: .offPeak),
                                      TOUSlot(startHour: 19, endHour: 24, tariff: .peak)],
                              prices: [TOUPrice(tariff: .peak, price: "0.2"), TOUPrice(tariff: .offPeak, price: "0.001")],
                              currencyUnit: "$", reserveSOC: 6)

    @Test func validatesCoverageGapsOverlapsAndLimits() {
        #expect(Self.good.validate().isEmpty)
        var p = Self.good; p.slots[1].startHour = 10
        #expect(p.validate().contains(.gap(atHour: 9)))
        p = Self.good; p.slots[1].startHour = 8
        #expect(p.validate().contains(.overlap(atHour: 8)))
        p = Self.good; p.slots.removeLast()
        #expect(p.validate().contains(.notCoveringDay))
        p = Self.good; p.reserveSOC = 3
        #expect(p.validate(reserveRange: 15...100).contains(.reserveOutOfRange(min: 15, max: 100)))
        p = Self.good; p.prices[0].price = "abc"
        #expect(p.validate().contains(.invalidPrice("abc")))
        p = TOUPlan(slots: (0..<7).map { TOUSlot(startHour: $0, endHour: $0 + 1, tariff: .mid) } , prices: [])
        #expect(p.validate().contains(.tooManySlots(max: 6)))
        #expect(TOUPlan(slots: []).validate() == [.empty])
    }

    @Test func cloudJSONMatchesReferenceAndRoundTrips() throws {
        let ref = #"{"ranges": [{"start_time": "00:00", "end_time": "09:00", "type": 1},{"start_time": "09:00", "end_time": "19:00", "type": 3},{"start_time": "19:00", "end_time": "24:00", "type": 1}],"prices": [{"price": "0.2", "type": 1}, {"price": "0.001", "type": 3}],"unit": "$", "reserve_power": 6}"#
        let parsed = try #require(TOUPlan(cloudJSON: ref))
        #expect(parsed == Self.good && parsed.prices == Self.good.prices && parsed.reserveSOC == 6)
        let back = try #require(TOUPlan(cloudJSON: try Self.good.cloudJSONString()))
        #expect(back == Self.good && back.prices == Self.good.prices && back.currencyUnit == "$")
        #expect(TOUPlan(cloudJSON: "not json") == nil)
    }

    @Test func mqttScheduleSerialization() {
        let data = Self.good.mqttSchedule()
        #expect([UInt8](data) == [3, 1, 0, 9, 3, 9, 19, 1, 19, 24])
        #expect(TOUPlan.slots(fromMQTTSchedule: data) == Self.good.slots)
        #expect(TOUPlan.slots(fromMQTTSchedule: Data([3, 1, 0])) == nil)
    }

    @Test func normalizeMergesAndDropsUnusedPrices() {
        let p = TOUPlan(slots: [TOUSlot(startHour: 0, endHour: 12, tariff: .mid), TOUSlot(startHour: 12, endHour: 24, tariff: .mid)],
                        prices: [TOUPrice(tariff: .peak, price: "1"), TOUPrice(tariff: .mid, price: "0.5")]).normalized()
        #expect(p.slots.count == 1 && p.slots[0].endHour == 24)
        #expect(p.prices == [TOUPrice(tariff: .mid, price: "0.5")])
        #expect(Self.good.tariff(atHour: 12) == .offPeak)
    }
}

@Suite("Storage & security")
struct StorageTests {
    @Test func databaseRoundTrip() async throws {
        let db = try Database(path: ":memory:")
        let now = Date()
        try await db.insertTelemetry(TelemetryRow(timestamp: now, serial: "S1", soc: 55, inputW: 10, outputW: 20, mode: 1, connection: "cloud"))
        try await db.insertTelemetry(TelemetryRow(timestamp: now.addingTimeInterval(-7200), serial: "S1", soc: 50, inputW: nil, outputW: nil, mode: nil, connection: nil))
        let rows = try await db.telemetry(serial: "S1", since: now.addingTimeInterval(-3600))
        #expect(rows.count == 1 && rows[0].soc == 55 && rows[0].mode == 1)
        try await db.appendAudit(serial: "S1", category: "tou", message: "hello")
        #expect(try await db.audit().first?.message == "hello")
        try await db.saveSnapshot(serial: "S1", kind: "tou_plan", json: "{}")
        try await db.saveSnapshot(serial: "S1", kind: "other", json: "{}")
        #expect(try await db.snapshots(serial: "S1", kind: "tou_plan").count == 1)
        #expect(try await db.snapshots(serial: "S1").count == 2)
        try await db.setValue("a", for: "k"); try await db.setValue("b", for: "k")
        #expect(try await db.value(for: "k") == "b")
        #expect(try await db.value(for: "missing") == nil)
        try await db.pruneTelemetry(olderThan: now.addingTimeInterval(-60))
    }

    @Test func redactionRemovesSecrets() {
        let raw = "login birk5437@gmail.com x-auth-token: abcDEF123 gtoken=deadbeef serial 9JVB42LJK8J0P5RY key 0123456789abcdef0123456789abcdef0123 -----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----"
        let s = Redactor.sanitize(raw, serials: ["9JVB42LJK8J0P5RY"], email: "birk5437@gmail.com")
        #expect(!s.contains("birk5437") && !s.contains("abcDEF123") && !s.contains("deadbeef"))
        #expect(!s.contains("9JVB42LJK8J0P5RY") && s.contains("…P5RY"))
        #expect(!s.contains("AAA") && !s.contains("0123456789abcdef"))
    }

    /// The real Keychain needs a writable login keychain, which headless/sandboxed shells (CI, agents) don't have.
    /// In that case the test is *skipped*, never reported as passed.
    static let keychainAvailable: Bool = {
        let kc = KeychainManager(service: "com.ankercontroller.tests.probe.\(UUID().uuidString)")
        defer { kc.delete(account: "probe") }
        return (try? kc.save("x", account: "probe")) != nil
    }()

    @Test(.enabled(if: StorageTests.keychainAvailable, "no writable login keychain in this session"))
    func keychainSaveLoadDelete() throws {
        let kc = KeychainManager(service: "com.ankercontroller.tests.\(UUID().uuidString)")
        defer { kc.delete(account: "a") }
        try kc.save("pw1", account: "a")
        #expect(kc.load(account: "a") == "pw1")
        try kc.save("pw2", account: "a")
        #expect(kc.load(account: "a") == "pw2")
        kc.delete(account: "a")
        #expect(kc.load(account: "a") == nil)
    }
}

@Suite("Automation")
struct AutomationTests {
    static func cal(_ id: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: id)!; return c }

    @Test func validationAndConflicts() {
        let p = ModelRegistry.profile(for: "A1783")
        let ok = AutomationRule(name: "night", serial: "S", hour: 1, minute: 0, action: .setUsageMode(.timeOfUse))
        #expect(AutomationValidator.validate(ok, profile: p).isEmpty)
        #expect(!AutomationValidator.validate(ok, profile: ModelRegistry.profile(for: "A1763")).isEmpty)
        #expect(!AutomationValidator.validate(AutomationRule(name: "x", serial: "S", hour: 25, minute: 0, action: .setBackupSOC(2)), profile: p).isEmpty)
        let clash = AutomationRule(name: "day", serial: "S", hour: 1, minute: 0, weekdays: [2, 3], action: .setUsageMode(.standard))
        #expect(AutomationValidator.conflicts([ok, clash]).first?.contains("contradict") == true)
        let other = AutomationRule(name: "o", serial: "S2", hour: 1, minute: 0, action: .setUsageMode(.standard))
        #expect(AutomationValidator.conflicts([ok, other]).isEmpty)
        #expect(AutomationValidator.conflicts([ok, ok]).first?.contains("duplicates") == true)
    }

    @Test func nextFireAcrossDSTInDetroit() throws {
        let cal = Self.cal("America/Detroit")
        let rule = AutomationRule(name: "r", serial: "S", hour: 2, minute: 30, action: .setUsageMode(.standard))
        // 2027-03-14 is spring-forward in the US: 02:30 does not exist.
        let before = cal.date(from: DateComponents(year: 2027, month: 3, day: 13, hour: 12))!
        let fire = try #require(AutomationScheduler.nextFire(of: rule, after: before, calendar: cal))
        let c = cal.dateComponents([.month, .day, .hour], from: fire)
        #expect(c.month == 3 && c.day == 14 && c.hour == 3, "non-existent 02:30 fires at the next valid instant")
        // Fall-back (2027-11-07): 01:30 happens twice; must fire exactly once (first).
        let r2 = AutomationRule(name: "r2", serial: "S", hour: 1, minute: 30, action: .setUsageMode(.standard))
        let b2 = cal.date(from: DateComponents(year: 2027, month: 11, day: 6, hour: 12))!
        let f2 = try #require(AutomationScheduler.nextFire(of: r2, after: b2, calendar: cal))
        let again = try #require(AutomationScheduler.nextFire(of: r2, after: f2, calendar: cal))
        #expect(again.timeIntervalSince(f2) > 23 * 3600, "no second firing during the repeated hour")
    }

    @Test func dueRespectsCatchUpWindow() {
        let cal = Self.cal("America/Detroit")
        let rule = AutomationRule(name: "r", serial: "S", hour: 6, minute: 0, action: .setUsageMode(.standard))
        let last = cal.date(from: DateComponents(year: 2027, month: 5, day: 4, hour: 5, minute: 59))!
        let on = cal.date(from: DateComponents(year: 2027, month: 5, day: 4, hour: 6, minute: 0, second: 10))!
        let late = cal.date(from: DateComponents(year: 2027, month: 5, day: 4, hour: 9))!
        #expect(AutomationScheduler.due([rule], lastCheck: last, now: on, calendar: cal).count == 1)
        #expect(AutomationScheduler.due([rule], lastCheck: last, now: late, calendar: cal).isEmpty, "stale after sleep → skipped")
        #expect(AutomationScheduler.due([rule], lastCheck: on, now: on.addingTimeInterval(30), calendar: cal).isEmpty)
    }
}

@Suite("Plan editing")
struct PlanEditingTests {
    @Test func editsStayContiguousAndValid() {
        var p = TOUPlan.defaultPlan
        for _ in 0..<5 { p.splitLongestSlot(); #expect(p.validate().isEmpty) }
        #expect(p.slots.count == 6 && !p.canAddSlot)
        p.splitLongestSlot()
        #expect(p.slots.count == 6, "never exceeds the device limit of 6 ranges")
        p.setEnd(ofSlot: 0, to: 23)
        #expect(p.validate().isEmpty && p.orderedSlots[0].endHour < p.orderedSlots[1].endHour)
        p.setEnd(ofSlot: 5, to: 3)   // last slot cannot move
        #expect(p.orderedSlots.last?.endHour == 24)
        p.removeSlot(0)
        #expect(p.validate().isEmpty && p.orderedSlots.first?.startHour == 0 && p.slots.count == 5)
        while p.slots.count > 1 { p.removeSlot(p.slots.count - 1) }
        #expect(p.slots == [TOUSlot(startHour: 0, endHour: 24, tariff: p.slots[0].tariff)])
        p.removeSlot(0)
        #expect(p.slots.count == 1, "the last remaining slot cannot be removed")
    }
}

@Suite("Full SOLIX catalog")
struct CatalogTests {
    @Test func everyListedModelIsReadOnly() {
        #expect(ModelRegistry.catalog.count > 60)
        for p in ModelRegistry.catalog {
            #expect(!p.capabilities.supportsTOU && p.settableUsageModes.isEmpty && !p.supportsBatteryOnlyControl, "\(p.partNumber)")
            #expect(!p.telemetryDocumented, "\(p.partNumber) has no implemented layout")
        }
        #expect(Set(ModelRegistry.catalog.map(\.partNumber)).count == ModelRegistry.catalog.count, "duplicate part numbers")
    }

    @Test func unknownPartNumbersStillResolve() {
        let d = SOLIXDevice(serial: "S", partNumber: "A9999", name: "Mystery", isOwner: true)
        #expect(d.profile?.partNumber == "A9999" && d.profile?.category == .other)
        let cloud = CloudTransport(backend: CloudBackend())
        #expect(cloud.unsupportedReason(for: .monitor, device: d) != nil)
        #expect(cloud.unsupportedReason(for: .setUsageMode, device: d) != nil)
    }

    @Test func catalogModelsAreNamedAndSized() {
        #expect(ModelRegistry.profile(for: "A1722")?.marketingName == "SOLIX C300")
        #expect(ModelRegistry.profile(for: "A17C5")?.category == .solarbank)
        #expect(ModelRegistry.profile(bleProductType: "b103")?.partNumber == "A1753")
        #expect(ModelRegistry.profile(for: "A1790")?.telemetryDocumented == true)
        #expect(ModelRegistry.profile(for: "A1765")?.capabilities.supportsBluetoothMonitoring == true)
        #expect(BLESession.supports(partNumber: "A1765") && !BLESession.supports(partNumber: "A1722"))
    }
}
