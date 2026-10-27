import SwiftUI
import AnkerCore

struct AutomationView: View {
    @Environment(AppState.self) private var state
    @State private var editing: AutomationRule?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Automation").font(.title.weight(.semibold))
                    Spacer()
                    Button { editing = newRule() } label: { Label("New Rule", systemImage: "plus") }
                        .disabled(state.devices.isEmpty)
                }
                Card(title: "Mac-managed vs. native", systemImage: "info.circle") {
                    Text("These rules run only while this app is open and the Mac is awake and online. They are separate from the battery's native TOU schedule, which keeps running on the device by itself. A rule that switches a battery out of TOU mode will override its native schedule until another rule or you switch it back.")
                        .font(.callout)
                    Text("Creating a rule is your standing confirmation for that change. Rules never run in read-only mode, and each run is verified against the device and logged. Times follow this Mac's time zone, including daylight-saving changes; a rule missed by more than 5 minutes (e.g. Mac asleep) is skipped rather than run late.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let conflicts = AutomationValidator.conflicts(state.rules)
                ForEach(conflicts, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                Card(title: "Rules", systemImage: "list.bullet") {
                    if state.rules.isEmpty { Text("No rules yet.").foregroundStyle(.secondary) }
                    ForEach(state.rules) { r in
                        HStack {
                            Toggle("", isOn: Binding(get: { r.enabled }, set: { v in if let i = state.rules.firstIndex(where: { $0.id == r.id }) { state.rules[i].enabled = v; state.persistRules() } })).labelsHidden()
                            VStack(alignment: .leading) {
                                Text(r.name).font(.headline)
                                Text("\(state.device(r.serial)?.name ?? r.serial) · \(String(format: "%02d:%02d", r.hour, r.minute)) · \(days(r.weekdays)) · \(r.action.label)").font(.caption).foregroundStyle(.secondary)
                                if let next = AutomationScheduler.nextFire(of: r, after: Date()) { Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.tertiary) }
                            }
                            Spacer()
                            Button("Edit") { editing = r }
                            Button(role: .destructive) { state.rules.removeAll { $0.id == r.id }; state.persistRules() } label: { Image(systemName: "trash") }
                        }
                        Divider()
                    }
                }
                Card(title: "Run log", systemImage: "clock") {
                    if state.automationLog.isEmpty { Text("Nothing has run yet.").foregroundStyle(.secondary) }
                    ForEach(state.automationLog.prefix(50), id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                }
            }
            .padding(20).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(item: $editing) { r in RuleEditor(rule: r) { saved in
            if let i = state.rules.firstIndex(where: { $0.id == saved.id }) { state.rules[i] = saved } else { state.rules.append(saved) }
            state.persistRules()
        }.environment(state) }
    }

    func newRule() -> AutomationRule {
        AutomationRule(name: "New rule", serial: state.devices.first?.serial ?? "", hour: 0, minute: 0, action: .setUsageMode(.standard))
    }
    func days(_ d: Set<Int>) -> String {
        d.count == 7 ? "daily" : d.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")
    }
}

struct RuleEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var rule: AutomationRule
    var onSave: (AutomationRule) -> Void
    @State private var kind = 0
    @State private var mode: UsageMode = .standard
    @State private var soc = 20

    var issues: [String] {
        var r = rule; r.action = kind == 0 ? .setUsageMode(mode) : .setBackupSOC(soc)
        var all = AutomationValidator.validate(r, profile: state.device(r.serial)?.profile)
        all += AutomationValidator.conflicts(state.rules.filter { $0.id != r.id } + [r])
        return all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automation Rule").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $rule.name)
                Picker("Device", selection: $rule.serial) { ForEach(state.devices) { Text($0.name).tag($0.serial) } }
                Picker("Action", selection: $kind) { Text("Switch operating mode").tag(0); Text("Set backup reserve").tag(1) }
                if kind == 0 {
                    Picker("Mode", selection: $mode) { ForEach(UsageMode.allCases) { Text($0.label).tag($0) } }
                } else {
                    Stepper("Reserve: \(soc)%", value: $soc, in: 5...100)
                }
                HStack {
                    Stepper("Hour: \(rule.hour)", value: $rule.hour, in: 0...23)
                    Stepper("Minute: \(String(format: "%02d", rule.minute))", value: $rule.minute, in: 0...59)
                }
                HStack {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(Calendar.current.shortWeekdaySymbols[d - 1], isOn: Binding(get: { rule.weekdays.contains(d) }, set: { if $0 { rule.weekdays.insert(d) } else { rule.weekdays.remove(d) } })).toggleStyle(.button)
                    }
                }
            }.formStyle(.grouped)
            ForEach(issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Rule") { var r = rule; r.action = kind == 0 ? .setUsageMode(mode) : .setBackupSOC(soc); onSave(r); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(!issues.isEmpty)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear {
            switch rule.action { case .setUsageMode(let m): kind = 0; mode = m; case .setBackupSOC(let s): kind = 1; soc = s }
        }
    }
}
