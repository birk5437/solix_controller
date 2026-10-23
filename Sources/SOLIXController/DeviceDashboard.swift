import SwiftUI
import Charts
import SOLIXCore

struct DeviceDashboard: View {
    @Environment(AppState.self) private var state
    let device: SOLIXDevice

    var t: BatteryTelemetry? { state.telemetry[device.serial] }
    var capacity: Int { device.profile?.capacityWh ?? 0 }

    var body: some View {
        VStack(spacing: 16) {
            if t == nil {
                Card(title: "Waiting for live data", systemImage: "antenna.radiowaves.left.and.right") {
                    Text(waitingText).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                Card(title: "Battery", systemImage: "battery.100") {
                    HStack(spacing: 18) {
                        Gauge(value: (t?.socPercent ?? 0) / 100) {
                            Text("SOC")
                        } currentValueLabel: {
                            Text(t?.socPercent.map { "\(Int($0))%" } ?? "–").font(.title3.weight(.semibold).monospacedDigit())
                        }
                        .gaugeStyle(.accessoryCircularCapacity).scaleEffect(1.6).frame(width: 90, height: 90)
                        VStack(alignment: .leading, spacing: 10) {
                            Metric(label: "Capacity", value: "\(capacity)", unit: "Wh")
                            Metric(label: "Stored (est.)", value: t?.socPercent.map { String(format: "%.0f", Double(capacity) * $0 / 100) } ?? "–", unit: "Wh")
                        }
                    }
                }
                Card(title: "Power", systemImage: "bolt.fill") {
                    HStack(spacing: 22) {
                        Metric(label: "Input", value: fmt(t?.inputPowerW), unit: "W")
                        Metric(label: "Output", value: fmt(t?.outputPowerW), unit: "W")
                        Metric(label: (t?.netChargingW ?? 0) >= 0 ? "Charging" : "Discharging", value: fmt(t?.netChargingW.map(abs)), unit: "W")
                    }
                    Divider()
                    HStack(spacing: 22) {
                        Metric(label: "AC in", value: fmt(t?.acInputW), unit: "W")
                        Metric(label: "Solar / DC in", value: fmt(t?.dcInputW), unit: "W")
                        Metric(label: "AC out", value: fmt(t?.acOutputW), unit: "W")
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                Card(title: "Status", systemImage: "info.circle") {
                    LabeledContent("Operating mode") { Text(modeText) }
                    LabeledContent("Estimated runtime") { Text(runtimeText) }
                    LabeledContent("AC input") { Text(acInputText).foregroundStyle(t?.batteryOnlySwitch == 1 ? .red : .primary) }
                    LabeledContent("Temperature") { Text(t?.temperatureC.map { String(format: "%.0f °C", $0) } ?? "–") }
                    LabeledContent("Firmware") { Text(device.firmware ?? t?.firmware ?? "not reported") }
                    LabeledContent("Connection") { Text(device.activeTransports.isEmpty ? "None" : device.activeTransports.map(\.label).joined(separator: ", ")) }
                    LabeledContent("Last update") { Text(t.map { $0.timestamp.formatted(date: .omitted, time: .standard) } ?? "–") }
                }
                Card(title: "Last 6 hours", systemImage: "chart.xyaxis.line") {
                    SOCChart(points: recent).frame(height: 150)
                }
            }
            Card(title: "Power (last 6 hours)", systemImage: "chart.line.uptrend.xyaxis") {
                PowerChart(points: recent).frame(height: 170)
            }
        }
    }

    var recent: [HistoryPoint] {
        let cut = Date().addingTimeInterval(-6 * 3600)
        return (state.history[device.serial] ?? []).filter { $0.time >= cut }
    }

    var acInputText: String {
        if t?.batteryOnlySwitch == 1 || t?.acPlugStatus == 2 { return "Disabled — Battery-Only ON" }
        switch t?.acPlugStatus {
        case 1: return "Connected"
        case 0: return "Disconnected"
        default: return t?.acInputW.map { $0 > 0 ? "\(Int($0)) W flowing" : "none flowing" } ?? "not reported"
        }
    }

    var modeText: String {
        guard let m = t?.usageMode else { return device.profile?.capabilities.supportsTOU == true ? "not reported yet" : "not reported by this model" }
        return UsageMode(rawValue: m)?.label ?? "code \(m)"
    }

    var runtimeText: String {
        guard let h = t?.estimatedRuntimeHours(capacityWh: capacity) else { return "not discharging" }
        return h >= 1 ? String(format: "%.1f h", h) : String(format: "%.0f min", h * 60)
    }

    var waitingText: String {
        if let id = device.bleIdentifier, let st = state.bluetooth.sessionStatus[id] {
            let cloudHint = device.isBluetoothOnly ? " (Bluetooth cannot change TOU or modes; sign in to the Anker cloud for that.)" : ""
            return "Bluetooth: \(st)\(cloudHint)"
        }
        if device.isBluetoothOnly {
            return "Waiting for the Bluetooth connection. Keep the battery powered on and in range; the connection retries automatically."
        }
        if !state.cloudSignedIn { return "Sign in to the Anker cloud (Add Device → Anker Account). Live data for \(device.partNumber) arrives over Anker's MQTT service; Bluetooth telemetry needs an encrypted session that this build does not implement yet." }
        if !state.mqttConnected { return "Signed in, but the MQTT live-data channel is not connected. See Connections & Logs." }
        return "Connected. The battery publishes real-time data only after a trigger, which is re-sent every 50 seconds. It can take up to a minute for the first frame."
    }
}

struct SOCChart: View {
    let points: [HistoryPoint]
    var body: some View {
        Chart(points.filter { $0.soc != nil }) {
            LineMark(x: .value("Time", $0.time), y: .value("SOC", $0.soc ?? 0)).interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { AxisGridLine(); AxisValueLabel("\($0.as(Int.self) ?? 0)%") } }
        .overlay { if points.isEmpty { Text("No data yet").foregroundStyle(.secondary) } }
    }
}

struct PowerChart: View {
    let points: [HistoryPoint]
    var body: some View {
        Chart {
            ForEach(points.filter { $0.inputW != nil }) { LineMark(x: .value("Time", $0.time), y: .value("W", $0.inputW ?? 0), series: .value("Series", "Input")).foregroundStyle(by: .value("Series", "Input")) }
            ForEach(points.filter { $0.outputW != nil }) { LineMark(x: .value("Time", $0.time), y: .value("W", $0.outputW ?? 0), series: .value("Series", "Output")).foregroundStyle(by: .value("Series", "Output")) }
        }
        .chartForegroundStyleScale(["Input": Color.green, "Output": Color.orange])
        .chartYAxisLabel("W")
        .overlay { if points.isEmpty { Text("No data yet").foregroundStyle(.secondary) } }
    }
}
