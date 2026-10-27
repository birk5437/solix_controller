import Foundation
import Network
@preconcurrency import Security

// Minimal MQTT 3.1.1 client (QoS 0 publish, QoS 0/1 receive) over TLS with a client certificate, as required by the
// Anker MQTT broker (port 8883). Topic and envelope formats from anker-solix-api mqtt.py.

public struct MQTTMessage: Sendable {
    public var topic: String
    public var payload: Data
}

public enum MQTTError: Error, CustomStringConvertible, Sendable {
    case identity(String)
    case connection(String)
    case refused(UInt8)
    case notConnected
    case timeout
    public var description: String {
        switch self {
        case .identity(let m): "Could not build the TLS client identity: \(m)"
        case .connection(let m): "MQTT connection failed: \(m)"
        case .refused(let c): "MQTT broker refused the connection (code \(c))"
        case .notConnected: "MQTT is not connected."
        case .timeout: "MQTT operation timed out."
        }
    }
}

// MARK: - Packet codec (pure, unit-tested)

public enum MQTTCodec {
    public static func remainingLength(_ n: Int) -> [UInt8] {
        var x = n; var out: [UInt8] = []
        repeat {
            var b = UInt8(x % 128); x /= 128
            if x > 0 { b |= 0x80 }
            out.append(b)
        } while x > 0
        return out
    }

    static func utf8(_ s: String) -> [UInt8] {
        let b = [UInt8](s.utf8)
        return [UInt8(b.count >> 8), UInt8(b.count & 0xff)] + b
    }

    public static func connect(clientID: String, keepAlive: UInt16 = 60) -> Data {
        var vh: [UInt8] = utf8("MQTT") + [0x04, 0x02, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xff)]
        vh += utf8(clientID)
        return Data([0x10] + remainingLength(vh.count) + vh)
    }

    public static func subscribe(packetID: UInt16, topics: [String]) -> Data {
        var body: [UInt8] = [UInt8(packetID >> 8), UInt8(packetID & 0xff)]
        for t in topics { body += utf8(t) + [0x00] }
        return Data([0x82] + remainingLength(body.count) + body)
    }

    public static func publish(topic: String, payload: Data) -> Data {
        let body = utf8(topic) + [UInt8](payload)
        return Data([0x30] + remainingLength(body.count) + body)
    }

    public static let pingReq = Data([0xC0, 0x00])

    public enum Packet: Equatable, Sendable {
        case connack(returnCode: UInt8)
        case suback
        case publish(topic: String, payload: Data, qos: UInt8, packetID: UInt16?)
        case pingResp
        case other(UInt8)
    }

    /// Extract complete packets from `buffer`, leaving any partial tail in place.
    public static func drain(_ buffer: inout Data) -> [Packet] {
        var out: [Packet] = []
        while true {
            let b = [UInt8](buffer)
            guard b.count >= 2 else { break }
            var mult = 1, len = 0, i = 1, complete = false
            while i < b.count && i <= 4 {
                len += Int(b[i] & 0x7f) * mult
                mult *= 128
                i += 1
                if b[i - 1] & 0x80 == 0 { complete = true; break }
            }
            guard complete, b.count >= i + len else { break }
            let body = Array(b[i..<(i + len)])
            let type = b[0] >> 4
            switch type {
            case 2: out.append(.connack(returnCode: body.count >= 2 ? body[1] : 0xff))
            case 9: out.append(.suback)
            case 13: out.append(.pingResp)
            case 3:
                let qos = (b[0] >> 1) & 0x03
                if body.count >= 2 {
                    let tl = Int(body[0]) << 8 | Int(body[1])
                    if body.count >= 2 + tl {
                        let topic = String(decoding: body[2..<(2 + tl)], as: UTF8.self)
                        var p = 2 + tl; var pid: UInt16?
                        if qos > 0, body.count >= p + 2 { pid = UInt16(body[p]) << 8 | UInt16(body[p + 1]); p += 2 }
                        out.append(.publish(topic: topic, payload: Data(body[min(p, body.count)...]), qos: qos, packetID: pid))
                    }
                }
            default: out.append(.other(type))
            }
            buffer.removeFirst(i + len)
        }
        return out
    }
}

// MARK: - Anker envelope

public enum AnkerEnvelope {
    public struct Inbound: Sendable { public var partNumber: String?; public var serial: String?; public var frame: Data }

    /// Decode `{"head":{...},"payload":"{\"data\":\"<b64>\",...}"}` → hex frame bytes.
    public static func decode(topic: String, payload: Data) -> Inbound? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let inner = obj["payload"] as? String,
              let innerObj = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any],
              let b64 = innerObj["data"] as? String, let frame = Data(base64Encoded: b64) else { return nil }
        let parts = topic.split(separator: "/")
        let pn = (innerObj["pn"] as? String) ?? (parts.count > 2 ? String(parts[2]) : nil)
        let sn = (innerObj["sn"] as? String) ?? (parts.count > 3 ? String(parts[3]) : nil)
        return Inbound(partNumber: pn, serial: sn, frame: frame)
    }

    public static func commandTopic(info: MQTTInfo, pn: String, sn: String) -> String { "cmd/\(info.appName)/\(pn)/\(sn)/req" }
    public static func subscribeTopics(info: MQTTInfo, pn: String, sn: String) -> [String] {
        ["dt/\(info.appName)/\(pn)/\(sn)/#", "cmd/\(info.appName)/\(pn)/\(sn)/#"]
    }

    public static func command(info: MQTTInfo, pn: String, sn: String, frame: Data, now: Date = Date()) throws -> Data {
        let inner: [String: Any] = ["device_sn": sn, "account_id": info.userID, "data": frame.base64EncodedString()]
        let innerData = try JSONSerialization.data(withJSONObject: inner, options: [.sortedKeys])
        let head: [String: Any] = [
            "version": "1.0.0.1",
            "client_id": "android-\(info.appName)-\(info.userID)-\(info.certificateID)",
            "sess_id": "1234-5678", "msg_seq": 1, "seed": 1,
            "timestamp": Int(now.timeIntervalSince1970), "cmd_status": 2, "cmd": 17, "sign_code": 1,
            "device_pn": pn, "device_sn": sn,
        ]
        let outer: [String: Any] = ["head": head, "payload": String(decoding: innerData, as: UTF8.self)]
        return try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
    }
}

// MARK: - TLS client identity

enum MQTTIdentity {
    /// Builds a SecIdentity from the PEM certificate + private key returned by the Anker API using a throw-away
    /// keychain that is deleted afterwards. Nothing is written to the user's login keychain.
    @available(macOS, deprecated: 10.10, message: "SecKeychain is the only way to pair PEM key + cert without a PKCS#12 passphrase")
    static func make(certPEM: String, keyPEM: String) throws -> (SecIdentity, cleanup: @Sendable () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("solix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("mqtt.keychain").path
        let pw = UUID().uuidString
        var kc: SecKeychain?
        guard SecKeychainCreate(path, UInt32(pw.utf8.count), pw, false, nil, &kc) == errSecSuccess, let kc else {
            throw MQTTError.identity("temporary keychain creation failed")
        }
        let cleanup: @Sendable () -> Void = {
            SecKeychainDelete(kc)
            try? FileManager.default.removeItem(at: dir)
        }
        do {
            func importPEM(_ pem: String, type: SecExternalItemType) throws -> [Any] {
                var format = SecExternalFormat.formatPEMSequence
                var itemType = type
                var items: CFArray?
                let st = SecItemImport(Data(pem.utf8) as CFData, nil, &format, &itemType, [], nil, kc, &items)
                guard st == errSecSuccess else { throw MQTTError.identity("import failed (\(st))") }
                return (items as? [Any]) ?? []
            }
            _ = try importPEM(keyPEM, type: .itemTypePrivateKey)
            let certs = try importPEM(certPEM, type: .itemTypeCertificate)
            guard let certAny = certs.first else { throw MQTTError.identity("no certificate in PEM") }
            let cert = certAny as! SecCertificate  // swiftlint:disable:this force_cast
            var identity: SecIdentity?
            let st = SecIdentityCreateWithCertificate(kc, cert, &identity)
            guard st == errSecSuccess, let identity else { throw MQTTError.identity("key/certificate pairing failed (\(st))") }
            return (identity, cleanup)
        } catch {
            cleanup()
            throw error
        }
    }
}

// MARK: - Client

public actor MQTTClient {
    private var connection: NWConnection?
    private var buffer = Data()
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var pingTask: Task<Void, Never>?
    private var packetID: UInt16 = 0
    private var cleanup: (@Sendable () -> Void)?
    private var continuation: AsyncStream<MQTTMessage>.Continuation?
    public nonisolated let messages: AsyncStream<MQTTMessage>
    public private(set) var isConnected = false

    public init() {
        var c: AsyncStream<MQTTMessage>.Continuation!
        messages = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { c = $0 }
        continuation = c
    }

    public func connect(info: MQTTInfo, timeout: TimeInterval = 20) async throws {
        disconnect()
        let (identity, cleanupFn) = try MQTTIdentity.make(certPEM: info.certificatePEM, keyPEM: info.privateKeyPEM)
        cleanup = cleanupFn
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(host: NWEndpoint.Host(info.endpoint), port: 8883, using: params)
        connection = conn
        buffer = Data()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    Task { await self.armConnect(cont, conn: conn, clientID: "\(info.thingName)_\(String(format: "%05d", Int.random(in: 0..<99999)))") }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MQTTError.timeout
            }
            do { try await group.next(); group.cancelAll() } catch { group.cancelAll(); await self.teardown(); throw error }
        }
        isConnected = true
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.send(MQTTCodec.pingReq)
            }
        }
    }

    private func armConnect(_ cont: CheckedContinuation<Void, Error>, conn: NWConnection, clientID: String) {
        connectWaiter = cont
        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state: state, clientID: clientID) }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func handle(state: NWConnection.State, clientID: String) {
        switch state {
        case .ready:
            send(MQTTCodec.connect(clientID: clientID))
            receiveLoop()
        case .failed(let e), .waiting(let e):
            finishConnect(.failure(MQTTError.connection(e.localizedDescription)))
            if case .failed = state { isConnected = false }
        case .cancelled:
            isConnected = false
        default: break
        }
    }

    private func finishConnect(_ r: Result<Void, Error>) {
        guard let w = connectWaiter else { return }
        connectWaiter = nil
        w.resume(with: r)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { await self?.onReceive(data: data, complete: complete, error: error) }
        }
    }

    private func onReceive(data: Data?, complete: Bool, error: NWError?) {
        if let data { buffer.append(data) }
        for p in MQTTCodec.drain(&buffer) {
            switch p {
            case .connack(let rc): finishConnect(rc == 0 ? .success(()) : .failure(MQTTError.refused(rc)))
            case .publish(let topic, let payload, let qos, let pid):
                if qos == 1, let pid { send(Data([0x40, 0x02, UInt8(pid >> 8), UInt8(pid & 0xff)])) }
                continuation?.yield(MQTTMessage(topic: topic, payload: payload))
            default: break
            }
        }
        if error != nil || complete { isConnected = false; finishConnect(.failure(MQTTError.connection("closed"))); return }
        receiveLoop()
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    public func subscribe(_ topics: [String]) throws {
        guard isConnected else { throw MQTTError.notConnected }
        packetID &+= 1
        send(MQTTCodec.subscribe(packetID: max(packetID, 1), topics: topics))
    }

    public func publish(topic: String, payload: Data) throws {
        guard isConnected else { throw MQTTError.notConnected }
        send(MQTTCodec.publish(topic: topic, payload: payload))
    }

    private func teardown() { disconnect() }

    public func disconnect() {
        pingTask?.cancel(); pingTask = nil
        if isConnected { connection?.send(content: Data([0xE0, 0x00]), completion: .contentProcessed { _ in }) }
        connection?.cancel(); connection = nil
        isConnected = false
        cleanup?(); cleanup = nil
        finishConnect(.failure(MQTTError.notConnected))
    }
}
