import Foundation
import CryptoKit
import Network

/// Invite codes: 10 characters (XXXXX-XXXXX) that carry their issue time and
/// a signature, so any copy of Messiah can check them offline. A code works
/// for 5 minutes after the owner issues it.
enum InviteCodes {
    static let lifetime: TimeInterval = 300

    /// The signing secret is not in the source code. The build adds
    /// Generated/InviteSecret.swift from the MESSIAH_INVITE_SECRET GitHub secret.
    private static let secret = SymmetricKey(data: Data(hex: InviteSecret.hex))
    private static let epoch: TimeInterval = 1_767_225_600 // 2026-01-01
    private static let tickLength: TimeInterval = 30
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func issue(at date: Date = Date()) -> String {
        let tick = UInt64(max(0, (date.timeIntervalSince1970 - epoch) / tickLength)) & 0x7F_FFFF
        let value = tick << 27 | mac(tick)
        var chars: [Character] = []
        for i in stride(from: 9, through: 0, by: -1) {
            chars.append(alphabet[Int((value >> (UInt64(i) * 5)) & 31)])
        }
        let s = String(chars)
        return String(s.prefix(5)) + "-" + String(s.suffix(5))
    }

    static func isValid(_ input: String, now: Date = Date()) -> Bool {
        guard let value = decode(input) else { return false }
        let tick = value >> 27
        guard mac(tick) == value & 0x7FF_FFFF else { return false }
        let nowTick = Int64((now.timeIntervalSince1970 - epoch) / tickLength)
        let age = nowTick - Int64(tick)
        // 10 ticks of 30 s = 5 minutes, with a little allowance for clock drift
        return age >= -2 && age <= Int64(lifetime / tickLength)
    }

    /// Uppercases and inserts the dash while the user types.
    static func format(_ input: String) -> String {
        let s = clean(input)
        return s.count > 5 ? String(s.prefix(5)) + "-" + String(s.dropFirst(5).prefix(5)) : s
    }

    static func clean(_ input: String) -> String {
        var out = ""
        for ch in input.uppercased() {
            switch ch {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default: if alphabet.contains(ch) { out.append(ch) }
            }
        }
        return String(out.prefix(10))
    }

    private static func decode(_ input: String) -> UInt64? {
        let s = clean(input)
        guard s.count == 10 else { return nil }
        var value: UInt64 = 0
        for ch in s {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = value << 5 | UInt64(i)
        }
        return value
    }

    private static func mac(_ tick: UInt64) -> UInt64 {
        var be = tick.bigEndian
        let message = Data("messiah-invite".utf8) + withUnsafeBytes(of: &be) { Data($0) }
        let b = Array(HMAC<SHA256>.authenticationCode(for: message, using: secret))
        let first32 = UInt64(b[0]) << 24 | UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3])
        return first32 >> 5 // 27 bits
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var chars = Array(hex)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        for i in stride(from: 0, to: chars.count, by: 2) {
            bytes.append(UInt8(String(chars[i...i + 1]), radix: 16) ?? 0)
        }
        self.init(bytes)
    }
}

/// The owner (admin) device. Only Messiah Updater on the owner's PC has the
/// owner key, and it only sends it over USB to the owner's iPhone (checked by
/// its serial/UDID on the PC side). The key lives in the Keychain, so it
/// survives reinstalling Messiah.
final class OwnerStore: ObservableObject {
    static let shared = OwnerStore()
    private static let keyHash = "8b5f6da711241dd2e75b0073b470a41a087c7f25f7c199a2024ff4614d4d4259"
    private static let keychainName = "messiah_owner_key"

    @Published private(set) var isOwner: Bool

    private init() {
        isOwner = Self.check(Keychain.get(Self.keychainName))
    }

    func grant(_ key: String) -> Bool {
        guard Self.check(key) else { return false }
        Keychain.set(key, for: Self.keychainName)
        isOwner = true
        return true
    }

    func revoke() {
        Keychain.set("", for: Self.keychainName)
        isOwner = false
    }

    private static func check(_ key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() == keyHash
    }

    /// True when a connection came through the USB tunnel (usbmuxd connects
    /// from the phone's own loopback address).
    static func isUSB(_ conn: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = conn.endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        default: return false
        }
    }
}
