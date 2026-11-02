import SwiftUI
import Network
import UIKit

/// Lets the Messiah Updater on a PC connect while the app is open, over
/// Wi-Fi (Bonjour, port 47800) or USB (the PC tunnels to the same port).
///
/// Wire format, both directions: 4-byte big-endian JSON length, 4-byte
/// big-endian binary length, the JSON, then the binary (used for IPAs).
final class UpdateServer: ObservableObject {
    static let shared = UpdateServer()
    static let port: UInt16 = 47800
    static let serviceType = "_messiah-upd._tcp"
    static let enabledKey = "updater_enabled"
    private static let tokensKey = "updater_tokens"

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Off"
    @Published private(set) var pairingCode = UpdateServer.newCode()
    @Published private(set) var lastEvent: String?

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var wrongCodes = 0

    private final class Client {
        let conn: NWConnection
        var authed = false
        init(_ conn: NWConnection) { self.conn = conn }
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - Listener

    func start() {
        guard enabled, listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.service = NWListener.Service(name: "Messiah on \(UIDevice.current.name)", type: Self.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.status = "Waiting for the Updater"
                case .failed(let error):
                    self.stop()
                    self.status = "Stopped: \(error.localizedDescription)"
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: .main)
            listener = l
            status = "Starting…"
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.conn.cancel() }
        clients.removeAll()
        isRunning = false
        status = "Off"
    }

    func forgetComputers() {
        UserDefaults.standard.removeObject(forKey: Self.tokensKey)
        clients.values.forEach { $0.conn.cancel() }
        clients.removeAll()
        pairingCode = Self.newCode()
        lastEvent = "Forgot all paired computers"
    }

    private func accept(_ conn: NWConnection) {
        let client = Client(conn)
        let key = ObjectIdentifier(client)
        clients[key] = client
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.clients[key] = nil
                if self.isRunning, !self.clients.values.contains(where: { $0.authed }) {
                    self.status = "Waiting for the Updater"
                }
            default:
                break
            }
        }
        conn.start(queue: .main)
        readFrame(client)
    }

    // MARK: - Framing

    private func readFrame(_ c: Client) {
        read(c.conn, 8) { [weak self] header in
            guard let self, let header else { c.conn.cancel(); return }
            let jsonLen = Int(header.be32(at: 0)), binLen = Int(header.be32(at: 4))
            guard jsonLen > 0, jsonLen <= 64 << 20, binLen <= 512 << 20 else { c.conn.cancel(); return }
            self.read(c.conn, jsonLen) { json in
                guard let json else { c.conn.cancel(); return }
                let finish: (Data) -> Void = { binary in
                    self.handle(c, json: json, binary: binary) { reply, after in
                        self.send(c.conn, reply) {
                            after?()
                            self.readFrame(c)
                        }
                    }
                }
                if binLen == 0 {
                    finish(Data())
                } else {
                    self.read(c.conn, binLen) { binary in
                        guard let binary else { c.conn.cancel(); return }
                        finish(binary)
                    }
                }
            }
        }
    }

    private func read(_ conn: NWConnection, _ count: Int, _ done: @escaping (Data?) -> Void) {
        var buffer = Data()
        buffer.reserveCapacity(min(count, 1 << 24))
        func next() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: min(count - buffer.count, 1 << 20)) { data, _, isComplete, error in
                if let data { buffer.append(data) }
                if buffer.count >= count { done(buffer); return }
                if error != nil || isComplete { done(nil); return }
                next()
            }
        }
        next()
    }

    private func send(_ conn: NWConnection, _ obj: [String: Any], then: @escaping () -> Void) {
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{\"ok\":false}".utf8)
        var frame = Data()
        frame.append(UInt32(json.count).bigEndianBytes)
        frame.append(UInt32(0).bigEndianBytes)
        frame.append(json)
        conn.send(content: frame, completion: .contentProcessed { error in
            if error == nil { then() } else { conn.cancel() }
        })
    }

    // MARK: - Requests

    private typealias Reply = ([String: Any], (() -> Void)?) -> Void

    private func handle(_ c: Client, json: Data, binary: Data, reply: Reply) {
        guard let req = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let type = req["type"] as? String else {
            reply(["ok": false, "error": "Bad request"], nil)
            return
        }
        if type == "hello" {
            reply(hello(c, req), nil)
            return
        }
        guard c.authed else {
            reply(["ok": false, "error": "Not paired. Connect again and enter the pairing code.", "needsPairing": true], nil)
            return
        }

        switch type {
        case "ping":
            reply(["ok": true], nil)

        case "getConfig":
            reply(["ok": true, "config": HybridStore.shared.configJSON,
                   "settings": HybridStore.shared.currentSettings], nil)

        case "apply":
            do {
                let request = try JSONDecoder().decode(HybridStore.ApplyRequest.self, from: json)
                let changes = try HybridStore.shared.apply(request)
                lastEvent = "Update \(HybridStore.shared.packLabel) applied: " + changes.joined(separator: ", ")
                reply(["ok": true, "changes": changes,
                       "packVersion": HybridStore.shared.config.packVersion ?? 0], nil)
            } catch {
                reply(["ok": false, "error": error.localizedDescription], nil)
            }

        case "reset":
            HybridStore.shared.reset()
            lastEvent = "Update pack removed; back to built-in"
            reply(["ok": true], nil)

        case "installIPA":
            guard binary.count > 1000 else {
                reply(["ok": false, "error": "The IPA was empty"], nil)
                return
            }
            let raw = (req["fileName"] as? String) ?? "Messiah.ipa"
            let name = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(name.lowercased().hasSuffix(".ipa") ? name : name + ".ipa")
            do {
                try binary.write(to: url, options: .atomic)
                lastEvent = "Received \(url.lastPathComponent). Choose SideStore or AltStore to install it."
                reply(["ok": true], { Self.presentShareSheet(for: url) })
            } catch {
                reply(["ok": false, "error": "Could not save the IPA: \(error.localizedDescription)"], nil)
            }

        default:
            reply(["ok": false, "error": "Unknown request \(type). Update Messiah to use this feature."], nil)
        }
    }

    private func hello(_ c: Client, _ req: [String: Any]) -> [String: Any] {
        var tokens = UserDefaults.standard.stringArray(forKey: Self.tokensKey) ?? []
        var info: [String: Any] = [:]

        if let token = req["token"] as? String, tokens.contains(token) {
            c.authed = true
        } else if let code = req["code"] as? String {
            if code == pairingCode {
                let token = UUID().uuidString + UUID().uuidString
                tokens.append(token)
                UserDefaults.standard.set(tokens, forKey: Self.tokensKey)
                c.authed = true
                info["token"] = token
                pairingCode = Self.newCode()
                wrongCodes = 0
            } else {
                wrongCodes += 1
                if wrongCodes >= 5 {
                    // stop guessing: a new code is needed after 5 misses
                    pairingCode = Self.newCode()
                    wrongCodes = 0
                }
                info["error"] = "Wrong pairing code"
            }
        }

        if c.authed {
            status = "Connected to the Updater"
        }
        let bundle = Bundle.main.infoDictionary ?? [:]
        info["ok"] = true
        info["paired"] = c.authed
        info["app"] = "Messiah"
        info["version"] = bundle["CFBundleShortVersionString"] as? String ?? "?"
        info["build"] = bundle["CFBundleVersion"] as? String ?? "?"
        info["device"] = UIDevice.current.name
        info["deviceID"] = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        info["packVersion"] = HybridStore.shared.config.packVersion ?? 0
        info["packName"] = HybridStore.shared.config.packName ?? ""
        info["protocol"] = 1
        return info
    }

    // MARK: - Helpers

    private static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private static func presentShareSheet(for url: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                                                 width: 0, height: 0)
        top.present(sheet, animated: true)
    }

    /// The phone's Wi-Fi IPv4 address, for typing into the Updater by hand.
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

private extension Data {
    func be32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}

private extension UInt32 {
    var bigEndianBytes: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
