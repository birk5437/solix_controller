import Foundation
import Network
import Observation

public struct LANHost: Identifiable, Hashable, Sendable {
    public var id: String { "\(name)|\(type)" }
    public var name: String
    public var type: String
    public var domain: String
    public var isSolixLike: Bool
}

public struct LANProbeResult: Identifiable, Hashable, Sendable {
    public var id: String { "\(host):\(port)" }
    public var host: String
    public var port: UInt16
    public var reachable: Bool
    public var note: String
}

/// Local-network discovery. No documented local API exists for A1763 / A1783 / A1790P, so the app can only
/// (a) list Bonjour services whose names look like Anker/SOLIX devices and (b) probe a manually entered IP.
@MainActor
@Observable
public final class LocalNetworkService {
    /// Bonjour types listed in Info.plist NSBonjourServices.
    public static let serviceTypes = ["_http._tcp", "_modbus._tcp"]
    public private(set) var hosts: [LANHost] = []
    public private(set) var browsing = false
    public private(set) var browserError: String?
    public var manualResults: [LANProbeResult] = []
    @ObservationIgnored private var browsers: [NWBrowser] = []

    public init() {}

    public func startBrowsing() {
        stopBrowsing()
        browserError = nil
        for t in Self.serviceTypes {
            let b = NWBrowser(for: .bonjour(type: t, domain: nil), using: .tcp)
            b.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .failed(let e) = state { self?.browserError = e.localizedDescription }
                    if case .waiting(let e) = state { self?.browserError = e.localizedDescription }
                }
            }
            b.browseResultsChangedHandler = { [weak self] results, _ in
                let found: [LANHost] = results.compactMap {
                    guard case let .service(name, type, domain, _) = $0.endpoint else { return nil }
                    let like = ["anker", "solix", "a17", "a18"].contains { name.lowercased().contains($0) }
                    return LANHost(name: name, type: type, domain: domain, isSolixLike: like)
                }
                Task { @MainActor in self?.merge(found, type: t) }
            }
            b.start(queue: .main)
            browsers.append(b)
        }
        browsing = true
    }

    private func merge(_ found: [LANHost], type: String) {
        hosts.removeAll { $0.type == type || $0.type == type + "." }
        hosts.append(contentsOf: found)
    }

    public func stopBrowsing() { browsers.forEach { $0.cancel() }; browsers = []; browsing = false }

    /// TCP reachability probe. Does not send any application data.
    public nonisolated static func probe(host: String, port: UInt16, timeout: TimeInterval = 3) async -> LANProbeResult {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            return LANProbeResult(host: host, port: port, reachable: false, note: "invalid port")
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        return await withCheckedContinuation { (cont: CheckedContinuation<LANProbeResult, Never>) in
            let box = OnceBox()
            @Sendable func finish(_ ok: Bool, _ note: String) {
                guard box.fire() else { return }
                conn.cancel()
                cont.resume(returning: LANProbeResult(host: host, port: port, reachable: ok, note: note))
            }
            conn.stateUpdateHandler = { s in
                switch s {
                case .ready: finish(true, "TCP connection accepted (protocol unknown)")
                case .failed(let e): finish(false, e.localizedDescription)
                case .waiting(let e): finish(false, e.localizedDescription)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false, "timed out") }
        }
    }

    public func probeManual(host: String, ports: [UInt16] = [502, 80, 8080]) async {
        var results: [LANProbeResult] = []
        for p in ports { results.append(await Self.probe(host: host, port: p)) }
        manualResults = results
    }
}

final class OnceBox: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
