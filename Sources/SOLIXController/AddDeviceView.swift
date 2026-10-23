import SwiftUI
import SOLIXCore

struct AddDeviceView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    enum Method: String, CaseIterable, Identifiable { case account = "Anker Account", bluetooth = "Bluetooth", network = "Local Network"; var id: String { rawValue } }
    @State private var method: Method = .account

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Device").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(18)
            Picker("", selection: $method) { ForEach(Method.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            ScrollView {
                Group {
                    switch method {
                    case .account: AccountSignIn()
                    case .bluetooth: BluetoothDiscovery()
                    case .network: NetworkDiscovery()
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 600)
    }
}

struct AccountSignIn: View {
    @Environment(AppState.self) private var state
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with the Anker account that owns your batteries. Setting changes (TOU plan, mode) only work for the owner account; a shared/member account can monitor at most.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Email", text: $s.email).textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password)
                Picker("Country", selection: $s.country) {
                    ForEach(countries, id: \.0) { Text("\($0.1) (\($0.0))").tag($0.0) }
                }
                Toggle("Remember password in macOS Keychain", isOn: $remember)
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: 190)
            Text("The country selects Anker's regional server (US/Canada → ankerpower-api.anker.com). The password is end-to-end encrypted to Anker with an ECDH-derived key before sending, is never logged, and is only stored if you tick the Keychain box.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { await state.signIn(password: password, remember: remember); password = "" }
                } label: { Text(state.signingIn ? "Signing in…" : state.cloudSignedIn ? "Sign in again" : "Sign In") }
                .buttonStyle(.borderedProminent).disabled(state.email.isEmpty || password.isEmpty || state.signingIn)
                if state.cloudSignedIn { Button("Sign Out") { Task { await state.signOut() } } }
                if state.signingIn { ProgressView().controlSize(.small) }
            }
            if let e = state.signInError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            if state.cloudSignedIn {
                Label("Signed in — \(state.devices.count) device(s) found. MQTT live data: \(state.mqttConnected ? "connected" : "not connected").", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            }
        }
    }
    let countries = [("US", "United States"), ("CA", "Canada"), ("MX", "Mexico"), ("AU", "Australia"), ("DE", "Germany"), ("GB", "United Kingdom"), ("FR", "France"), ("IT", "Italy"), ("ES", "Spain"), ("NL", "Netherlands"), ("JP", "Japan")]
}

struct BluetoothDiscovery: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let bt = state.bluetooth
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Bluetooth: \(bt.availability.rawValue)", systemImage: "dot.radiowaves.left.and.right")
                Spacer()
                Button(bt.isScanning ? "Stop Scan" : "Start Scan") { bt.isScanning ? bt.stopScan() : bt.startScan() }
                    .disabled(bt.availability != .poweredOn)
            }
            if bt.availability == .unauthorized {
                Label("Bluetooth access is denied. Enable it in System Settings → Privacy & Security → Bluetooth.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text("Bluetooth discovery identifies models from the manufacturer record and lists GATT services. Telemetry over Bluetooth needs an encrypted session that is not implemented in this build, and there are no TOU commands over Bluetooth.")
                .font(.caption).foregroundStyle(.secondary)
            if bt.devices.isEmpty { Text(bt.isScanning ? "Scanning… make sure the battery is powered on and Bluetooth is enabled on it." : "No Anker devices found yet.").foregroundStyle(.secondary) }
            ForEach(bt.devices.values.sorted { $0.rssi > $1.rssi }) { d in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.name).font(.headline)
                            Text("\(d.modelGuess?.marketingName ?? (d.advertisement.map { "product \($0.productType) · sku \($0.sku)" } ?? "unknown model")) · RSSI \(d.rssi) dBm")
                                .font(.caption).foregroundStyle(.secondary)
                            if let a = d.advertisement { Text("MAC \(a.mac) · encrypted negotiation \(a.acceptsEncryptedNegotiation ? "supported" : "n/a")").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        if state.isAdded(d) {
                            Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                        } else {
                            Button("Add to My Devices") { state.addBluetoothDevice(d) }.buttonStyle(.borderedProminent)
                        }
                        Toggle("Auto-reconnect", isOn: Binding(get: { bt.trustedIdentifiers.contains(d.id) }, set: { state.trustBLE(d.id, $0) })).toggleStyle(.checkbox)
                        Button(d.connected ? "Disconnect" : d.connecting ? "Connecting…" : "Connect") { d.connected ? bt.disconnect(d.id) : bt.connect(d.id) }
                            .disabled(d.connecting)
                    }
                    if !d.services.isEmpty {
                        DisclosureGroup("GATT services (\(d.services.count))") {
                            ForEach(d.services) { s in
                                VStack(alignment: .leading) {
                                    Text(s.uuid).font(.system(.caption, design: .monospaced)).bold()
                                    ForEach(s.characteristics) { c in
                                        Text("  \(c.uuid)  [\(c.properties.joined(separator: ", "))]\(c.value.map { "  = \($0)" } ?? "")")
                                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }.font(.caption)
                    }
                }
                .padding(12).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
            if !bt.log.isEmpty {
                DisclosureGroup("Bluetooth log") { Text(bt.log.suffix(30).joined(separator: "\n")).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
            }
        }
    }
}

struct NetworkDiscovery: View {
    @Environment(AppState.self) private var state
    @State private var host = ""
    @State private var probing = false

    var body: some View {
        let lan = state.lan
        VStack(alignment: .leading, spacing: 12) {
            Label("No local API is documented for the C1000 Gen 2, C2000 Gen 2 or F3800 Plus. Only the X1 series has a documented local protocol (Modbus TCP, enabled via Anker's installer app). This tab can find Bonjour services and test whether an IP answers on common ports, but cannot read or control these batteries.", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(lan.browsing ? "Stop Browsing" : "Browse Bonjour (HTTP, Modbus)") { lan.browsing ? lan.stopBrowsing() : lan.startBrowsing() }
                if let e = lan.browserError { Text(e).font(.caption).foregroundStyle(.orange) }
            }
            ForEach(lan.hosts) { h in
                HStack { Image(systemName: h.isSolixLike ? "bolt.batteryblock" : "network"); Text(h.name); Spacer(); Text(h.type).font(.caption).foregroundStyle(.secondary) }
            }
            if lan.browsing && lan.hosts.isEmpty { Text("Nothing found yet.").foregroundStyle(.secondary) }
            Divider()
            Text("Manual IP address").font(.headline)
            HStack {
                TextField("192.168.1.50", text: $host).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Probe Ports 502 / 80 / 8080") { probing = true; Task { await lan.probeManual(host: host); probing = false } }
                    .disabled(host.isEmpty || probing)
                if probing { ProgressView().controlSize(.small) }
            }
            ForEach(lan.manualResults) { r in
                Label("\(r.host):\(r.port) — \(r.reachable ? "reachable" : "closed") (\(r.note))", systemImage: r.reachable ? "checkmark.circle" : "xmark.circle")
                    .font(.callout).foregroundStyle(r.reachable ? .green : .secondary)
            }
        }
    }
}
