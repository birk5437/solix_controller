import SwiftUI
import SOLIXCore

struct DiagnosticsView: View {
    @Environment(AppState.self) private var state
    let device: SOLIXDevice
    @State private var frames: [CapturedFrame] = []
    @State private var capturing = false

    var t: BatteryTelemetry? { state.telemetry[device.serial] }
    var report: TOUActivationReport? { state.reports[device.serial] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "TOU debug panel", systemImage: "ladybug") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    row("Current mode (device-reported)", t?.usageMode.map { UsageMode(rawValue: $0)?.label ?? "code \($0)" } ?? "not reported")
                    row("Requested mode", report.map { $0.requestedMode.label } ?? "—")
                    row("Mode after last attempt", report?.deviceReportedMode.map { UsageMode(rawValue: $0)?.label ?? "code \($0)" } ?? "—")
                    row("Stored TOU schedule", state.storedPlans[device.serial].map(describe) ?? (state.planLoadError[device.serial] ?? "none / not readable"))
                    row("Schedule on device", t?.touSchedule.map { s in s.map { "\($0.startHour)–\($0.endHour) \($0.tariff.short)" }.joined(separator: ", ") } ?? "not reported")
                    row("API response status", state.cloudSignedIn ? "signed in" : "signed out")
                    row("Device response", report?.steps.last.map { "\($0.name): \($0.detail)" } ?? "—")
                    row("Firmware", device.firmware ?? t?.firmware ?? "not reported")
                    row("Transport", (state.lastTransportUsed[device.serial] ?? device.activeTransports.first)?.label ?? "none")
                    row("Last successful change", state.lastSuccessfulChange[device.serial]?.formatted() ?? "none this session")
                    row("Last error", state.lastError[device.serial] ?? "none")
                }
                .font(.callout)
            }
            Card(title: "TOU troubleshooting", systemImage: "stethoscope") {
                HStack {
                    Button { Task { await state.runDiagnostics(serial: device.serial) } } label: { Label("Run 10 Checks", systemImage: "play.circle") }
                    Text("Read-only: queries state, sends nothing.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(state.diagnostics[device.serial] ?? []) { c in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(c.status)).foregroundStyle(color(c.status)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) { Text(c.title).font(.callout.weight(.medium)); Text(c.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Card(title: "Capabilities & protocol", systemImage: "list.clipboard") {
                let c = device.capabilities
                capRow("Bluetooth monitoring (protocol documented)", c.supportsBluetoothMonitoring, "SolixBLE; encrypted session not implemented here")
                capRow("Bluetooth control", false, "no TOU/mode commands over BLE")
                capRow("Local Wi-Fi monitoring / control", false, "no documented local API for this model")
                capRow("Cloud monitoring (MQTT)", c.supportsCloudMonitoring, "")
                capRow("Cloud control", c.supportsCloudControl, "")
                capRow("TOU", c.supportsTOU, "")
                capRow("TOU scheduling", c.supportsTOUScheduling, "")
                capRow("Reserve SOC", c.supportsReserveSOC, "")
                Text(device.profile?.touNote ?? "").font(.caption).foregroundStyle(.secondary)
                if let p = device.profile { Text("Sources: " + p.sources.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary) }
            }
            Card(title: "Protocol capture", systemImage: "waveform.path.ecg") {
                Text("Records every MQTT frame for this device and highlights the fields that changed between frames. Change the mode in the Anker app while this is open to see which bytes move — that is how undocumented commands (e.g. C1000 Gen 2 / F3800 Plus TOU) can be identified. Raw bytes stay on screen only and are omitted from exports.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(capturing ? "Stop Auto-refresh" : "Start Auto-refresh") { capturing.toggle() }
                    Button("Refresh") { Task { await reload() } }
                    Button("Clear") { Task { await state.backend.clearCapture(); frames = [] } }
                    Spacer(); Text("\(frames.count) frames").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(frames.reversed().prefix(120)) { f in
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(f.time.formatted(date: .omitted, time: .standard)) \(f.direction.rawValue) \(f.msgType)  \(f.note ?? "")  changed: \(f.changedFields.isEmpty ? "–" : f.changedFields.joined(separator: ","))")
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(f.changedFields.isEmpty ? Color.secondary : Color.orange)
                                Text(f.hex).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(height: 240)
            }
            Button { Task { await state.exportDiagnostics() } } label: { Label("Export Sanitized Diagnostic Log…", systemImage: "square.and.arrow.up") }
        }
        .task(id: capturing) {
            await reload()
            while capturing && !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000); await reload() }
        }
    }

    func reload() async { frames = (await state.backend.capturedFrames).filter { $0.serial == device.serial } }
    func row(_ k: String, _ v: String) -> some View { GridRow { Text(k).foregroundStyle(.secondary); Text(v).textSelection(.enabled) } }
    func describe(_ p: TOUPlan) -> String { p.orderedSlots.map { "\($0.startHour)–\($0.endHour) \($0.tariff.short)" }.joined(separator: ", ") + " · reserve \(p.reserveSOC)%" }
    func icon(_ s: CheckStatus) -> String { switch s { case .pass: "checkmark.circle.fill"; case .warn: "exclamationmark.triangle.fill"; case .fail: "xmark.octagon.fill"; case .unknown: "questionmark.circle" } }
    func color(_ s: CheckStatus) -> Color { switch s { case .pass: .green; case .warn: .orange; case .fail: .red; case .unknown: .gray } }
    func capRow(_ k: String, _ v: Bool, _ note: String) -> some View {
        HStack { Image(systemName: v ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(v ? .green : .secondary); Text(k).font(.callout); if !note.isEmpty { Text("— " + note).font(.caption).foregroundStyle(.secondary) } }
    }
}

struct AppDiagnosticsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connections & Logs").font(.title.weight(.semibold))
                Card(title: "Connection status", systemImage: "network") {
                    LabeledContent("Bluetooth") { Text(state.bluetooth.availability.rawValue) }
                    LabeledContent("Local network") { Text(state.lan.browsing ? "browsing" : "idle") }
                    LabeledContent("Anker cloud") { Text(state.cloudSignedIn ? "signed in" : "signed out") }
                    LabeledContent("MQTT live data") { Text(state.mqttConnected ? "connected" : "disconnected") }
                    LabeledContent("Mode") { Text(state.readOnly ? "read-only" : "changes enabled (each confirmed)") }
                    if let e = state.signInError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
                }
                Card(title: "Audit trail", systemImage: "list.bullet.clipboard") {
                    HStack {
                        Button("Refresh") { Task { await state.refreshAudit() } }
                        Button("Export Sanitized…") { Task { await state.exportDiagnostics() } }
                    }
                    ForEach(state.audit.prefix(150)) { a in
                        Text("\(a.timestamp.formatted(date: .abbreviated, time: .standard))  [\(a.category)]  \(a.message)")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    if state.audit.isEmpty { Text("Nothing logged yet.").foregroundStyle(.secondary) }
                }
            }
            .padding(20).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task { await state.refreshAudit() }
    }
}
