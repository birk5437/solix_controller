import Testing
import Foundation
@testable import SOLIXCore

// MARK: - Mocks

actor MockHTTP: HTTPTransporting {
    var requests: [URLRequest] = []
    var handler: @Sendable (URLRequest) -> (Data, Int)
    init(_ h: @escaping @Sendable (URLRequest) -> (Data, Int)) { handler = h }
    func send(_ request: URLRequest) async throws -> (Data, Int) { requests.append(request); return handler(request) }
    func setHandler(_ h: @escaping @Sendable (URLRequest) -> (Data, Int)) { handler = h }
}

func json(_ o: Any, status: Int = 200) -> (Data, Int) { (try! JSONSerialization.data(withJSONObject: o), status) }

struct StubTransport: SOLIXTransport {
    let kind: TransportKind
    var available = true
    var unsupported: String? = nil
    func isAvailable() async -> Bool { available }
    func unsupportedReason(for op: DeviceOperation, device: SOLIXDevice) -> String? { unsupported }
}

actor MockBackend: TOUBackend {
    var signedIn = true, mqtt = true
    var storedPlan: TOUPlan?
    var fetchError: Error?
    var pushStoresDifferent = false
    var deviceObeys = true
    var deviceScheduleOverride: [TOUSlot]?
    var telemetry = BatteryTelemetry()
    var sent: [String] = []

    var cloudSignedIn: Bool { signedIn }
    var mqttConnected: Bool { mqtt }
    func configure(_ f: @Sendable (isolated MockBackend) -> Void) { f(self) }

    func fetchCloudPlan(serial: String) async throws -> TOUPlan? { if let e = fetchError { throw e }; return storedPlan }
    func pushCloudPlan(serial: String, plan: TOUPlan) async throws {
        sent.append("plan")
        var p = plan
        if pushStoresDifferent { p.slots[0].tariff = .mid }
        storedPlan = p
    }
    func sendUsageMode(_ device: SOLIXDevice, mode: UsageMode) async throws {
        sent.append("mode:\(mode.rawValue)")
        if deviceObeys {
            telemetry.usageMode = mode.rawValue
            if mode == .timeOfUse { telemetry.touSchedule = deviceScheduleOverride ?? storedPlan?.slots }
        }
    }
    func sendBackupSOC(_ device: SOLIXDevice, soc: Int) async throws { sent.append("soc:\(soc)"); telemetry.backupSOC = soc }
    func requestTelemetry(_ device: SOLIXDevice) async throws {}
    func latestTelemetry(serial: String) async -> BatteryTelemetry? { telemetry }
    func awaitTelemetry(serial: String, since: Date, timeout: TimeInterval, where predicate: @Sendable (BatteryTelemetry) -> Bool) async -> BatteryTelemetry? {
        predicate(telemetry) ? telemetry : nil
    }
}

let c2000 = SOLIXDevice(serial: "C2000SN12345", partNumber: "A1783", name: "C2000", isOwner: true)

// MARK: - Cloud client

@Suite("Cloud client")
struct CloudTests {
    static func loginOK(_ expires: Double) -> (Data, Int) {
        json(["code": 0, "msg": "success", "data": ["auth_token": "TOKEN-SECRET", "user_id": "user-123", "token_expires_at": expires, "nick_name": "Nick"]])
    }

    @Test func loginEncryptsPasswordAndAuthenticatesLaterRequests() async throws {
        let now = Date()
        let http = MockHTTP { req in
            req.url!.path.hasSuffix("passport/login") ? Self.loginOK(now.timeIntervalSince1970 + 86400)
                : json(["code": 0, "data": ["pps_list": [["device_sn": "SN1", "device_pn": "A1783", "device_name": "C2000", "main_version": "v1.2"]]]])
        }
        let client = AnkerCloudClient(country: "us", http: http, minInterval: 0, now: { now })
        let s = try await client.login(email: "me@example.com", password: "hunter2-plain")
        #expect(s.userID == "user-123" && s.nickname == "Nick")
        let devices = try await client.listDevices()
        #expect(devices == [CloudDevice(serial: "SN1", partNumber: "A1783", name: "C2000", firmware: "v1.2")])

        let reqs = await http.requests
        let loginBody = String(decoding: reqs[0].httpBody!, as: UTF8.self)
        #expect(!loginBody.contains("hunter2-plain"), "password must never be sent in plaintext")
        let obj = try JSONSerialization.jsonObject(with: reqs[0].httpBody!) as! [String: Any]
        let pk = ((obj["client_secret_info"] as! [String: Any])["public_key"] as! String)
        #expect(pk.count == 130 && pk.hasPrefix("04"))
        #expect(obj["ab"] as? String == "US")
        #expect(reqs[0].url!.host == "ankerpower-api.anker.com")
        #expect(reqs[1].value(forHTTPHeaderField: "x-auth-token") == "TOKEN-SECRET")
        #expect(reqs[1].value(forHTTPHeaderField: "gtoken") == AnkerCrypto.md5Hex("user-123"))
        #expect(reqs[1].value(forHTTPHeaderField: "country") == "US")
        #expect(await client.isLoggedIn)
    }

    @Test func mapsErrorCodes() async throws {
        let http = MockHTTP { _ in json(["code": 26108, "msg": "bad pw"]) }
        let c = AnkerCloudClient(country: "US", http: http, minInterval: 0)
        await #expect(throws: CloudError.invalidCredentials(code: 26108, message: "bad pw")) { try await c.login(email: "a@b.c", password: "x") }
        #expect(CloudError.fromCode(160003, message: "m") == .noPermission(message: "m"))
        #expect(CloudError.fromCode(26052, message: "m") == .verificationRequired(code: 26052, message: "m"))
        #expect(CloudError.fromCode(26084, message: "") == .tokenKickedOut)
    }

    @Test func requiresLoginAndHonoursExpiry() async throws {
        let http = MockHTTP { _ in Self.loginOK(1000) }
        let c = AnkerCloudClient(country: "US", http: http, minInterval: 0, now: { Date(timeIntervalSince1970: 2000) })
        await #expect(throws: CloudError.notLoggedIn) { _ = try await c.listDevices() }
        try await c.login(email: "a@b.c", password: "x")   // token already expired relative to clock
        #expect(await c.isLoggedIn == false)
        await #expect(throws: CloudError.notLoggedIn) { _ = try await c.listDevices() }
    }

    @Test func rateLimitBlocksEndpointWithoutRetrying() async throws {
        let now = Date()
        let http = MockHTTP { req in
            req.url!.path.hasSuffix("login") ? Self.loginOK(now.timeIntervalSince1970 + 9999) : json(["code": 429], status: 429)
        }
        let c = AnkerCloudClient(country: "US", http: http, minInterval: 0, now: { now })
        try await c.login(email: "a@b.c", password: "x")
        await #expect(throws: CloudError.rateLimited(retryAfter: 60)) { _ = try await c.listDevices() }
        let before = await http.requests.count
        await #expect(throws: CloudError.self) { _ = try await c.listDevices() }
        #expect(await http.requests.count == before, "no request is made while the endpoint is throttled")
    }

    @Test func writesAreNeverAutoRetried() async throws {
        let now = Date()
        let http = MockHTTP { req in
            req.url!.path.hasSuffix("login") ? Self.loginOK(now.timeIntervalSince1970 + 9999) : json(["code": 160003, "msg": "no permission"])
        }
        let c = AnkerCloudClient(country: "US", http: http, minInterval: 0, now: { now })
        try await c.login(email: "a@b.c", password: "x")
        await #expect(throws: CloudError.noPermission(message: "no permission")) {
            try await c.setDeviceAttributes(serial: "S", attributes: ["pps_use_time": "{}"])
        }
        #expect(await http.requests.filter { $0.url!.path.contains("set_device_attrs") }.count == 1)
    }

    @Test func aesRoundTripAndRegionAndTimezone() throws {
        let key = Data((0..<32).map(UInt8.init))
        let enc = try AnkerCrypto.aesCBCEncrypt(Data("secret pw ✓".utf8), key: key)
        #expect(enc.count % 16 == 0)
        #expect(String(decoding: try AnkerCrypto.aesCBCDecrypt(enc, key: key), as: UTF8.self) == "secret pw ✓")
        #expect(AnkerRegion.forCountry("us") == .com && AnkerRegion.forCountry("DE") == .eu)
        let tz = TimeZone(identifier: "America/Detroit")!
        let summer = Date(timeIntervalSince1970: 1_782_000_000), winter = Date(timeIntervalSince1970: 1_768_000_000)
        #expect(AnkerCloudClient.timezoneHeader(tz, at: summer) == "GMT-04:00")
        #expect(AnkerCloudClient.timezoneHeader(tz, at: winter) == "GMT-05:00")
    }
}

// MARK: - Transport selection / failover

@Suite("Transport manager")
struct TransportTests {
    @Test func prefersLocalThenBluetoothThenCloud() async {
        let m = TransportManager(transports: [StubTransport(kind: .cloud), StubTransport(kind: .bluetooth), StubTransport(kind: .localWiFi)])
        let sel = await m.select(for: .monitor, device: c2000)
        #expect(sel.ordered == [.localWiFi, .bluetooth, .cloud])
    }

    @Test func userOverrideGoesFirstAndUnsupportedIsExplained() async {
        var d = c2000; d.preferredTransport = .cloud
        let m = TransportManager(transports: [StubTransport(kind: .cloud), StubTransport(kind: .bluetooth, unsupported: "no BLE TOU"),
                                              StubTransport(kind: .localWiFi, available: false)])
        let sel = await m.select(for: .setUsageMode, device: d)
        #expect(sel.ordered == [.cloud])
        #expect(sel.rejected[.bluetooth] == "no BLE TOU" && sel.rejected[.localWiFi] == "currently unavailable")
    }

    @Test func readsFailOverButWritesDoNot() async throws {
        let m = TransportManager(transports: [StubTransport(kind: .bluetooth), StubTransport(kind: .cloud)])
        struct Boom: Error {}
        let (v, via) = try await m.run(.monitor, device: c2000) { k in if k == .bluetooth { throw Boom() }; return 42 }
        #expect(v == 42 && via == .cloud)

        let calls = Counter()
        await #expect(throws: Boom.self) {
            _ = try await m.run(.setUsageMode, device: c2000) { k in await calls.add(k); throw Boom() }
        }
        #expect(await calls.kinds == [.bluetooth], "non-idempotent write attempted exactly once, never retried on another transport")
    }

    @Test func throwsDetailedErrorWhenNothingSupportsOperation() async {
        let m = TransportManager(transports: [StubTransport(kind: .cloud, unsupported: "nope")])
        do { _ = try await m.run(.writeTOUPlan, device: c2000) { _ in 1 }; Issue.record("expected throw") }
        catch let e as NoTransportError { #expect(e.reasons[.cloud] == "nope" && e.reasons[.bluetooth] == "not configured") }
        catch { Issue.record("wrong error \(error)") }
    }

    @Test func realTransportsReportVerifiedSupportOnly() {
        let backend = CloudBackend()
        let cloud = CloudTransport(backend: backend)
        let c1000 = SOLIXDevice(serial: "x", partNumber: "A1763", name: "C1000", isOwner: true)
        let f3800 = SOLIXDevice(serial: "y", partNumber: "A1790P", name: "F3800", isOwner: true)
        #expect(cloud.unsupportedReason(for: .setUsageMode, device: c2000) == nil)
        #expect(cloud.unsupportedReason(for: .setUsageMode, device: c1000) != nil)
        #expect(cloud.unsupportedReason(for: .writeTOUPlan, device: f3800) != nil)
        #expect(cloud.unsupportedReason(for: .monitor, device: f3800) == nil)
        #expect(BluetoothTransport().unsupportedReason(for: .setUsageMode, device: c1000) != nil)
        #expect(LocalWiFiTransport().unsupportedReason(for: .monitor, device: c2000) != nil)
    }
}
actor Counter { var kinds: [TransportKind] = []; func add(_ k: TransportKind) { kinds.append(k) } }

// MARK: - TOU activation

@Suite("TOU activation")
struct TOUServiceTests {
    static func service(_ b: MockBackend, snaps: SnapBox = SnapBox()) -> TOUService {
        TOUService(backend: b, verifyTimeout: 0.1, saveSnapshot: { _, k, j in await snaps.add(k, j) }, audit: { _, _ in })
    }
    static let plan = PlanTests.good

    @Test func verifiedSuccessPreservesPreviousPlanAndReadsBack() async {
        let b = MockBackend()
        await b.configure { $0.storedPlan = TOUPlan.defaultPlan; $0.telemetry.minSOC = 1; $0.telemetry.maxSOC = 100; $0.telemetry.usageMode = 0; $0.telemetry.backupSOC = 20 }
        let snaps = SnapBox()
        let r = await Self.service(b, snaps: snaps).setMode(.timeOfUse, on: c2000, plan: Self.plan, readOnly: false) { _ in true }
        #expect(r.success && r.modeStage == .verified && r.planStage == .verified && r.deviceReportedMode == 1)
        #expect(await b.sent == ["plan", "soc:6", "mode:1"], "plan first, then reserve, then mode — each exactly once")
        #expect(await snaps.items.count == 1, "previous plan preserved before overwrite")
        #expect(r.steps.contains { $0.name == "Read plan back" && $0.ok })
    }

    @Test func httpOKIsNotSuccessWhenDeviceDoesNotChangeMode() async {
        let b = MockBackend()
        await b.configure { $0.storedPlan = Self.plan; $0.deviceObeys = false; $0.telemetry.usageMode = 0; $0.telemetry.backupSOC = 6 }
        let r = await Self.service(b).setMode(.timeOfUse, on: c2000, plan: Self.plan, readOnly: false) { _ in true }
        #expect(!r.success && r.modeStage == .failed && r.deviceReportedMode == 0)
        #expect(r.problems.contains { $0.title == "Device did not confirm" })
        #expect(await b.sent == ["mode:1"], "command published once; no retry")
    }

    @Test func cloudStoringADifferentPlanAbortsBeforeModeChange() async {
        let b = MockBackend()
        await b.configure { $0.pushStoresDifferent = true; $0.telemetry.backupSOC = 6 }
        let r = await Self.service(b).setMode(.timeOfUse, on: c2000, plan: Self.plan, readOnly: false) { _ in true }
        #expect(!r.success && r.planStage == .failed)
        #expect(await b.sent == ["plan"], "mode must not be switched when the plan could not be verified")
    }

    @Test func declinedConfirmationAndReadOnlySendNothing() async {
        let b = MockBackend()
        await b.configure { $0.storedPlan = Self.plan }
        let declined = await Self.service(b).setMode(.timeOfUse, on: c2000, plan: Self.plan, readOnly: false) { _ in false }
        #expect(!declined.success && declined.summary.contains("Cancelled"))
        let ro = await Self.service(b).setMode(.timeOfUse, on: c2000, plan: Self.plan, readOnly: true) { _ in Issue.record("must not prompt"); return true }
        #expect(!ro.success && ro.summary.contains("Read-only"))
        #expect(await b.sent.isEmpty)
    }

    @Test func invalidPlanIsRejectedBeforeAnyWrite() async {
        let b = MockBackend()
        var bad = Self.plan; bad.slots[1].startHour = 12
        let r = await Self.service(b).setMode(.timeOfUse, on: c2000, plan: bad, readOnly: false) { _ in true }
        #expect(!r.success && r.problems.contains { $0.detail.contains("gap") })
        #expect(await b.sent.isEmpty)
    }

    @Test func unsupportedModelsGetNoSpeculativeCommands() async {
        let b = MockBackend()
        for pn in ["A1763", "A1790P"] {
            let d = SOLIXDevice(serial: "S\(pn)", partNumber: pn, name: pn, isOwner: true)
            let r = await Self.service(b).setMode(.timeOfUse, on: d, plan: Self.plan, readOnly: false) { _ in true }
            #expect(!r.success && r.summary.contains("not documented"))
        }
        #expect(await b.sent.isEmpty)
    }

    @Test func permissionErrorSurfacesAndModeStillRequiresPlan() async {
        let b = MockBackend()
        await b.configure { $0.fetchError = CloudError.noPermission(message: "member account") }
        let r = await Self.service(b).setMode(.timeOfUse, on: c2000, plan: nil, readOnly: false) { _ in true }
        #expect(!r.success && r.problems.contains { $0.detail.contains("owner") })
    }

    @Test func disablingTOUIsVerified() async {
        let b = MockBackend()
        await b.configure { $0.telemetry.usageMode = 1 }
        let r = await Self.service(b).setMode(.standard, on: c2000, plan: nil, readOnly: false) { s in s.targetMode == .standard }
        #expect(r.success && r.deviceReportedMode == 0)
    }

    @Test func diagnosticsCoverAllTenChecksAndFlagProblems() async {
        let b = MockBackend()
        await b.configure { $0.mqtt = false; $0.telemetry.usageMode = 3; $0.telemetry.acPlugStatus = 0; $0.telemetry.minSOC = 10; $0.telemetry.maxSOC = 90 }
        var p = Self.plan; p.reserveSOC = 5; p.prices = []
        let checks = await Self.service(b).diagnose(device: c2000, plan: p)
        #expect(checks.count == 10)
        func status(_ n: Int) -> CheckStatus { checks.first { $0.title.hasPrefix("\(n).") }!.status }
        #expect(status(1) == .pass && status(4) == .warn && status(5) == .warn && status(6) == .warn)
        #expect(status(7) == .fail, "reserve 5% < min SOC 10% + 5")
        #expect(status(9) == .fail, "MQTT disconnected")
        #expect(status(10) == .unknown)
        let c1000 = SOLIXDevice(serial: "x", partNumber: "A1763", name: "C1000", isOwner: true)
        #expect(await Self.service(b).diagnose(device: c1000, plan: nil).first?.status == .fail)
    }
}
actor SnapBox { var items: [(String, String)] = []; func add(_ k: String, _ j: String) { items.append((k, j)) } }

@Suite("Multi-device")
struct MultiDeviceTests {
    @Test func telemetryStoreKeepsDevicesIndependent() async throws {
        let db = try Database(path: ":memory:")
        let now = Date()
        for (sn, soc) in [("A", 10.0), ("B", 90.0), ("C", 50.0)] {
            try await db.insertTelemetry(TelemetryRow(timestamp: now, serial: sn, soc: soc, inputW: 0, outputW: 0, mode: nil, connection: nil))
        }
        #expect(try await db.telemetry(serial: "A", since: now.addingTimeInterval(-1)).map(\.soc) == [10])
        #expect(try await db.telemetry(serial: "B", since: now.addingTimeInterval(-1)).map(\.soc) == [90])
        let devices = ["A1763", "A1783", "A1790P"].enumerated().map { SOLIXDevice(serial: "D\($0.offset)", partNumber: $0.element, name: $0.element, isOwner: true) }
        #expect(Set(devices.map(\.id)).count == 3)
        #expect(devices.map { $0.capabilities.supportsTOU } == [false, true, false])
    }
}
