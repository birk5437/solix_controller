import Foundation

/// What the TOU service needs from the outside world. Implemented by `CloudBackend`; mocked in tests.
public protocol TOUBackend: Sendable {
    var cloudSignedIn: Bool { get async }
    var mqttConnected: Bool { get async }
    /// Stored plan (`pps_use_time`). `nil` when the device has no plan attribute. Throws `CloudError.noPermission` for non-owners.
    func fetchCloudPlan(serial: String) async throws -> TOUPlan?
    func pushCloudPlan(serial: String, plan: TOUPlan) async throws
    func sendUsageMode(_ device: SOLIXDevice, mode: UsageMode) async throws
    func sendBackupSOC(_ device: SOLIXDevice, soc: Int) async throws
    func requestTelemetry(_ device: SOLIXDevice) async throws
    func latestTelemetry(serial: String) async -> BatteryTelemetry?
    /// Wait until `predicate` holds for a fresh telemetry frame (frames older than `since` are ignored).
    func awaitTelemetry(serial: String, since: Date, timeout: TimeInterval,
                        where predicate: @Sendable (BatteryTelemetry) -> Bool) async -> BatteryTelemetry?
}

public enum CheckStatus: String, Codable, Sendable { case pass, warn, fail, unknown }

public struct DiagnosticCheck: Identifiable, Hashable, Sendable {
    public var id: String { title }
    public var title: String
    public var status: CheckStatus
    public var detail: String
}

public enum ConfigStage: String, Codable, Sendable, CaseIterable {
    case edited = "Edited locally", submitted = "Submitted", accepted = "Accepted by cloud"
    case verified = "Verified on device", failed = "Failed"
}

public struct ActivationStep: Identifiable, Sendable, Hashable {
    public var id = UUID()
    public var time = Date()
    public var name: String
    public var ok: Bool
    public var detail: String
}

public struct TOUActivationReport: Sendable {
    public var requestedMode: UsageMode
    public var deviceReportedMode: Int?
    public var planStage: ConfigStage = .edited
    public var modeStage: ConfigStage = .edited
    public var steps: [ActivationStep] = []
    public var problems: [DiagnosticCheck] = []
    public var success = false
    public var summary = ""
    public var transport = TransportKind.cloud
    public mutating func add(_ name: String, _ ok: Bool, _ detail: String) {
        steps.append(ActivationStep(name: name, ok: ok, detail: detail))
    }
}

public struct ChangeSummary: Sendable {
    public var device: SOLIXDevice
    public var targetMode: UsageMode
    public var previousMode: Int?
    public var newPlan: TOUPlan?
    public var previousPlan: TOUPlan?
    public var newReserve: Int?
    public var previousReserve: Int?
    /// Plan/reserve change only; the operating mode is left untouched.
    public var modeUnchanged = false
    public var text: String {
        var l = ["Device: \(device.name) (\(device.partNumber))"]
        if !modeUnchanged {
            l.append("Operating mode: \(previousMode.flatMap(UsageMode.init(rawValue:))?.label ?? "unknown") → \(targetMode.label)")
        }
        if let p = newPlan {
            l.append("TOU plan will be replaced (previous plan is saved first):")
            for s in p.slots.sorted(by: { $0.startHour < $1.startHour }) {
                l.append(String(format: "  %02d:00–%02d:00  %@", s.startHour, s.endHour, s.tariff.label))
            }
        }
        if let r = newReserve { l.append("Backup reserve: \(previousReserve.map(String.init) ?? "?")% → \(r)%") }
        return l.joined(separator: "\n")
    }
}

public struct TOUService: Sendable {
    let backend: TOUBackend
    let verifyTimeout: TimeInterval
    let saveSnapshot: @Sendable (_ serial: String, _ kind: String, _ json: String) async -> Void
    let audit: @Sendable (_ serial: String, _ message: String) async -> Void

    public init(backend: TOUBackend, verifyTimeout: TimeInterval = 45,
                saveSnapshot: @escaping @Sendable (String, String, String) async -> Void = { _, _, _ in },
                audit: @escaping @Sendable (String, String) async -> Void = { _, _ in }) {
        self.backend = backend; self.verifyTimeout = verifyTimeout
        self.saveSnapshot = saveSnapshot; self.audit = audit
    }

    // MARK: Diagnostics

    /// The ten checks required for “why won't TOU turn on”. Statuses are `unknown` when the data to decide is not available.
    public func diagnose(device: SOLIXDevice, plan: TOUPlan?) async -> [DiagnosticCheck] {
        var out: [DiagnosticCheck] = []
        let profile = device.profile
        let tel = await backend.latestTelemetry(serial: device.serial)

        // 1. model support
        if let p = profile {
            out.append(.init(title: "1. Model supports TOU", status: p.capabilities.supportsTOU ? .pass : .fail,
                             detail: p.touNote))
        } else {
            out.append(.init(title: "1. Model supports TOU", status: .unknown, detail: "\(device.partNumber) is not in the verified model registry."))
        }

        // 2. firmware
        let fw = device.firmware ?? tel?.firmware
        if tel?.usageMode != nil {
            out.append(.init(title: "2. Firmware supports TOU", status: .pass,
                             detail: "Firmware \(fw ?? "?") reports a TOU/usage-mode block in its telemetry."))
        } else {
            out.append(.init(title: "2. Firmware supports TOU", status: .unknown,
                             detail: "Firmware \(fw ?? "unknown"). No reference documents a minimum firmware for TOU; the device has not reported a usage-mode field yet.\(await backend.mqttConnected ? "" : " (MQTT is not connected.)")"))
        }

        // 3. valid schedule (device-stored + the one being edited)
        var stored: TOUPlan?
        var permissionDetail: String?
        do { stored = try await backend.fetchCloudPlan(serial: device.serial) }
        catch let e as CloudError { permissionDetail = e.description } catch { permissionDetail = "\(error)" }
        let candidate = plan ?? stored
        if let c = candidate {
            let issues = c.validate(reserveRange: reserveRange(tel))
            out.append(.init(title: "3. A valid TOU schedule exists", status: issues.isEmpty ? .pass : .fail,
                             detail: issues.isEmpty ? "\(c.slots.count) range(s) covering 00:00–24:00." : issues.map(\.description).joined(separator: " ")))
        } else {
            out.append(.init(title: "3. A valid TOU schedule exists", status: permissionDetail == nil ? .fail : .unknown,
                             detail: permissionDetail ?? "The device has no stored TOU plan. Create one in the editor."))
        }

        // 4. tariff settings
        if let c = candidate {
            let used = Set(c.slots.map(\.tariff)); let priced = Set(c.prices.map(\.tariff))
            let missing = used.subtracting(priced)
            out.append(.init(title: "4. Tariff prices configured", status: missing.isEmpty ? .pass : .warn,
                             detail: missing.isEmpty ? "Prices set for every tariff in use (unit \(c.currencyUnit))."
                                : "No price for: \(missing.map(\.label).joined(separator: ", ")). The Anker app requires a price per tariff."))
        } else {
            out.append(.init(title: "4. Tariff prices configured", status: .unknown, detail: "No plan to inspect."))
        }

        // 5. conflicting mode
        if let m = tel?.usageMode {
            let conflict = m == 2 || m == 3
            out.append(.init(title: "5. No conflicting operating mode", status: conflict ? .warn : .pass,
                             detail: "Device reports mode: \(UsageMode(rawValue: m)?.label ?? "code \(m)")."
                                + (conflict ? " Switch to Standard or TOU explicitly." : "")))
        } else {
            out.append(.init(title: "5. No conflicting operating mode", status: .unknown, detail: "Device mode not received yet (needs MQTT telemetry)."))
        }

        // 6. grid charging availability
        if let plug = tel?.acPlugStatus {
            let text = ["AC input disconnected", "AC input connected", "AC input disabled (battery-only power on)"]
            out.append(.init(title: "6. Grid charging available", status: plug == 1 ? .pass : .warn,
                             detail: plug < text.count ? text[plug] : "AC plug status \(plug)"))
        } else {
            out.append(.init(title: "6. Grid charging available", status: .unknown, detail: "AC input status not received."))
        }

        // 7. reserve settings
        let rr = reserveRange(tel)
        if let c = candidate {
            let okR = rr.contains(c.reserveSOC)
            out.append(.init(title: "7. Reserve SOC valid", status: okR ? .pass : .fail,
                             detail: "Reserve \(c.reserveSOC)%; device accepts \(rr.lowerBound)–\(rr.upperBound)% (min SOC + 5 … max SOC)."))
        } else {
            out.append(.init(title: "7. Reserve SOC valid", status: .unknown, detail: "No plan."))
        }

        // 8. permission
        if let d = permissionDetail {
            out.append(.init(title: "8. Account may change settings", status: .fail, detail: d))
        } else if await backend.cloudSignedIn {
            out.append(.init(title: "8. Account may change settings", status: device.isOwner ? .pass : .warn,
                             detail: "Device attribute query succeeded (owner-only endpoint)."))
        } else {
            out.append(.init(title: "8. Account may change settings", status: .unknown, detail: "Not signed in to the Anker cloud."))
        }

        // 9. transport
        let cloud = await backend.cloudSignedIn, mqtt = await backend.mqttConnected
        out.append(.init(title: "9. Transport supports TOU commands",
                         status: cloud && mqtt ? .pass : .fail,
                         detail: "Plan is stored through cloud REST (\(cloud ? "signed in" : "NOT signed in")); the mode switch uses the Anker MQTT broker (\(mqtt ? "connected" : "NOT connected")). Bluetooth and local Wi-Fi have no documented TOU commands."))

        // 10. acceptance — only knowable after an attempt
        out.append(.init(title: "10. Device accepts the configuration", status: .unknown,
                         detail: "Determined during activation by reading the mode back from the device."))
        return out
    }

    func reserveRange(_ t: BatteryTelemetry?) -> ClosedRange<Int> {
        let lo = (t?.minSOC ?? 0) + 5, hi = t?.maxSOC ?? 100
        return lo <= hi ? lo...hi : 5...100
    }

    // MARK: Activation

    /// Full workflow: read → validate → confirm → write plan → read back → switch mode → verify on device.
    /// Never reports success from an accepted request alone.
    public func setMode(
        _ mode: UsageMode, on device: SOLIXDevice, plan: TOUPlan?, readOnly: Bool,
        confirm: @Sendable (ChangeSummary) async -> Bool
    ) async -> TOUActivationReport {
        var r = TOUActivationReport(requestedMode: mode)
        func fail(_ s: String) -> TOUActivationReport {
            r.success = false; r.summary = s
            if r.modeStage != .verified { r.modeStage = .failed }
            return r
        }
        guard let profile = device.profile, profile.capabilities.supportsTOU, profile.settableUsageModes.contains(mode) else {
            r.add("Support check", false, device.profile?.touNote ?? "Unknown model")
            return fail("This model's mode switch is not documented, so no command was sent.")
        }
        guard await backend.cloudSignedIn else { r.add("Cloud session", false, "Not signed in"); return fail("Sign in to the Anker cloud first.") }
        guard await backend.mqttConnected else { r.add("MQTT", false, "Not connected"); return fail("The device command channel (MQTT) is not connected.") }

        // 1. Read current configuration.
        let before = await backend.latestTelemetry(serial: device.serial)
        r.deviceReportedMode = before?.usageMode
        var storedPlan: TOUPlan?
        do { storedPlan = try await backend.fetchCloudPlan(serial: device.serial); r.add("Read stored plan", true, storedPlan.map { "\($0.slots.count) range(s)" } ?? "none") }
        catch { r.add("Read stored plan", false, "\(error)"); r.problems.append(.init(title: "Permission", status: .fail, detail: "\(error)")) }
        r.add("Read current mode", before?.usageMode != nil, before?.usageMode.map { UsageMode(rawValue: $0)?.label ?? "code \($0)" } ?? "no telemetry yet")

        // 2/3. Validate & surface problems.
        let targetPlan = (mode == .timeOfUse) ? (plan ?? storedPlan) : nil
        if mode == .timeOfUse {
            guard let p = targetPlan else {
                r.add("Validate", false, "No TOU plan exists")
                return fail("TOU needs a schedule. Create and save one first.")
            }
            let issues = p.validate(reserveRange: reserveRange(before))
            if !issues.isEmpty {
                for i in issues { r.problems.append(.init(title: "Plan", status: .fail, detail: i.description)) }
                r.add("Validate", false, issues.map(\.description).joined(separator: " "))
                return fail("The plan is invalid; nothing was sent.")
            }
            r.add("Validate", true, "Plan is consistent")
        }
        if readOnly { r.add("Read-only mode", false, "Changes disabled"); return fail("Read-only mode is on; nothing was sent.") }

        // 4. Confirm with the user.
        let planChanged = targetPlan.map { !($0.sameSchedule(as: storedPlan?.slots ?? []) && $0.reserveSOC == storedPlan?.reserveSOC && $0.prices == storedPlan?.prices && $0.currencyUnit == storedPlan?.currencyUnit) } ?? false
        let summary = ChangeSummary(device: device, targetMode: mode, previousMode: before?.usageMode,
                                    newPlan: planChanged ? targetPlan : nil, previousPlan: storedPlan,
                                    newReserve: (targetPlan?.reserveSOC).flatMap { $0 != before?.backupSOC ? $0 : nil },
                                    previousReserve: before?.backupSOC)
        guard await confirm(summary) else { r.add("Confirmation", false, "Declined"); return fail("Cancelled by user; nothing was sent.") }
        r.add("Confirmation", true, "User confirmed")
        await audit(device.serial, "Change confirmed: \(summary.text.replacingOccurrences(of: "\n", with: " | "))")

        // Preserve previous configuration before any overwrite.
        if planChanged, let prev = storedPlan, let json = try? prev.cloudJSONString() {
            await saveSnapshot(device.serial, "tou_plan", json)
            r.add("Preserve previous plan", true, "Saved snapshot")
        }

        // 5a. Plan (cloud REST). One attempt only.
        if planChanged, let p = targetPlan {
            r.planStage = .submitted
            do {
                try await backend.pushCloudPlan(serial: device.serial, plan: p)
                r.add("Submit plan", true, "Cloud returned success (this alone is not proof)")
                let back = try await backend.fetchCloudPlan(serial: device.serial)
                if let back, back.sameSchedule(as: p.slots), back.reserveSOC == p.reserveSOC {
                    r.planStage = .accepted; r.add("Read plan back", true, "Cloud now stores the submitted schedule")
                } else {
                    r.planStage = .failed; r.add("Read plan back", false, "Cloud returned a different plan than submitted")
                    return fail("The cloud accepted the request but stores a different plan. Mode was NOT changed.")
                }
            } catch {
                r.planStage = .failed; r.add("Submit plan", false, "\(error)")
                return fail("Plan upload failed: \(error). Mode was NOT changed.")
            }
        }

        // 5b. Reserve SOC (MQTT) if it differs from what the device reports.
        if mode == .timeOfUse, let p = targetPlan, p.reserveSOC != before?.backupSOC {
            let t0 = Date()
            do {
                try await backend.sendBackupSOC(device, soc: p.reserveSOC)
                try? await backend.requestTelemetry(device)
                let t = await backend.awaitTelemetry(serial: device.serial, since: t0, timeout: verifyTimeout) { $0.backupSOC == p.reserveSOC }
                r.add("Reserve SOC", t != nil, t != nil ? "Device reports \(p.reserveSOC)%" : "Device did not confirm \(p.reserveSOC)%")
                if t == nil { return fail("The device did not confirm the reserve SOC change. Mode was NOT changed.") }
            } catch { r.add("Reserve SOC", false, "\(error)"); return fail("Reserve SOC command failed: \(error)") }
        }

        // 6. Mode switch (MQTT) + read-back.
        r.modeStage = .submitted
        let t0 = Date()
        do { try await backend.sendUsageMode(device, mode: mode); r.add("Send mode command", true, "Published \(mode.label)") }
        catch { r.modeStage = .failed; r.add("Send mode command", false, "\(error)"); return fail("Mode command failed: \(error)") }
        try? await backend.requestTelemetry(device)
        let confirmed = await backend.awaitTelemetry(serial: device.serial, since: t0, timeout: verifyTimeout) { $0.usageMode == mode.rawValue }
        if let c = confirmed {
            r.deviceReportedMode = c.usageMode; r.modeStage = .verified
            r.add("Verify mode on device", true, "Device reports \(mode.label)")
            if mode == .timeOfUse, let p = targetPlan {
                if let slots = c.touSchedule {
                    let same = p.sameSchedule(as: slots)
                    r.planStage = same ? .verified : r.planStage
                    r.add("Verify schedule on device", same, same ? "Device schedule matches" : "Device reports a different schedule than the plan")
                    if !same { r.problems.append(.init(title: "Schedule mismatch", status: .warn, detail: "Mode is active but the device-side schedule differs from the stored plan.")) }
                    r.success = same
                    r.summary = same ? "TOU is active and the schedule is verified on the device." : "TOU mode is active, but the device schedule differs from the plan."
                } else {
                    r.success = true
                    r.summary = "TOU mode is active (device did not include its schedule in this frame)."
                }
            } else { r.success = true; r.summary = "\(mode.label) is active (verified from device telemetry)." }
        } else {
            let last = await backend.latestTelemetry(serial: device.serial)
            r.deviceReportedMode = last?.usageMode; r.modeStage = .failed
            r.add("Verify mode on device", false, "Device reports \(last?.usageMode.flatMap { UsageMode(rawValue: $0)?.label } ?? "nothing") after \(Int(verifyTimeout)) s")
            r.problems.append(.init(title: "Device did not confirm", status: .fail,
                                    detail: "The command was published but the device never reported \(mode.label). Check AC input/battery-only state, firmware, and use the Protocol Capture tab while toggling the mode in the Anker app to compare messages."))
            r.summary = "The device did not enter \(mode.label). No success is reported."
        }
        await audit(device.serial, "Mode \(mode.label): \(r.success ? "VERIFIED" : "NOT verified") — \(r.summary)")
        return r
    }

    // MARK: Plan-only and reserve-only changes

    /// Upload a plan without changing the operating mode, then read it back from the cloud.
    public func savePlan(_ plan: TOUPlan, on device: SOLIXDevice, readOnly: Bool,
                         confirm: @Sendable (ChangeSummary) async -> Bool) async -> TOUActivationReport {
        var r = TOUActivationReport(requestedMode: .timeOfUse)
        guard device.profile?.capabilities.supportsTOUScheduling == true else {
            r.add("Support check", false, device.profile?.touNote ?? "Unknown model")
            r.summary = "This model's TOU plan write is not documented, so nothing was sent."; r.planStage = .failed; return r
        }
        guard await backend.cloudSignedIn else { r.add("Cloud session", false, "Not signed in"); r.summary = "Sign in first."; r.planStage = .failed; return r }
        let tel = await backend.latestTelemetry(serial: device.serial)
        let issues = plan.validate(reserveRange: reserveRange(tel))
        if !issues.isEmpty {
            r.add("Validate", false, issues.map(\.description).joined(separator: " "))
            r.problems = issues.map { .init(title: "Plan", status: .fail, detail: $0.description) }
            r.summary = "The plan is invalid; nothing was sent."; r.planStage = .failed; return r
        }
        if readOnly { r.add("Read-only mode", false, "Changes disabled"); r.summary = "Read-only mode is on; nothing was sent."; r.planStage = .failed; return r }
        var stored: TOUPlan?
        do { stored = try await backend.fetchCloudPlan(serial: device.serial); r.add("Read stored plan", true, stored.map { "\($0.slots.count) range(s)" } ?? "none") }
        catch { r.add("Read stored plan", false, "\(error)"); r.summary = "\(error)"; r.planStage = .failed; return r }
        var summary = ChangeSummary(device: device, targetMode: .timeOfUse, previousMode: tel?.usageMode, newPlan: plan,
                                    previousPlan: stored, newReserve: nil, previousReserve: tel?.backupSOC)
        summary.modeUnchanged = true
        guard await confirm(summary) else { r.add("Confirmation", false, "Declined"); r.summary = "Cancelled by user; nothing was sent."; r.planStage = .failed; return r }
        r.add("Confirmation", true, "User confirmed")
        await audit(device.serial, "Plan save confirmed: \(summary.text.replacingOccurrences(of: "\n", with: " | "))")
        if let prev = stored, let json = try? prev.cloudJSONString() { await saveSnapshot(device.serial, "tou_plan", json); r.add("Preserve previous plan", true, "Saved snapshot") }
        r.planStage = .submitted
        do {
            try await backend.pushCloudPlan(serial: device.serial, plan: plan)
            r.add("Submit plan", true, "Cloud returned success (not yet proof)")
            let back = try await backend.fetchCloudPlan(serial: device.serial)
            if let back, back.sameSchedule(as: plan.slots), back.reserveSOC == plan.reserveSOC, back.prices == plan.prices {
                r.planStage = .accepted; r.success = true
                r.add("Read plan back", true, "Cloud stores the submitted plan")
                r.summary = "Plan saved and read back from the cloud. It becomes active on the device when TOU mode is on."
            } else {
                r.planStage = .failed; r.add("Read plan back", false, "Cloud returned a different plan")
                r.summary = "The cloud accepted the request but stores a different plan."
            }
        } catch { r.planStage = .failed; r.add("Submit plan", false, "\(error)"); r.summary = "Plan upload failed: \(error)" }
        await audit(device.serial, "Plan save: \(r.success ? "read back OK" : "FAILED") — \(r.summary)")
        return r
    }

    /// Change the backup reserve over MQTT and verify it from telemetry.
    public func setReserve(_ soc: Int, on device: SOLIXDevice, readOnly: Bool,
                           confirm: @Sendable (ChangeSummary) async -> Bool) async -> TOUActivationReport {
        var r = TOUActivationReport(requestedMode: .timeOfUse)
        guard device.profile?.capabilities.supportsReserveSOC == true else {
            r.add("Support check", false, device.profile?.touNote ?? "Unknown model"); r.summary = "Reserve control is not documented for this model."; return r
        }
        guard await backend.mqttConnected else { r.add("MQTT", false, "Not connected"); r.summary = "The command channel is not connected."; return r }
        let tel = await backend.latestTelemetry(serial: device.serial)
        let range = reserveRange(tel)
        guard range.contains(soc) else { r.add("Validate", false, "\(soc)% outside \(range)"); r.summary = "Reserve must be \(range.lowerBound)–\(range.upperBound)%."; return r }
        if readOnly { r.add("Read-only mode", false, "Changes disabled"); r.summary = "Read-only mode is on; nothing was sent."; return r }
        var summary = ChangeSummary(device: device, targetMode: .timeOfUse, previousMode: tel?.usageMode, newPlan: nil, previousPlan: nil,
                                    newReserve: soc, previousReserve: tel?.backupSOC)
        summary.modeUnchanged = true
        guard await confirm(summary) else { r.add("Confirmation", false, "Declined"); r.summary = "Cancelled by user; nothing was sent."; return r }
        let t0 = Date()
        do { try await backend.sendBackupSOC(device, soc: soc); r.add("Send reserve command", true, "Published \(soc)%") }
        catch { r.add("Send reserve command", false, "\(error)"); r.summary = "\(error)"; return r }
        try? await backend.requestTelemetry(device)
        if await backend.awaitTelemetry(serial: device.serial, since: t0, timeout: verifyTimeout, where: { $0.backupSOC == soc }) != nil {
            r.success = true; r.add("Verify on device", true, "Device reports \(soc)%"); r.summary = "Reserve is \(soc)% (verified from device telemetry)."
        } else { r.add("Verify on device", false, "No confirmation"); r.summary = "The device did not confirm the new reserve." }
        await audit(device.serial, "Reserve \(soc)%: \(r.success ? "VERIFIED" : "NOT verified")")
        return r
    }
}
