import Foundation
import CryptoKit
import CommonCrypto

// Ported from thomluther/anker-solix-api (MIT): session.py (login / headers / error handling), apitypes.py (endpoints).

public enum CloudError: Error, CustomStringConvertible, Sendable, Equatable {
    case notLoggedIn
    case invalidCredentials(code: Int, message: String)
    case verificationRequired(code: Int, message: String)
    case tokenKickedOut
    case noPermission(message: String)
    case rateLimited(retryAfter: TimeInterval)
    case server(code: Int, message: String)
    case network(String)
    case malformedResponse(String)
    case readOnlyMode

    public var description: String {
        switch self {
        case .notLoggedIn: "Not signed in to the Anker cloud."
        case .invalidCredentials(let c, let m): "Anker rejected the credentials (\(c)): \(m)"
        case .verificationRequired(let c, let m): "Anker requires account verification (\(c)): \(m). Complete verification in the Anker app, then retry."
        case .tokenKickedOut: "The session was ended by Anker (signed in elsewhere). Sign in again."
        case .noPermission(let m): "This account has no permission for the request: \(m). Device settings require the device owner account."
        case .rateLimited(let s): "Anker rate limit reached; retry in \(Int(s)) s."
        case .server(let c, let m): "Anker API error \(c): \(m)"
        case .network(let m): "Network error: \(m)"
        case .malformedResponse(let m): "Unexpected API response: \(m)"
        case .readOnlyMode: "Read-only mode is on; the change was not sent."
        }
    }

    static func fromCode(_ code: Int, message: String) -> CloudError {
        switch code {
        case 26108, 26156: .invalidCredentials(code: code, message: message)
        case 26050, 26051, 26052, 26053, 26054, 26055: .verificationRequired(code: code, message: message)
        case 26084: .tokenKickedOut
        case 160003: .noPermission(message: message)
        case 429: .rateLimited(retryAfter: 60)
        case 401, 403: .invalidCredentials(code: code, message: message)
        default: .server(code: code, message: message)
        }
    }
}

public protocol HTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransporting {
    let session: URLSession
    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (d, r) = try await session.data(for: request)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct CloudSession: Sendable {
    public var userID: String
    public var nickname: String
    public var expires: Date?
}

public struct CloudDevice: Sendable, Hashable, Identifiable {
    public var id: String { serial }
    public var serial: String
    public var partNumber: String
    public var name: String
    public var firmware: String?
}

public struct MQTTInfo: Sendable {
    public var userID: String
    public var appName: String
    public var thingName: String
    public var certificateID: String
    public var certificatePEM: String
    public var privateKeyPEM: String
    public var endpoint: String
}

public enum AnkerRegion: String, Sendable {
    case com, eu
    var baseURL: URL {
        switch self {
        case .com: URL(string: "https://ankerpower-api.anker.com")!
        case .eu: URL(string: "https://ankerpower-api-eu.anker.com")!
        }
    }
    /// Country list from anker-solix-api apitypes.API_COUNTRIES["com"]; everything else uses EU.
    static let comCountries: Set<String> = [
        "DZ", "LB", "SY", "EG", "LY", "TN", "MA", "JO", "PS", "AR", "AU", "BR", "HK", "IN", "MX", "NG", "NZ",
        "RU", "ZA", "KR", "TW", "US", "CA",
    ]
    public static func forCountry(_ c: String) -> AnkerRegion { comCountries.contains(c.uppercased()) ? .com : .eu }
}

enum AnkerCrypto {
    /// Public key of Anker API servers (session.py `_api_public_key_hex`), identical for EU and COM.
    static let serverPublicKeyHex =
        "04c5c00c4f8d1197cc7c3167c52bf7acb054d722f0ef08dcd7e0883236e0d72a3868d9750cb47fa4619248f3d83f0f662671dadc6e2d31c2f41db0161651c7c076"

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    /// AES-256-CBC, key = ECDH shared secret, IV = first 16 key bytes, PKCS7 (session._encryptApiData).
    static func aesCBCEncrypt(_ plain: Data, key: Data) throws -> Data {
        precondition(key.count == 32)
        let iv = key.prefix(16)
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            plain.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, 32, ivPtr.baseAddress,
                                inPtr.baseAddress, plain.count, outPtr.baseAddress, outPtr.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CloudError.malformedResponse("encryption failed (\(status))") }
        return out.prefix(moved)
    }

    static func aesCBCDecrypt(_ cipher: Data, key: Data) throws -> Data {
        let iv = key.prefix(16)
        var out = Data(count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            cipher.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, 32, ivPtr.baseAddress,
                                inPtr.baseAddress, cipher.count, outPtr.baseAddress, outPtr.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CloudError.malformedResponse("decryption failed (\(status))") }
        return out.prefix(moved)
    }

    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Anker cloud REST client. Credentials are passed in only for login and are never stored or logged here.
public actor AnkerCloudClient {
    private let http: HTTPTransporting
    private let region: AnkerRegion
    private let country: String
    private var token: String?
    private var gtoken: String?
    private var expires: Date?
    private var lastRequest = Date.distantPast
    private var blockedEndpoints: [String: Date] = [:]
    private let minInterval: TimeInterval
    private let audit: (@Sendable (String) -> Void)?
    private let now: @Sendable () -> Date

    public init(country: String, http: HTTPTransporting = URLSessionTransport(), minInterval: TimeInterval = 0.5,
                now: @escaping @Sendable () -> Date = { Date() }, audit: (@Sendable (String) -> Void)? = nil) {
        self.country = country.uppercased()
        self.region = .forCountry(country)
        self.http = http; self.minInterval = minInterval; self.now = now; self.audit = audit
    }

    public var isLoggedIn: Bool { token != nil && (expires.map { $0 > now().addingTimeInterval(60) } ?? true) }
    public var sessionExpiry: Date? { expires }

    // MARK: Login

    static func timezoneHeader(_ tz: TimeZone = .current, at date: Date = Date()) -> String {
        let s = tz.secondsFromGMT(for: date)
        let sign = s < 0 ? "-" : "+"
        return String(format: "GMT%@%02d:%02d", sign, abs(s) / 3600, (abs(s) % 3600) / 60)
    }

    private func headers() -> [String: String] {
        var h = [
            "content-type": "application/json", "model-type": "DESKTOP", "app-name": "anker_power",
            "os-type": "android", "country": country, "timezone": Self.timezoneHeader(),
        ]
        if let token, let gtoken { h["gtoken"] = gtoken; h["x-auth-token"] = token }
        return h
    }

    @discardableResult
    public func login(email: String, password: String) async throws -> CloudSession {
        let priv = P256.KeyAgreement.PrivateKey()
        guard let serverKeyData = AnkerCrypto.data(hex: AnkerCrypto.serverPublicKeyHex),
              let serverKey = try? P256.KeyAgreement.PublicKey(x963Representation: serverKeyData),
              let secret = try? priv.sharedSecretFromKeyAgreement(with: serverKey)
        else { throw CloudError.malformedResponse("key agreement failed") }
        let shared = secret.withUnsafeBytes { Data($0) }
        let encPassword = try AnkerCrypto.aesCBCEncrypt(Data(password.utf8), key: shared).base64EncodedString()
        let tzMs = TimeZone.current.secondsFromGMT() * 1000
        let body: [String: Any] = [
            "ab": country,
            "client_secret_info": ["public_key": AnkerCrypto.hex(priv.publicKey.x963Representation)],
            "enc": 0, "email": email, "password": encPassword, "time_zone": tzMs,
            "transaction": String(Int(now().timeIntervalSince1970 * 1000)),
        ]
        token = nil; gtoken = nil
        let data = try await post("passport/login", body: body, isLogin: true)
        guard let token = data["auth_token"] as? String, let uid = data["user_id"] as? String else {
            throw CloudError.malformedResponse("login response lacks token")
        }
        self.token = token
        self.gtoken = AnkerCrypto.md5Hex(uid)
        let exp = (data["token_expires_at"] as? Double) ?? (data["token_expires_at"] as? Int).map(Double.init)
        self.expires = exp.map { Date(timeIntervalSince1970: $0) }
        audit?("cloud login ok (token expiry \(expires.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"))")
        return CloudSession(userID: uid, nickname: (data["nick_name"] as? String) ?? "", expires: expires)
    }

    public func logout() { token = nil; gtoken = nil; expires = nil }

    // MARK: Requests

    /// Returns the `data` object of a successful response. Writes are never retried automatically.
    @discardableResult
    func post(_ endpoint: String, body: [String: Any] = [:], isLogin: Bool = false) async throws -> [String: Any] {
        if !isLogin {
            guard token != nil else { throw CloudError.notLoggedIn }
            if let e = expires, e <= now().addingTimeInterval(60) { token = nil; throw CloudError.notLoggedIn }
        }
        if let until = blockedEndpoints[endpoint], until > now() {
            throw CloudError.rateLimited(retryAfter: until.timeIntervalSince(now()))
        }
        let wait = minInterval - now().timeIntervalSince(lastRequest)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRequest = now()

        var req = URLRequest(url: region.baseURL.appendingPathComponent(endpoint))
        req.httpMethod = "POST"
        for (k, v) in headers() { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, status): (Data, Int)
        do { (data, status) = try await http.send(req) } catch { throw CloudError.network(error.localizedDescription) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 429 {
            blockedEndpoints[endpoint] = now().addingTimeInterval(60)
            throw CloudError.rateLimited(retryAfter: 60)
        }
        guard let json else {
            if status == 401 || status == 403 { throw CloudError.invalidCredentials(code: status, message: "HTTP \(status)") }
            throw CloudError.malformedResponse("HTTP \(status), non-JSON body")
        }
        let code = (json["code"] as? Int) ?? Int("\(json["code"] ?? "")") ?? -1
        audit?("cloud POST \(endpoint) → http \(status), code \(code)")
        guard code == 0 else { throw CloudError.fromCode(code, message: (json["msg"] as? String) ?? "no message") }
        return (json["data"] as? [String: Any]) ?? [:]
    }

    // MARK: API calls used by the app

    /// `power_service/v1/site/list_user_devices` → pps_list etc.
    public func listDevices() async throws -> [CloudDevice] {
        let data = try await post("power_service/v1/site/list_user_devices")
        var out: [CloudDevice] = []
        for (_, value) in data {
            guard let list = value as? [[String: Any]] else { continue }
            for d in list {
                guard let sn = d["device_sn"] as? String, let pn = d["device_pn"] as? String else { continue }
                out.append(CloudDevice(serial: sn, partNumber: pn, name: (d["device_name"] as? String) ?? pn,
                                       firmware: (d["main_version"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        return out
    }

    /// `power_service/v1/app/device/get_device_attrs`
    public func deviceAttributes(serial: String, names: [String]) async throws -> [String: String] {
        let data = try await post("power_service/v1/app/device/get_device_attrs",
                                  body: ["device_sn": serial, "attributes": names])
        var out: [String: String] = [:]
        for (k, v) in (data["attributes"] as? [String: Any]) ?? [:] { out[k] = (v as? String) ?? "\(v)" }
        return out
    }

    /// `power_service/v1/app/device/set_device_attrs`. Acceptance (code 0) is NOT proof of device state.
    public func setDeviceAttributes(serial: String, attributes: [String: String]) async throws {
        try await post("power_service/v1/app/device/set_device_attrs",
                       body: ["device_sn": serial, "attributes": attributes])
    }

    /// `app/devicemanage/get_user_mqtt_info`
    public func mqttInfo() async throws -> MQTTInfo {
        let d = try await post("app/devicemanage/get_user_mqtt_info")
        guard let uid = d["user_id"] as? String, let app = d["app_name"] as? String,
              let thing = d["thing_name"] as? String, let cert = d["certificate_pem"] as? String,
              let key = d["private_key"] as? String, let host = d["endpoint_addr"] as? String
        else { throw CloudError.malformedResponse("MQTT info incomplete") }
        return MQTTInfo(userID: uid, appName: app, thingName: thing,
                        certificateID: (d["certificate_id"] as? String) ?? "",
                        certificatePEM: cert, privateKeyPEM: key, endpoint: host)
    }
}
