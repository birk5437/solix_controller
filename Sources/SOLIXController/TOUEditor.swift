import SwiftUI
import SOLIXCore

extension Tariff {
    var color: Color { switch self { case .peak: .orange; case .mid: .gray; case .offPeak: .green } }
    var symbol: String { switch self { case .peak: "arrow.up.right"; case .mid: "minus"; case .offPeak: "arrow.down.left" } }
    var short: String { switch self { case .peak: "Peak"; case .mid: "Mid"; case .offPeak: "Off-peak" } }
}

struct TOUEditor: View {
    @Environment(AppState.self) private var state
    let device: SOLIXDevice

    var supported: Bool { device.capabilities.supportsTOUScheduling }
    var plan: TOUPlan { state.editedPlans[device.serial] ?? TOUPlan.defaultPlan }
    var stored: TOUPlan? { state.storedPlans[device.serial] }
    var tel: BatteryTelemetry? { state.telemetry[device.serial] }
    var reserveRange: ClosedRange<Int> {
        let lo = (tel?.minSOC ?? 0) + 5, hi = tel?.maxSOC ?? 100
        return lo <= hi ? lo...hi : 5...100
    }
    var dirty: Bool { stored.map { !$0.sameSchedule(as: plan.slots) || $0.reserveSOC != plan.reserveSOC || $0.prices != plan.prices } ?? true }

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 16) {
            if !supported {
                Card(title: "TOU control unavailable for this model", systemImage: "lock.slash") {
                    Text(device.profile?.touNote ?? "This model is not in the verified registry.").font(.callout)
                    Text("The editor below is shown read-only so you can see what the cloud stores, but nothing can be sent. Use Diagnostics → Protocol Capture while changing TOU in the Anker app to help document the commands.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if tel?.batteryOnlySwitch == 1 {
                Card(title: "AC input is disabled", systemImage: "exclamationmark.triangle.fill") {
                    Text("The battery reports Battery-Only Power ON, so TOU will not run and activation is blocked. Go to Settings → AC input → Allow AC Input.").font(.callout)
                }
            }
            stageCard
            Card(title: "24-hour schedule", systemImage: "calendar.day.timeline.leading") {
                Timeline(plan: plan, currentHour: Calendar.current.component(.hour, from: Date()))
                    .frame(height: 64)
                HStack(spacing: 14) {
                    ForEach(Tariff.allCases) { t in
                        HStack(spacing: 5) { Image(systemName: t.symbol).foregroundStyle(t.color); Text(t.label).font(.caption) }
                    }
                }
                Text("Same schedule every day. PPS TOU plans have no weekday/weekend or seasonal variants (those exist only on Solarbank 2 AC / 3).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "Time ranges", systemImage: "list.bullet.rectangle") {
                ForEach(Array(plan.orderedSlots.enumerated()), id: \.offset) { i, slot in
                    HStack {
                        Text(String(format: "%02d:00", slot.startHour)).font(.body.monospacedDigit()).frame(width: 52, alignment: .leading)
                        Text("→").foregroundStyle(.secondary)
                        if i < plan.orderedSlots.count - 1 {
                            Picker("End", selection: Binding(get: { slot.endHour }, set: { v in mutate { $0.setEnd(ofSlot: i, to: v) } })) {
                                ForEach(max(slot.startHour + 1, 1)...max(plan.orderedSlots[i + 1].endHour - 1, slot.startHour + 1), id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                            }
                            .labelsHidden().frame(width: 90)
                        } else {
                            Text("24:00").font(.body.monospacedDigit()).frame(width: 90, alignment: .leading)
                        }
                        Picker("Tariff", selection: Binding(get: { slot.tariff }, set: { v in mutate { $0.setTariff(ofSlot: i, to: v) } })) {
                            ForEach(Tariff.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }
                        .labelsHidden().frame(width: 190)
                        Spacer()
                        Button { mutate { $0.removeSlot(i) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(plan.slots.count <= 1 || !supported)
                    }
                    .disabled(!supported)
                }
                HStack {
                    Button { mutate { $0.splitLongestSlot() } } label: { Label("Add Range", systemImage: "plus.circle") }
                        .disabled(!plan.canAddSlot || !supported)
                    Text("\(plan.slots.count) of \(TOUPlan.maxSlots) ranges").font(.caption).foregroundStyle(.secondary)
                }
            }
            Card(title: "Prices & reserve", systemImage: "dollarsign.circle") {
                HStack {
                    Text("Currency symbol")
                    TextField("$", text: Binding(get: { plan.currencyUnit }, set: { v in mutate { $0.currencyUnit = String(v.prefix(3)) } }))
                        .frame(width: 60).textFieldStyle(.roundedBorder)
                }
                ForEach(Array(Set(plan.slots.map(\.tariff))).sorted { $0.rawValue < $1.rawValue }) { t in
                    HStack {
                        Label(t.label, systemImage: t.symbol).foregroundStyle(t.color).frame(width: 190, alignment: .leading)
                        TextField("price per kWh", text: Binding(get: { plan.prices.first { $0.tariff == t }?.price ?? "0" }, set: { v in
                            mutate { p in
                                if let i = p.prices.firstIndex(where: { $0.tariff == t }) { p.prices[i].price = v } else { p.prices.append(TOUPrice(tariff: t, price: v)) }
                            }
                        }))
                        .frame(width: 100).textFieldStyle(.roundedBorder)
                        Text("per kWh").foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack {
                    Text("Backup reserve").frame(width: 190, alignment: .leading)
                    Slider(value: Binding(get: { Double(plan.reserveSOC) }, set: { v in mutate { $0.reserveSOC = Int(v) } }),
                           in: Double(reserveRange.lowerBound)...Double(max(reserveRange.upperBound, reserveRange.lowerBound + 1)), step: 1)
                        .frame(maxWidth: 320)
                    Text("\(plan.reserveSOC)%").monospacedDigit().frame(width: 44)
                }
                Text("Discharge stops at the reserve while TOU is active. The device accepts \(reserveRange.lowerBound)–\(reserveRange.upperBound)% (min SOC + 5 … max SOC).")
                    .font(.caption).foregroundStyle(.secondary)
                if state.readOnly { Text("Read-only mode is on.").font(.caption).foregroundStyle(.orange) }
            }
            .disabled(!supported)

            let issues = plan.validate(reserveRange: reserveRange)
            if !issues.isEmpty {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, i in Label(i.description, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            }
            if let e = state.planLoadError[device.serial] {
                Label("Could not read the stored plan: \(e)", systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
            }

            HStack {
                Button { Task { await state.loadStoredPlan(device.serial); state.editedPlans[device.serial] = state.storedPlans[device.serial] ?? plan } } label: { Label("Reload from Device", systemImage: "arrow.clockwise") }
                Button { Task { await state.restorePreviousPlan(serial: device.serial) } } label: { Label("Restore Previous Plan", systemImage: "clock.arrow.circlepath") }
                Spacer()
                Button { Task { await state.savePlan(serial: device.serial) } } label: { Label("Save Schedule…", systemImage: "square.and.arrow.down") }
                    .disabled(!supported || !issues.isEmpty || state.busy.contains(device.serial))
                Button { Task { await state.setMode(.timeOfUse, serial: device.serial) } } label: { Label("Activate TOU…", systemImage: "bolt.badge.clock") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!supported || !issues.isEmpty || state.busy.contains(device.serial))
                Button { Task { await state.setMode(.standard, serial: device.serial) } } label: { Label("Disable TOU…", systemImage: "power") }
                    .disabled(!supported || state.busy.contains(device.serial))
            }
            if state.busy.contains(device.serial) { ProgressView("Working — waiting for the device to confirm…").controlSize(.small) }
            if let r = state.reports[device.serial] { ReportCard(report: r) }
        }
        .task { if state.storedPlans[device.serial] == nil { await state.loadStoredPlan(device.serial) } }
    }

    func mutate(_ f: (inout TOUPlan) -> Void) {
        var p = plan; f(&p); state.editedPlans[device.serial] = p
    }

    var stageCard: some View {
        let r = state.reports[device.serial]
        return Card(title: "Configuration state", systemImage: "checklist") {
            HStack(spacing: 8) {
                stage("Edited locally", active: dirty, done: !dirty || r != nil, color: .gray)
                arrow
                stage("Submitted", active: r?.planStage == .submitted, done: [.submitted, .accepted, .verified].contains(r?.planStage), color: .blue)
                arrow
                stage("Accepted", active: r?.planStage == .accepted, done: [.accepted, .verified].contains(r?.planStage) || (r?.modeStage == .verified), color: .teal)
                arrow
                stage("Verified on device", active: r?.modeStage == .verified, done: r?.modeStage == .verified, color: .green)
            }
            Text(dirty ? "You have unsaved edits that differ from what the cloud stores." : "The editor matches the plan stored in the cloud.")
                .font(.caption).foregroundStyle(.secondary)
            if let r, r.planStage == .failed || r.modeStage == .failed { Text("Last attempt failed: \(r.summary)").font(.callout).foregroundStyle(.red) }
        }
    }
    var arrow: some View { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
    func stage(_ name: String, active: Bool, done: Bool, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: done ? "checkmark.circle.fill" : active ? "circle.dotted" : "circle")
            Text(name).font(.callout.weight(done || active ? .semibold : .regular))
        }
        .foregroundStyle(done || active ? color : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 5).background((done || active ? color : Color.gray).opacity(0.12), in: Capsule())
    }
}

struct Timeline: View {
    let plan: TOUPlan
    let currentHour: Int
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(plan.orderedSlots.enumerated()), id: \.offset) { _, s in
                    RoundedRectangle(cornerRadius: 4).fill(s.tariff.color.opacity(0.75))
                        .overlay(HStack(spacing: 4) { Image(systemName: s.tariff.symbol); if (s.endHour - s.startHour) >= 3 { Text(s.tariff.short) } }
                            .font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1))
                        .frame(width: max(w * CGFloat(s.endHour - s.startHour) / 24 - 2, 2), height: 34)
                        .offset(x: w * CGFloat(s.startHour) / 24)
                }
                ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                    Text(String(format: "%02d", h)).font(.caption2).foregroundStyle(.secondary)
                        .offset(x: w * CGFloat(h) / 24 - (h == 24 ? 12 : h == 0 ? 0 : 6), y: 40)
                }
                Rectangle().fill(.primary).frame(width: 2, height: 42).offset(x: w * CGFloat(currentHour) / 24 + w / 48 - 1, y: -4)
            }
        }
        .accessibilityLabel("24-hour tariff schedule")
    }
}
