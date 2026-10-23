import Foundation

/// Tariff classes used by the PPS TOU plan (anker-solix-api helpers.convert_pps_tou_schedule:
/// 1 = Peak, 2 = Mid peak, 3 = Off peak).
public enum Tariff: Int, Codable, CaseIterable, Sendable, Identifiable {
    case peak = 1, mid = 2, offPeak = 3
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .peak: "Peak (discharge)"
        case .mid: "Mid-peak (idle)"
        case .offPeak: "Off-peak (charge)"
        }
    }
}

public struct TOUSlot: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    /// 0...23
    public var startHour: Int
    /// 1...24 (24 = midnight at end of day)
    public var endHour: Int
    public var tariff: Tariff

    public init(startHour: Int, endHour: Int, tariff: Tariff) {
        self.startHour = startHour; self.endHour = endHour; self.tariff = tariff
    }
    // Identity is irrelevant for equality of schedules.
    public static func == (l: TOUSlot, r: TOUSlot) -> Bool {
        l.startHour == r.startHour && l.endHour == r.endHour && l.tariff == r.tariff
    }
    public func hash(into h: inout Hasher) { h.combine(startHour); h.combine(endHour); h.combine(tariff) }
}

public struct TOUPrice: Codable, Hashable, Sendable {
    public var tariff: Tariff
    public var price: String
    public init(tariff: Tariff, price: String) { self.tariff = tariff; self.price = price }
}

public enum TOUValidationIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case tooManySlots(max: Int)
    case invalidHour(Int)
    case gap(atHour: Int)
    case overlap(atHour: Int)
    case notCoveringDay
    case reserveOutOfRange(min: Int, max: Int)
    case invalidPrice(String)

    public var description: String {
        switch self {
        case .empty: "The plan has no time ranges."
        case .tooManySlots(let m): "The device supports at most \(m) time ranges per day."
        case .invalidHour(let h): "Hour \(h) is outside 0–24."
        case .gap(let h): "There is a gap in the schedule at \(String(format: "%02d:00", h))."
        case .overlap(let h): "Ranges overlap at \(String(format: "%02d:00", h))."
        case .notCoveringDay: "The plan must cover the full day from 00:00 to 24:00."
        case .reserveOutOfRange(let a, let b): "Reserve SOC must be between \(a)% and \(b)%."
        case .invalidPrice(let s): "Price “\(s)” is not a valid non-negative number."
        }
    }
}

/// PPS Time-of-Use plan. The PPS plan has hour granularity, up to 6 ranges, no gaps, and — unlike
/// Solarbank use-time plans — no seasons or weekday/weekend variants (see anker-solix-api
/// schedule.set_pps_use_time). Weekday/weekend schedules are therefore *not* offered for these models.
public struct TOUPlan: Codable, Hashable, Sendable {
    public static let maxSlots = 6

    public var slots: [TOUSlot]
    public var prices: [TOUPrice]
    public var currencyUnit: String
    /// Backup reserve SOC (`reserve_power` in the cloud plan, `backup_soc` over MQTT).
    public var reserveSOC: Int

    public init(slots: [TOUSlot], prices: [TOUPrice] = [], currencyUnit: String = "$", reserveSOC: Int = 10) {
        self.slots = slots; self.prices = prices; self.currencyUnit = currencyUnit; self.reserveSOC = reserveSOC
    }

    public static let defaultPlan = TOUPlan(
        slots: [TOUSlot(startHour: 0, endHour: 24, tariff: .mid)],
        prices: [TOUPrice(tariff: .mid, price: "0")])

    /// - Parameter reserveRange: allowed reserve range; the device requires min_soc+5 ≤ backup ≤ max_soc
    ///   (mqttcmdmap.CMD_PPS_BACKUP_SOC_V2).
    public func validate(reserveRange: ClosedRange<Int> = 5...100) -> [TOUValidationIssue] {
        var issues: [TOUValidationIssue] = []
        guard !slots.isEmpty else { return [.empty] }
        if slots.count > Self.maxSlots { issues.append(.tooManySlots(max: Self.maxSlots)) }
        for s in slots {
            if !(0...23).contains(s.startHour) { issues.append(.invalidHour(s.startHour)) }
            if !(1...24).contains(s.endHour) { issues.append(.invalidHour(s.endHour)) }
        }
        let sorted = slots.sorted { $0.startHour < $1.startHour }
        if sorted.first?.startHour != 0 || sorted.last?.endHour != 24 { issues.append(.notCoveringDay) }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            if a.endHour < b.startHour { issues.append(.gap(atHour: a.endHour)) }
            if a.endHour > b.startHour { issues.append(.overlap(atHour: b.startHour)) }
        }
        for s in sorted where s.endHour <= s.startHour { issues.append(.overlap(atHour: s.startHour)) }
        if !reserveRange.contains(reserveSOC) {
            issues.append(.reserveOutOfRange(min: reserveRange.lowerBound, max: reserveRange.upperBound))
        }
        for p in prices where Double(p.price).map({ $0 < 0 || !$0.isFinite }) ?? true {
            issues.append(.invalidPrice(p.price))
        }
        return issues
    }

    public var isValid: Bool { validate().isEmpty }

    /// Merge adjacent equal-tariff slots and drop prices for unused tariffs (what the Anker app does).
    public func normalized() -> TOUPlan {
        var out: [TOUSlot] = []
        for s in slots.sorted(by: { $0.startHour < $1.startHour }) {
            if var last = out.last, last.tariff == s.tariff, last.endHour == s.startHour {
                last.endHour = s.endHour
                out[out.count - 1] = last
            } else { out.append(s) }
        }
        let used = Set(out.map(\.tariff))
        var p = prices.filter { used.contains($0.tariff) }
        for t in used where !p.contains(where: { $0.tariff == t }) { p.append(TOUPrice(tariff: t, price: "0")) }
        var copy = self
        copy.slots = out; copy.prices = p.sorted { $0.tariff.rawValue < $1.tariff.rawValue }
        return copy
    }

    /// Which tariff applies at a given hour.
    public func tariff(atHour h: Int) -> Tariff? {
        slots.first { $0.startHour <= h && h < $0.endHour }?.tariff
    }

    // MARK: Cloud JSON (`pps_use_time` attribute)

    private static func hhmm(_ h: Int) -> String { String(format: "%02d:00", h) }

    /// Serialized exactly like the cloud attribute documented in anker-solix-api:
    /// {"ranges":[{"start_time":"00:00","end_time":"09:00","type":1}],"prices":[{"price":"0.2","type":1}],"unit":"$","reserve_power":6}
    public func cloudJSONString() throws -> String {
        let ranges: [[String: Any]] = slots.sorted { $0.startHour < $1.startHour }.map {
            ["start_time": Self.hhmm($0.startHour), "end_time": Self.hhmm($0.endHour), "type": $0.tariff.rawValue]
        }
        let prices: [[String: Any]] = prices.map { ["price": $0.price, "type": $0.tariff.rawValue] }
        let obj: [String: Any] = ["ranges": ranges, "prices": prices, "unit": currencyUnit, "reserve_power": reserveSOC]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public init?(cloudJSON: String) {
        guard let data = cloudJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ranges = obj["ranges"] as? [[String: Any]] else { return nil }
        func hour(_ any: Any?) -> Int? {
            guard let s = any as? String, let h = Int(s.prefix(2)) else { return nil }
            return h
        }
        var slots: [TOUSlot] = []
        for r in ranges {
            guard let s = hour(r["start_time"]), let e = hour(r["end_time"]),
                  let t = (r["type"] as? Int) ?? Int("\(r["type"] ?? "")"), let tariff = Tariff(rawValue: t)
            else { return nil }
            slots.append(TOUSlot(startHour: s, endHour: e, tariff: tariff))
        }
        var prices: [TOUPrice] = []
        for p in (obj["prices"] as? [[String: Any]]) ?? [] {
            if let t = (p["type"] as? Int) ?? Int("\(p["type"] ?? "")"), let tariff = Tariff(rawValue: t) {
                prices.append(TOUPrice(tariff: tariff, price: "\(p["price"] ?? "0")"))
            }
        }
        self.init(slots: slots, prices: prices, currencyUnit: (obj["unit"] as? String) ?? "$",
                  reserveSOC: (obj["reserve_power"] as? Int) ?? Int("\(obj["reserve_power"] ?? "")") ?? 10)
    }

    // MARK: MQTT binary schedule (field a7 / telemetry d9)

    /// 1 byte slot count, then per slot: tariff, start hour, end hour (helpers.convert_pps_tou_schedule).
    public func mqttSchedule() -> Data {
        var d = Data([UInt8(slots.count)])
        for s in slots.sorted(by: { $0.startHour < $1.startHour }) {
            d.append(contentsOf: [UInt8(s.tariff.rawValue), UInt8(s.startHour), UInt8(s.endHour)])
        }
        return d
    }

    public static func slots(fromMQTTSchedule data: Data) -> [TOUSlot]? {
        guard let count = data.first.map(Int.init), data.count >= 1 + count * 3 else { return nil }
        var out: [TOUSlot] = []
        let b = [UInt8](data)
        for i in 0..<count {
            let o = 1 + i * 3
            guard let t = Tariff(rawValue: Int(b[o])) else { return nil }
            out.append(TOUSlot(startHour: Int(b[o + 1]), endHour: Int(b[o + 2]), tariff: t))
        }
        return out
    }

    /// Schedule-only comparison (prices are cloud-only and never appear in device telemetry).
    public func sameSchedule(as other: [TOUSlot]) -> Bool {
        slots.sorted { $0.startHour < $1.startHour } == other.sorted { $0.startHour < $1.startHour }
    }
}

// MARK: - Editing helpers (keep the plan contiguous by construction)

extension TOUPlan {
    /// Sorted, contiguous copy of the slots (what the editor works on).
    public var orderedSlots: [TOUSlot] { slots.sorted { $0.startHour < $1.startHour } }

    /// Move the end of slot `i` to `hour`; the next slot's start follows. The last slot always ends at 24.
    public mutating func setEnd(ofSlot i: Int, to hour: Int) {
        var s = orderedSlots
        guard s.indices.contains(i), i < s.count - 1 else { return }
        let h = min(max(hour, s[i].startHour + 1), s[i + 1].endHour - 1)
        s[i].endHour = h; s[i + 1].startHour = h
        slots = s
    }

    public mutating func setTariff(ofSlot i: Int, to t: Tariff) {
        var s = orderedSlots
        guard s.indices.contains(i) else { return }
        s[i].tariff = t; slots = s
    }

    public var canAddSlot: Bool { slots.count < Self.maxSlots && orderedSlots.contains { $0.endHour - $0.startHour >= 2 } }

    /// Split the longest slot in two (≥ 2 h required); the new second half gets a different tariff.
    public mutating func splitLongestSlot() {
        var s = orderedSlots
        guard canAddSlot, let i = s.indices.max(by: { s[$0].endHour - s[$0].startHour < s[$1].endHour - s[$1].startHour }) else { return }
        let mid = s[i].startHour + (s[i].endHour - s[i].startHour) / 2
        let other = Tariff.allCases.first { $0 != s[i].tariff } ?? .mid
        let second = TOUSlot(startHour: mid, endHour: s[i].endHour, tariff: other)
        s[i].endHour = mid
        s.insert(second, at: i + 1)
        slots = s
        if !prices.contains(where: { $0.tariff == other }) { prices.append(TOUPrice(tariff: other, price: "0")) }
    }

    /// Remove slot `i`; the previous slot (or the next, for the first) absorbs its hours.
    public mutating func removeSlot(_ i: Int) {
        var s = orderedSlots
        guard s.count > 1, s.indices.contains(i) else { return }
        if i == 0 { s[1].startHour = 0 } else { s[i - 1].endHour = s[i].endHour }
        s.remove(at: i); slots = s
    }
}
