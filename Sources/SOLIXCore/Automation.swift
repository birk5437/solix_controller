import Foundation

/// Mac-managed automation. These rules run only while the app is open and the Mac is awake — unlike the device's
/// native TOU schedule, which keeps running on the battery by itself.
public struct AutomationRule: Codable, Identifiable, Hashable, Sendable {
    public enum Action: Codable, Hashable, Sendable {
        case setUsageMode(UsageMode)
        case setBackupSOC(Int)

        public var label: String {
            switch self {
            case .setUsageMode(let m): "Switch to \(m.label)"
            case .setBackupSOC(let s): "Set reserve to \(s)%"
            }
        }
        var kind: String {
            switch self { case .setUsageMode: "mode"; case .setBackupSOC: "reserve" }
        }
    }

    public var id = UUID()
    public var name: String
    public var serial: String
    public var enabled = true
    public var hour: Int
    public var minute: Int
    /// Calendar weekdays: 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    public var action: Action

    public init(name: String, serial: String, hour: Int, minute: Int, weekdays: Set<Int> = Set(1...7), action: Action) {
        self.name = name; self.serial = serial; self.hour = hour; self.minute = minute
        self.weekdays = weekdays; self.action = action
    }
}

public enum AutomationValidator {
    public static func validate(_ rule: AutomationRule, profile: ModelProfile?) -> [String] {
        var issues: [String] = []
        if !(0...23).contains(rule.hour) || !(0...59).contains(rule.minute) { issues.append("Time is invalid.") }
        if rule.weekdays.isEmpty || !rule.weekdays.isSubset(of: Set(1...7)) { issues.append("Select at least one weekday.") }
        guard let p = profile else { return issues + ["Unknown device model."] }
        switch rule.action {
        case .setUsageMode(let m):
            if !p.settableUsageModes.contains(m) { issues.append("\(p.marketingName) cannot be switched to \(m.label) by this app.") }
        case .setBackupSOC(let s):
            if !p.capabilities.supportsReserveSOC { issues.append("\(p.marketingName) has no documented reserve command.") }
            if !(5...100).contains(s) { issues.append("Reserve must be within 5–100%.") }
        }
        return issues
    }

    /// Contradictory = same device, same weekday, same minute, same kind of action but different value.
    /// Duplicate = identical action at the same time.
    public static func conflicts(_ rules: [AutomationRule]) -> [String] {
        var out: [String] = []
        let active = rules.filter(\.enabled)
        for (i, a) in active.enumerated() {
            for b in active[(i + 1)...] where a.serial == b.serial && a.hour == b.hour && a.minute == b.minute
                && !a.weekdays.isDisjoint(with: b.weekdays) && a.action.kind == b.action.kind {
                out.append(a.action == b.action
                    ? "“\(a.name)” and “\(b.name)” are duplicates."
                    : "“\(a.name)” and “\(b.name)” contradict each other (same time, different \(a.action.kind)).")
            }
        }
        return out
    }
}

public enum AutomationScheduler {
    /// Next firing strictly after `date`, using the calendar's time zone. Calendar matching handles DST: a time that
    /// does not exist on a spring-forward day fires at the next valid instant; a repeated time fires once (`.first`).
    public static func nextFire(of rule: AutomationRule, after date: Date, calendar: Calendar = .current) -> Date? {
        var best: Date?
        for wd in rule.weekdays {
            let comps = DateComponents(hour: rule.hour, minute: rule.minute, second: 0, weekday: wd)
            if let d = calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime,
                                         repeatedTimePolicy: .first, direction: .forward), best == nil || d < best! {
                best = d
            }
        }
        return best
    }

    /// Rules due in `(lastCheck, now]`, but only when the scheduled time is within `catchUp` of now, so waking from sleep
    /// hours later does not execute stale changes.
    public static func due(_ rules: [AutomationRule], lastCheck: Date, now: Date, catchUp: TimeInterval = 300,
                           calendar: Calendar = .current) -> [AutomationRule] {
        rules.filter { r in
            guard r.enabled, let next = nextFire(of: r, after: lastCheck, calendar: calendar) else { return false }
            return next <= now && now.timeIntervalSince(next) <= catchUp
        }
    }
}

@MainActor
public final class AutomationEngine {
    private var task: Task<Void, Never>?
    private var lastCheck = Date()
    private let rules: () -> [AutomationRule]
    private let perform: (AutomationRule) async -> Void

    public init(rules: @escaping () -> [AutomationRule], perform: @escaping (AutomationRule) async -> Void) {
        self.rules = rules; self.perform = perform
    }

    public func start() {
        stop(); lastCheck = Date()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                let now = Date()
                let due = AutomationScheduler.due(self.rules(), lastCheck: self.lastCheck, now: now)
                self.lastCheck = now
                for r in due { await self.perform(r) }
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }
}
