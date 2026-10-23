import SwiftUI
import SOLIXCore

struct DeviceSettingsView: View {
    @Environment(AppState.self) private var state
    let device: SOLIXDevice
    @State private var reserve: Double = 20

    var t: BatteryTelemetry? { state.telemetry[device.serial] }
    var supportsReserve: Bool { device.capabilities.supportsReserveSOC }
    var range: ClosedRange<Int> { let lo = (t?.minSOC ?? 0) + 5, hi = t?.maxSOC ?? 100; return lo <= hi ? lo...hi : 5...100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Connection preference", systemImage: "arrow.triangle.branch") {
                Picker("Preferred transport", selection: Binding(get: { device.preferredTransport }, set: { state.setPreferredTransport($0, serial: device.serial) })) {
                    Text("Automatic (Local Wi-Fi → Bluetooth → Cloud)").tag(TransportKind?.none)
                    ForEach(TransportKind.allCases) { Text($0.label).tag(TransportKind?.some($0)) }
                }
                Text("Automatic selection only uses a transport when its protocol is verified for this model and implemented here. Currently only the Anker cloud path (REST + MQTT) is usable; Bluetooth and local Wi-Fi are listed in Diagnostics with the exact reason.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "Backup reserve", systemImage: "battery.25") {
                if supportsReserve {
                    HStack {
                        Slider(value: $reserve, in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)), step: 1).frame(maxWidth: 340)
                        Text("\(Int(reserve))%").monospacedDigit().frame(width: 44)
                        Button("Apply…") { Task { await state.setReserve(Int(reserve), serial: device.serial) } }
                            .disabled(state.busy.contains(device.serial) || !state.mqttConnected)
                    }
                    Text("Device reports \(t?.backupSOC.map { "\($0)%" } ?? "—"). Accepted range \(range.lowerBound)–\(range.upperBound)%. The change is only reported as successful after the device echoes the new value.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Unsupported(text: device.profile?.touNote ?? "Unknown model.")
                }
            }
            .onAppear { reserve = Double(t?.backupSOC ?? range.lowerBound) }
            Card(title: "Reported by the device (read-only)", systemImage: "eye") {
                LabeledContent("Minimum SOC") { Text(t?.minSOC.map { "\($0)%" } ?? "not reported") }
                LabeledContent("Maximum SOC") { Text(t?.maxSOC.map { "\($0)%" } ?? "not reported") }
                LabeledContent("AC input") { Text(acText) }
                LabeledContent("Temperature") { Text(t?.temperatureC.map { "\(Int($0)) °C" } ?? "not reported") }
            }
            Card(title: "Not available in this build", systemImage: "nosign") {
                Unsupported(text: "AC/DC output switches, AC charge limit, display, light and timeouts — described for these models in the reference MQTT maps (anker-solix-api, message groups 0101–0103) but intentionally not implemented yet. They are not shown as controls because they cannot be driven from here.")
                Unsupported(text: "Grid-charging on/off: the AC charge limit exists on the device, but charging from the grid in TOU mode is decided by the device from the off-peak ranges; there is no separate documented switch.")
                Unsupported(text: "Weekday/weekend and seasonal schedules: not part of the PPS TOU plan.")
            }
        }
    }

    var acText: String {
        switch t?.acPlugStatus { case 0: "Disconnected"; case 1: "Connected"; case 2: "Disabled (battery-only)"; default: "not reported" }
    }
}

struct Unsupported: View {
    let text: String
    var body: some View { Label(text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

struct HistoryView: View {
    @Environment(AppState.self) private var state
    let device: SOLIXDevice
    @State private var hours: Double = 24

    var points: [HistoryPoint] { (state.history[device.serial] ?? []).filter { $0.time >= Date().addingTimeInterval(-hours * 3600) } }

    /// Trapezoidal energy integration, ignoring gaps larger than 15 minutes (app closed / offline).
    func energyWh(_ key: KeyPath<HistoryPoint, Double?>) -> Double {
        var total = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let dt = b.time.timeIntervalSince(a.time)
            guard dt > 0, dt <= 900, let x = a[keyPath: key], let y = b[keyPath: key] else { continue }
            total += (x + y) / 2 * dt / 3600
        }
        return total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Range", selection: $hours) {
                Text("1 h").tag(1.0); Text("6 h").tag(6.0); Text("24 h").tag(24.0); Text("7 days").tag(168.0)
            }.pickerStyle(.segmented).frame(width: 320)
            .onChange(of: hours) { _, h in Task { await state.loadHistory(hours: h) } }
            HStack(spacing: 16) {
                Card(title: "Energy in", systemImage: "arrow.down.circle") { Metric(label: "\(Int(hours)) h", value: String(format: "%.0f", energyWh(\.inputW)), unit: "Wh") }
                Card(title: "Energy out", systemImage: "arrow.up.circle") { Metric(label: "\(Int(hours)) h", value: String(format: "%.0f", energyWh(\.outputW)), unit: "Wh") }
                Card(title: "Samples", systemImage: "number") { Metric(label: "stored", value: "\(points.count)") }
            }
            Card(title: "Battery state of charge", systemImage: "battery.75") { SOCChart(points: points).frame(height: 190) }
            Card(title: "Charging / discharging power", systemImage: "bolt") { PowerChart(points: points).frame(height: 190) }
            Card(title: "Operating mode", systemImage: "switch.2") { ModeChart(points: points).frame(height: 110) }
            Text("Samples are stored locally at most once a minute while the app is running; there is no history for times the app was closed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await state.loadHistory(hours: hours) }
    }
}

import Charts
struct ModeChart: View {
    let points: [HistoryPoint]
    var body: some View {
        Chart(points.filter { $0.mode != nil }) {
            LineMark(x: .value("Time", $0.time), y: .value("Mode", $0.mode ?? 0)).interpolationMethod(.stepEnd)
        }
        .chartYAxis { AxisMarks(values: [0, 1, 2, 3]) { v in AxisGridLine(); AxisValueLabel { Text(UsageMode(rawValue: v.as(Int.self) ?? 0)?.label ?? "") } } }
        .overlay { if points.allSatisfy({ $0.mode == nil }) { Text("This model does not report an operating mode").foregroundStyle(.secondary) } }
    }
}
