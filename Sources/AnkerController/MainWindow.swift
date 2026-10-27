import SwiftUI
import AnkerCore

struct MainWindow: View {
    @Environment(AppState.self) private var state
    @State private var showAdd = false

    var body: some View {
        @Bindable var s = state
        NavigationSplitView {
            DeviceSidebar(showAdd: $showAdd)
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        } detail: {
            switch state.selection {
            case .device(let sn): DeviceDetailView(serial: sn).id(sn)
            case .automation: AutomationView()
            case .appDiagnostics: AppDiagnosticsView()
            case nil: EmptyState(showAdd: $showAdd)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $s.readOnly) {
                    Label(state.readOnly ? "Read-only" : "Changes enabled", systemImage: state.readOnly ? "lock.fill" : "lock.open.fill")
                }
                .toggleStyle(.button)
                .tint(state.readOnly ? .gray : .orange)
                .help(state.readOnly ? "Read-only mode: no command will be sent to any battery." : "Changes are enabled. Every change still asks for confirmation.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("Add Device", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { AddDeviceView().environment(state) }
        .sheet(item: Binding(get: { state.pendingConfirmation }, set: { if $0 == nil { state.resolveConfirmation(false) } })) { p in
            ConfirmationSheet(pending: p)
        }
    }
}

struct EmptyState: View {
    @Binding var showAdd: Bool
    var body: some View {
        ContentUnavailableView {
            Label("No devices yet", systemImage: "bolt.batteryblock")
        } description: {
            Text("Sign in with your Anker account or discover nearby batteries over Bluetooth.")
        } actions: {
            Button("Add Device…") { showAdd = true }.buttonStyle(.borderedProminent)
        }
    }
}

struct ConfirmationSheet: View {
    @Environment(AppState.self) private var state
    let pending: PendingConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Confirm change to battery settings", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.orange)
            Text("This will change how a physical energy-storage device operates. The previous schedule is saved first, and the result is read back from the device before it is reported as successful.")
                .font(.callout).foregroundStyle(.secondary)
            Text(pending.summary.text)
                .font(.system(.callout, design: .monospaced))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { state.resolveConfirmation(false) }.keyboardShortcut(.cancelAction)
                Button("Send Change") { state.resolveConfirmation(true) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22).frame(width: 520)
        .interactiveDismissDisabled()
    }
}

// MARK: - Sidebar

struct DeviceSidebar: View {
    @Environment(AppState.self) private var state
    @Binding var showAdd: Bool

    var body: some View {
        @Bindable var s = state
        List(selection: $s.selection) {
            Section("Devices") {
                ForEach(state.devices) { d in
                    DeviceRow(device: d, telemetry: state.telemetry[d.serial]).tag(SidebarSelection.device(d.serial))
                        .contextMenu { Button("Remove Device", role: .destructive) { state.removeDevice(d.serial) } }
                }
                if state.devices.isEmpty {
                    Text("No devices").foregroundStyle(.secondary)
                }
            }
            Section("App") {
                Label("Automation", systemImage: "clock.arrow.2.circlepath").tag(SidebarSelection.automation)
                Label("Connections & Logs", systemImage: "stethoscope").tag(SidebarSelection.appDiagnostics)
            }
        }
        .safeAreaInset(edge: .top) {
            if state.bluetooth.availability == .unauthorized || state.bluetooth.availability == .poweredOff {
                Label(state.bluetooth.availability == .unauthorized ? "Bluetooth not allowed — open Add Device → Bluetooth" : "Bluetooth is off",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { showAdd = true } label: { Label("Add Device", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                .controlSize(.large).buttonStyle(.bordered).padding(10)
        }
    }
}

struct StatusDot: View {
    let status: ConnectionStatus
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .accessibilityLabel(status.rawValue)
    }
    var color: Color {
        switch status { case .online: .green; case .connecting: .yellow; case .offline: .red; case .unknown: .gray }
    }
}

struct DeviceRow: View {
    let device: SOLIXDevice
    let telemetry: BatteryTelemetry?
    var body: some View {
        HStack(spacing: 10) {
            Gauge(value: (telemetry?.socPercent ?? 0) / 100) {
                EmptyView()
            } currentValueLabel: {
                Text(telemetry?.socPercent.map { "\(Int($0))" } ?? "–").font(.caption2.monospacedDigit())
            }
            .gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.75).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { StatusDot(status: device.status); Text(device.name).font(.headline).lineLimit(1) }
                Text(device.profile?.marketingName ?? device.partNumber).font(.caption).foregroundStyle(.secondary)
                Text(device.activeTransports.isEmpty ? "Not connected" : device.activeTransports.map(\.label).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}
