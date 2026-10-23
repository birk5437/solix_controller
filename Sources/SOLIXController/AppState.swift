import SwiftUI
import Observation
import SOLIXCore
import AppKit

struct PendingConfirmation: Identifiable {
    let id = UUID()
    let summary: ChangeSummary
    let continuation: CheckedContinuation<Bool, Never>
}

struct HistoryPoint: Identifiable {
    var id: Date { time }
    var time: Date
    var soc: Double?
    var inputW: Double?
    var outputW: Double?
    var mode: Int?
}

enum SidebarSelection: Hashable {
    case device(String)
    case automation
    case appDiagnostics
}

@MainActor
@Observable
final class AppState {
    // Services
    let backend: CloudBackend
    let bluetooth = BluetoothService()
    let lan = LocalNetworkService()
    let keychain = KeychainManager()
    let database: Database
    private(set) var transports: TransportManager
    private(set) var tou: TOUService
    @ObservationIgnored private var automation: AutomationEngine?

    // Device state
    var devices: [SOLIXDevice] = []
    var selection: SidebarSelection?
    var telemetry: [String: BatteryTelemetry] = [:]
    var history: [String: [HistoryPoint]] = [:]
    var storedPlans: [String: TOUPlan] = [:]
    var editedPlans: [String: TOUPlan] = [:]
    var planLoadError: [String: String] = [:]
    var reports: [String: TOUActivationReport] = [:]
    var lastSuccessfulChange: [String: Date] = [:]
    var lastError: [String: String] = [:]
    var diagnostics: [String: [DiagnosticCheck]] = [:]
    var busy: Set<String> = []
    var lastTransportUsed: [String: TransportKind] = [:]

    // Session
    var email: String { didSet { UserDefaults.standard.set(email, forKey: "email") } }
    var country: String { didSet { UserDefaults.standard.set(country, forKey: "country") } }
    var cloudSignedIn = false
    var mqttConnected = false
    var signingIn = false
    var signInError: String?
    var readOnly: Bool { didSet { UserDefaults.standard.set(readOnly, forKey: "readOnly") } }
    var pendingConfirmation: PendingConfirmation?

    // Automation
    var rules: [AutomationRule] = []
    var automationLog: [String] = []

    // Logs
    var audit: [AuditEntry] = []

    @ObservationIgnored private var lastHistoryWrite: [String: Date] = [:]
    @ObservationIgnored private var consumeTask: Task<Void, Never>?

    init() {
        let db = (try? Database(path: (try? Database.defaultPath()) ?? ":memory:")) ?? (try! Database(path: ":memory:"))
        database = db
        let backend = CloudBackend(log: { msg in Task { try? await db.appendAudit(serial: nil, category: "cloud", message: msg) } })
        self.backend = backend
        transports = TransportManager(transports: [LocalWiFiTransport(), BluetoothTransport(), CloudTransport(backend: backend)])
        tou = TOUService(
            backend: backend,
            saveSnapshot: { sn, kind, json in try? await db.saveSnapshot(serial: sn, kind: kind, json: json) },
            audit: { sn, msg in try? await db.appendAudit(serial: sn, category: "change", message: msg) })
        email = UserDefaults.standard.string(forKey: "email") ?? ""
        country = UserDefaults.standard.string(forKey: "country") ?? "US"
        readOnly = UserDefaults.standard.object(forKey: "readOnly") as? Bool ?? true
    }

    // MARK: Lifecycle

    func start() async {
        if let json = try? await database.value(for: "devices"), let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode([SOLIXDevice].self, from: data) {
            devices = saved.map { var d = $0; d.status = .offline; d.activeTransports = []; return d }
            selection = devices.first.map { .device($0.serial) }
        }
        if let json = try? await database.value(for: "rules"), let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode([AutomationRule].self, from: data) { rules = saved }
        if let json = try? await database.value(for: "ble_trusted"), let data = json.data(using: .utf8),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) { bluetooth.trustedIdentifiers = Set(ids) }
        await loadHistory()
        await refreshAudit()
        startAutomation()
        consumeTask = Task { [weak self] in
            guard let self else { return }
            for await u in self.backend.updates { await self.apply(u) }
        }
        // Silent re-login if credentials were remembered.
        if !email.isEmpty, let pw = keychain.load(account: email) { await signIn(password: pw, remember: true) }
    }

    func persistDevices() {
        guard let data = try? JSONEncoder().encode(devices), let s = String(data: data, encoding: .utf8) else { return }
        Task { try? await database.setValue(s, for: "devices") }
    }

    func persistRules() {
        guard let data = try? JSONEncoder().encode(rules), let s = String(data: data, encoding: .utf8) else { return }
        Task { try? await database.setValue(s, for: "rules") }
    }

    func trustBLE(_ id: UUID, _ trusted: Bool) {
        if trusted { bluetooth.trustedIdentifiers.insert(id) } else { bluetooth.trustedIdentifiers.remove(id) }
        if let data = try? JSONEncoder().encode(Array(bluetooth.trustedIdentifiers)), let s = String(data: data, encoding: .utf8) {
            Task { try? await database.setValue(s, for: "ble_trusted") }
        }
    }

    func refreshAudit() async { audit = (try? await database.audit(limit: 400)) ?? [] }

    func device(_ serial: String) -> SOLIXDevice? { devices.first { $0.serial == serial } }

    // MARK: Sign-in & discovery (cloud)

    func signIn(password: String, remember: Bool) async {
        signingIn = true; signInError = nil
        defer { signingIn = false }
        do {
            let found = try await backend.signIn(email: email, password: password, country: country)
            cloudSignedIn = true
            if remember { try? keychain.save(password, account: email) } else { keychain.delete(account: email) }
            // Merge: keep user overrides, add new devices.
            for c in found {
                if let i = devices.firstIndex(where: { $0.serial == c.serial }) {
                    devices[i].name = c.name; devices[i].firmware = c.firmware ?? devices[i].firmware
                } else {
                    devices.append(SOLIXDevice(serial: c.serial, partNumber: c.partNumber, name: c.name, isOwner: true, firmware: c.firmware))
                }
            }
            // Only models with a verified telemetry layout are monitored over MQTT.
            let monitorable = devices.filter { ModelRegistry.profile(for: $0.partNumber) != nil }
            for i in devices.indices { devices[i].status = .connecting }
            persistDevices()
            if selection == nil, let f = devices.first { selection = .device(f.serial) }
            do {
                try await backend.startMonitoring(monitorable)
                mqttConnected = true
                for i in devices.indices where ModelRegistry.profile(for: devices[i].partNumber) != nil {
                    devices[i].status = .online; devices[i].activeTransports = [.cloud]
                }
                for i in devices.indices where ModelRegistry.profile(for: devices[i].partNumber) == nil { devices[i].status = .unknown }
            } catch {
                mqttConnected = false
                for i in devices.indices { devices[i].status = .offline }
                signInError = "Signed in, but the live-data channel (MQTT) failed: \(error)"
            }
            persistDevices()
            for d in monitorable { await loadStoredPlan(d.serial) }
        } catch {
            cloudSignedIn = false
            signInError = "\(error)"
        }
        await refreshAudit()
    }

    func signOut() async {
        await backend.signOut()
        cloudSignedIn = false; mqttConnected = false
        keychain.delete(account: email)
        for i in devices.indices { devices[i].status = .offline; devices[i].activeTransports = [] }
    }

    // MARK: Telemetry

    private func apply(_ u: TelemetryUpdate) async {
        telemetry[u.serial] = u.telemetry
        if let i = devices.firstIndex(where: { $0.serial == u.serial }) {
            devices[i].status = .online
            if !devices[i].activeTransports.contains(.cloud) { devices[i].activeTransports.append(.cloud) }
        }
        let now = Date()
        let t = u.telemetry
        history[u.serial, default: []].append(HistoryPoint(time: now, soc: t.socPercent, inputW: t.inputPowerW, outputW: t.outputPowerW, mode: t.usageMode))
        if history[u.serial, default: []].count > 4000 { history[u.serial]?.removeFirst(500) }
        // Persist at most once a minute per device to keep the database small and polling modest.
        if now.timeIntervalSince(lastHistoryWrite[u.serial] ?? .distantPast) >= 60 {
            lastHistoryWrite[u.serial] = now
            try? await database.insertTelemetry(TelemetryRow(timestamp: now, serial: u.serial, soc: t.socPercent, inputW: t.inputPowerW,
                                                              outputW: t.outputPowerW, mode: t.usageMode, connection: "cloud"))
        }
    }

    func loadHistory(hours: Double = 24) async {
        for d in devices {
            let rows = (try? await database.telemetry(serial: d.serial, since: Date().addingTimeInterval(-hours * 3600))) ?? []
            history[d.serial] = rows.map { HistoryPoint(time: $0.timestamp, soc: $0.soc, inputW: $0.inputW, outputW: $0.outputW, mode: $0.mode) }
        }
    }

    // MARK: TOU

    func loadStoredPlan(_ serial: String) async {
        guard let d = device(serial), d.profile != nil else { return }
        do {
            let plan = try await backend.fetchCloudPlan(serial: serial)
            storedPlans[serial] = plan
            planLoadError[serial] = nil
            if editedPlans[serial] == nil { editedPlans[serial] = plan ?? TOUPlan.defaultPlan }
        } catch {
            planLoadError[serial] = "\(error)"
            if editedPlans[serial] == nil { editedPlans[serial] = TOUPlan.defaultPlan }
        }
    }

    private func confirm(_ s: ChangeSummary) async -> Bool {
        await withCheckedContinuation { cont in pendingConfirmation = PendingConfirmation(summary: s, continuation: cont) }
    }

    func resolveConfirmation(_ ok: Bool) {
        guard let p = pendingConfirmation else { return }
        pendingConfirmation = nil
        p.continuation.resume(returning: ok)
    }

    private func record(_ serial: String, _ r: TOUActivationReport) async {
        reports[serial] = r
        if r.success { lastSuccessfulChange[serial] = Date(); lastError[serial] = nil } else { lastError[serial] = r.summary }
        lastTransportUsed[serial] = .cloud
        await loadStoredPlan(serial)
        await refreshAudit()
    }

    func setMode(_ mode: UsageMode, serial: String) async {
        guard let d = device(serial), !busy.contains(serial) else { return }
        busy.insert(serial); defer { busy.remove(serial) }
        let plan = mode == .timeOfUse ? editedPlans[serial] : nil
        let r = await tou.setMode(mode, on: d, plan: plan, readOnly: readOnly) { [self] s in await confirm(s) }
        await record(serial, r)
    }

    func savePlan(serial: String) async {
        guard let d = device(serial), let plan = editedPlans[serial]?.normalized(), !busy.contains(serial) else { return }
        busy.insert(serial); defer { busy.remove(serial) }
        let r = await tou.savePlan(plan, on: d, readOnly: readOnly) { [self] s in await confirm(s) }
        await record(serial, r)
        if r.success { editedPlans[serial] = plan }
    }

    func setReserve(_ soc: Int, serial: String) async {
        guard let d = device(serial), !busy.contains(serial) else { return }
        busy.insert(serial); defer { busy.remove(serial) }
        let r = await tou.setReserve(soc, on: d, readOnly: readOnly) { [self] s in await confirm(s) }
        await record(serial, r)
    }

    func runDiagnostics(serial: String) async {
        guard let d = device(serial) else { return }
        diagnostics[serial] = await tou.diagnose(device: d, plan: editedPlans[serial])
    }

    func restorePreviousPlan(serial: String) async {
        guard let snaps = try? await database.snapshots(serial: serial, kind: "tou_plan"), let s = snaps.first,
              let plan = TOUPlan(cloudJSON: s.json) else { return }
        editedPlans[serial] = plan
    }

    func setPreferredTransport(_ t: TransportKind?, serial: String) {
        guard let i = devices.firstIndex(where: { $0.serial == serial }) else { return }
        devices[i].preferredTransport = t; persistDevices()
    }

    // MARK: Automation

    func startAutomation() {
        automation = AutomationEngine(rules: { [weak self] in self?.rules ?? [] }, perform: { [weak self] rule in await self?.perform(rule) })
        automation?.start()
    }

    func perform(_ rule: AutomationRule) async {
        guard let d = device(rule.serial) else { return }
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        if readOnly { automationLog.insert("\(stamp) “\(rule.name)” skipped: read-only mode", at: 0); return }
        // A standing confirmation was given when the rule was created.
        let r: TOUActivationReport
        switch rule.action {
        case .setUsageMode(let m): r = await tou.setMode(m, on: d, plan: editedPlans[d.serial] ?? storedPlans[d.serial], readOnly: false) { _ in true }
        case .setBackupSOC(let s): r = await tou.setReserve(s, on: d, readOnly: false) { _ in true }
        }
        automationLog.insert("\(stamp) “\(rule.name)”: \(r.success ? "verified" : "NOT verified") — \(r.summary)", at: 0)
        try? await database.appendAudit(serial: d.serial, category: "automation", message: "Rule “\(rule.name)”: \(r.success ? "verified" : "failed") — \(r.summary)")
        await record(d.serial, r)
    }

    // MARK: Export

    func sanitizedDiagnosticReport() async -> String {
        let serials = devices.map(\.serial)
        var out: [String] = []
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        out.append("SOLIX Controller \(v) — diagnostic export \(ISO8601DateFormatter().string(from: Date()))")
        out.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("Read-only mode: \(readOnly)  |  Cloud: \(cloudSignedIn ? "signed in" : "signed out")  |  MQTT: \(mqttConnected ? "connected" : "disconnected")  |  Bluetooth: \(bluetooth.availability.rawValue)")
        out.append("")
        for d in devices {
            let t = telemetry[d.serial]
            out.append("Device \(d.partNumber) \(d.name) sn …\(d.serial.suffix(4)) fw \(d.firmware ?? "?") status \(d.status.rawValue) transports \(d.activeTransports.map(\.label))")
            out.append("  capabilities: TOU=\(d.capabilities.supportsTOU) reserve=\(d.capabilities.supportsReserveSOC) — \(d.profile?.touNote ?? "unknown model")")
            if let t { out.append("  telemetry: soc \(t.socPercent.map { "\($0)" } ?? "-")% in \(t.inputPowerW.map { "\($0)" } ?? "-")W out \(t.outputPowerW.map { "\($0)" } ?? "-")W mode \(t.usageMode.map(String.init) ?? "-") backup \(t.backupSOC.map(String.init) ?? "-")") }
            if let p = storedPlans[d.serial] { out.append("  stored plan: \((try? p.cloudJSONString()) ?? "?")") }
            if let e = planLoadError[d.serial] { out.append("  plan read error: \(e)") }
            if let r = reports[d.serial] {
                out.append("  last attempt: \(r.success ? "VERIFIED" : "NOT verified") — \(r.summary)")
                for s in r.steps { out.append("    [\(s.ok ? "ok" : "!!")] \(s.name): \(s.detail)") }
            }
            if let c = diagnostics[d.serial] { for x in c { out.append("  check \(x.title): \(x.status.rawValue) — \(x.detail)") } }
            let frames = (await backend.capturedFrames).filter { $0.serial == d.serial }.suffix(60)
            out.append("  protocol capture (decoded values only; raw bytes omitted): \(frames.count) frame(s)")
            for f in frames { out.append("    \(f.direction.rawValue) \(f.msgType) changed=\(f.changedFields) \(f.note ?? "")") }
        }
        out.append("")
        out.append("Audit trail (latest first):")
        for a in audit.prefix(200) {
            out.append("  \(ISO8601DateFormatter().string(from: a.timestamp)) [\(a.category)] \(a.message)")
        }
        return Redactor.sanitize(out.joined(separator: "\n"), serials: serials, email: email)
    }

    func exportDiagnostics() async {
        let text = await sanitizedDiagnosticReport()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "solix-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}
