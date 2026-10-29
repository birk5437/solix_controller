import SwiftUI
import AnkerCore

enum DeviceTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", mode = "Operating Mode", tou = "TOU Schedule", settings = "Settings", history = "History", diagnostics = "Diagnostics"
    var id: String { rawValue }
}

struct DeviceDetailView: View {
    @Environment(AppState.self) private var state
    let serial: String
    @State private var tab: DeviceTab = .dashboard

    var body: some View {
        if let device = state.device(serial) {
            VStack(spacing: 0) {
                header(device)
                Picker("", selection: $tab) {
                    ForEach(DeviceTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 10)
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .dashboard: DeviceDashboard(device: device)
                        case .mode: OperatingModeView(device: device)
                        case .tou: TOUEditor(device: device)
                        case .settings: DeviceSettingsView(device: device)
                        case .history: HistoryView(device: device)
                        case .diagnostics: DiagnosticsView(device: device)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(device.name)
        } else {
            ContentUnavailableView("Device not found", systemImage: "questionmark.circle")
        }
    }

    func header(_ d: SOLIXDevice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(.title.weight(.semibold))
                Text("\(d.profile?.marketingName ?? d.partNumber) · \(d.profile?.category.label ?? "") · \(d.partNumber)").foregroundStyle(.secondary)
            }
            Spacer()
            Label(d.status == .online ? "Online" : d.status == .connecting ? "Connecting" : d.status == .offline ? "Offline" : "No live data",
                  systemImage: "circle.fill")
                .labelStyle(.titleAndIcon).font(.callout)
                .foregroundStyle(d.status == .online ? .green : d.status == .offline ? .red : .secondary)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
    }
}

/// Small reusable card.
struct Card<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage ?? "").labelStyle(CardTitleStyle(hasIcon: systemImage != nil))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
struct CardTitleStyle: LabelStyle {
    let hasIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if hasIcon { configuration.icon.foregroundStyle(.secondary) }
            configuration.title.font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

struct Metric: View {
    let label: String; let value: String; var unit: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.weight(.semibold).monospacedDigit())
                if !unit.isEmpty { Text(unit).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}

func fmt(_ v: Double?, digits: Int = 0) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }
