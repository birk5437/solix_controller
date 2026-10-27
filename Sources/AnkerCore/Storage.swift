import Foundation
import SQLite3
import Security

// MARK: - Redaction

public enum Redactor {
    /// Remove credentials / identifiers from text destined for export. Serial numbers keep their last 4 characters.
    public static func sanitize(_ text: String, serials: [String] = [], email: String? = nil) -> String {
        var s = text
        if let email, !email.isEmpty { s = s.replacingOccurrences(of: email, with: "<email>") }
        for sn in serials where sn.count > 4 {
            s = s.replacingOccurrences(of: sn, with: "…" + sn.suffix(4))
        }
        let rules: [(String, String)] = [
            ("-----BEGIN [A-Z ]+-----[\\s\\S]*?-----END [A-Z ]+-----", "<pem>"),
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>"),
            ("(?i)(x-auth-token|gtoken|authorization|password|auth_token)\"?\\s*[:=]\\s*\"?[^\"\\s,}]+", "$1=<redacted>"),
            ("\\b[0-9a-f]{32,}\\b", "<hex-redacted>"),
        ]
        for (p, r) in rules {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return s
    }
}

// MARK: - Keychain

public struct KeychainManager: Sendable {
    public let service: String
    public init(service: String = "com.solixcontroller.app") { self.service = service }

    public enum KeychainError: Error, Equatable { case status(OSStatus) }

    public func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let s = SecItemAdd(add as CFDictionary, nil)
            if s != errSecSuccess { throw KeychainError.status(s) }
        } else if status != errSecSuccess { throw KeychainError.status(status) }
    }

    public func load(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

// MARK: - SQLite

public struct AuditEntry: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var timestamp: Date
    public var serial: String?
    public var category: String
    public var message: String
}

public struct TelemetryRow: Identifiable, Sendable, Hashable {
    public var id: Double { timestamp.timeIntervalSince1970 }
    public var timestamp: Date
    public var serial: String
    public var soc: Double?
    public var inputW: Double?
    public var outputW: Double?
    public var mode: Int?
    public var connection: String?
    public init(timestamp: Date, serial: String, soc: Double?, inputW: Double?, outputW: Double?, mode: Int?, connection: String?) {
        self.timestamp = timestamp; self.serial = serial; self.soc = soc; self.inputW = inputW
        self.outputW = outputW; self.mode = mode; self.connection = connection
    }
}

public struct StoredSnapshot: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var timestamp: Date
    public var serial: String
    public var kind: String
    public var json: String
}

final class SQLiteHandle: @unchecked Sendable {
    var pointer: OpaquePointer?
    deinit { sqlite3_close(pointer) }
}

public actor Database {
    private let handleBox = SQLiteHandle()
    private var db: OpaquePointer? { handleBox.pointer }
    public nonisolated let path: String

    /// Pass `":memory:"` in tests.
    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(handle)))
        }
        handleBox.pointer = handle
        try Self.exec(handle, """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS telemetry(ts REAL, sn TEXT, soc REAL, in_w REAL, out_w REAL, mode INTEGER, conn TEXT);
        CREATE INDEX IF NOT EXISTS idx_tel ON telemetry(sn, ts);
        CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, sn TEXT, category TEXT, message TEXT);
        CREATE TABLE IF NOT EXISTS snapshots(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, sn TEXT, kind TEXT, json TEXT);
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);
        """)
    }


    public static func defaultPath() throws -> String {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SOLIXController", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("solix.sqlite").path
    }

    public enum DatabaseError: Error, CustomStringConvertible {
        case open(String), sql(String)
        public var description: String {
            switch self { case .open(let m), .sql(let m): "Database error: \(m)" }
        }
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.sql(m)
        }
    }

    private func run(_ sql: String, _ bind: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.sql(String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case let x as Double: sqlite3_bind_double(stmt, idx, x)
            case let x as Int: sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as Int64: sqlite3_bind_int64(stmt, idx, x)
            case let x as String: sqlite3_bind_text(stmt, idx, x, -1, transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func execute(_ sql: String, _ bind: [Any?] = []) throws {
        let stmt = try run(sql, bind)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    private func query<T>(_ sql: String, _ bind: [Any?] = [], _ map: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try run(sql, bind)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(stmt)) }
        return out
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }
    private static func dbl(_ s: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }

    // Telemetry
    public func insertTelemetry(_ r: TelemetryRow) throws {
        try execute("INSERT INTO telemetry VALUES(?,?,?,?,?,?,?)",
                    [r.timestamp.timeIntervalSince1970, r.serial, r.soc, r.inputW, r.outputW, r.mode, r.connection])
    }

    public func telemetry(serial: String, since: Date, limit: Int = 5000) throws -> [TelemetryRow] {
        try query("SELECT ts,sn,soc,in_w,out_w,mode,conn FROM telemetry WHERE sn=? AND ts>=? ORDER BY ts DESC LIMIT ?",
                  [serial, since.timeIntervalSince1970, limit]) { s in
            TelemetryRow(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), serial: Self.text(s, 1) ?? "",
                         soc: Self.dbl(s, 2), inputW: Self.dbl(s, 3), outputW: Self.dbl(s, 4),
                         mode: Self.dbl(s, 5).map(Int.init), connection: Self.text(s, 6))
        }.reversed()
    }

    public func pruneTelemetry(olderThan: Date) throws {
        try execute("DELETE FROM telemetry WHERE ts<?", [olderThan.timeIntervalSince1970])
    }

    // Audit trail
    public func appendAudit(serial: String?, category: String, message: String, at: Date = Date()) throws {
        try execute("INSERT INTO audit(ts,sn,category,message) VALUES(?,?,?,?)",
                    [at.timeIntervalSince1970, serial, category, message])
    }

    public func audit(limit: Int = 500) throws -> [AuditEntry] {
        try query("SELECT id,ts,sn,category,message FROM audit ORDER BY id DESC LIMIT ?", [limit]) { s in
            AuditEntry(id: sqlite3_column_int64(s, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                       serial: Self.text(s, 2), category: Self.text(s, 3) ?? "", message: Self.text(s, 4) ?? "")
        }
    }

    // Configuration snapshots (previous schedules are preserved before any overwrite)
    public func saveSnapshot(serial: String, kind: String, json: String, at: Date = Date()) throws {
        try execute("INSERT INTO snapshots(ts,sn,kind,json) VALUES(?,?,?,?)", [at.timeIntervalSince1970, serial, kind, json])
    }

    public func snapshots(serial: String, kind: String? = nil) throws -> [StoredSnapshot] {
        let sql = "SELECT id,ts,sn,kind,json FROM snapshots WHERE sn=?" + (kind == nil ? "" : " AND kind=?") + " ORDER BY id DESC"
        return try query(sql, kind == nil ? [serial] : [serial, kind]) { s in
            StoredSnapshot(id: sqlite3_column_int64(s, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                           serial: Self.text(s, 2) ?? "", kind: Self.text(s, 3) ?? "", json: Self.text(s, 4) ?? "")
        }
    }

    // Key/value (device registry, settings, automation rules as JSON)
    public func setValue(_ value: String, for key: String) throws {
        try execute("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }

    public func value(for key: String) throws -> String? {
        try query("SELECT value FROM kv WHERE key=?", [key]) { Self.text($0, 0) }.first ?? nil
    }
}
