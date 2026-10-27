import SwiftUI
import AnkerCore

struct OperatingModeView: View {
    @Environment(AppState.self) private var state
    let device: SOLIXDevice

    var current: Int? { state.telemetry[device.serial]?.usageMode }
    var settable: [UsageMode] { device.profile?.settableUsageModes ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Device-reported mode", systemImage: "gauge.with.dots.needle.33percent") {
                HStack {
                    Text(current.flatMap { UsageMode(rawValue: $0)?.label } ?? (current.map { "Code \($0)" } ?? "Not reported"))
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if let t = state.telemetry[device.serial]?.activeTariff, current == 1 {
                        Text(["None", "Peak", "Mid-peak", "Off-peak"][min(t, 3)] + " tariff now").foregroundStyle(.secondary)
                    }
                }
                if settable.isEmpty {
                    Label(device.profile?.touNote ?? "Unknown model: no verified protocol.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Card(title: "Modes", systemImage: "switch.2") {
                ForEach(UsageMode.allCases) { mode in
                    let can = settable.contains(mode)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(mode.label).font(.headline)
                                if current == mode.rawValue { Text("ACTIVE").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2).background(.green.opacity(0.25), in: Capsule()) }
                            }
                            Text(can ? description(mode) : unavailable(mode)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(current == mode.rawValue ? "Active" : "Switch…") { Task { await state.setMode(mode, serial: device.serial) } }
                            .disabled(!can || current == mode.rawValue || state.busy.contains(device.serial))
                    }
                    if mode != UsageMode.allCases.last { Divider() }
                }
            }
            if let r = state.reports[device.serial] { ReportCard(report: r) }
        }
    }

    func description(_ m: UsageMode) -> String {
        switch m {
        case .standard: "Normal UPS-style operation. The stored TOU plan is ignored."
        case .timeOfUse: "Charge during off-peak ranges, discharge during peak ranges, according to the TOU schedule. Runs on the battery itself; the Mac is not needed."
        default: ""
        }
    }

    func unavailable(_ m: UsageMode) -> String {
        guard device.profile != nil else { return "Unsupported: model is not in the verified registry." }
        if settable.isEmpty { return "Unavailable: no documented command for \(device.partNumber)." }
        return "Unavailable: the reference implementations only describe Standard and Time of Use for \(device.partNumber)."
    }
}

struct ReportCard: View {
    let report: TOUActivationReport
    var body: some View {
        Card(title: "Last attempt", systemImage: report.success ? "checkmark.seal.fill" : "xmark.octagon.fill") {
            Text(report.summary).font(.headline).foregroundStyle(report.success ? .green : .red)
            HStack(spacing: 8) {
                StageChip(label: "Plan", stage: report.planStage)
                StageChip(label: "Mode", stage: report.modeStage)
            }
            ForEach(report.steps) { s in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: s.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(s.ok ? .green : .red)
                    VStack(alignment: .leading) { Text(s.name).font(.callout.weight(.medium)); Text(s.detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
            ForEach(report.problems) { p in
                Label(p.detail, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
        }
    }
}

struct StageChip: View {
    let label: String; let stage: ConfigStage
    var color: Color { switch stage { case .verified: .green; case .accepted: .teal; case .submitted: .blue; case .edited: .gray; case .failed: .red } }
    var body: some View {
        Text("\(label): \(stage.rawValue)").font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3).background(color.opacity(0.2), in: Capsule())
    }
}
