import SwiftUI

struct HybridPreset: Codable, Equatable {
    var name: String
    var text: String
}

/// Everything the desktop Updater can change without installing a new IPA.
/// Every field is optional: nil means "use the built-in value".
struct HybridConfig: Codable, Equatable {
    var packVersion: Int?
    var packName: String?
    var appliedAt: Date?
    /// "magenta" / "coral" / "amber" / "violet" / "blue" -> "#RRGGBB"
    var colors: [String: String]?
    var appTitle: String?
    var welcomeText: String?
    var inputPlaceholder: String?
    var baseSystemPrompt: String?
    var personalities: [HybridPreset]?
    /// Shown once on the phone right after the update is applied.
    var announcement: String?
    /// built-in sound name (no extension) -> file name in the sounds folder
    var sounds: [String: String]?
}

struct HybridError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Holds the update pack sent by the Updater, saved in Application Support.
final class HybridStore: ObservableObject {
    static let shared = HybridStore()

    static let colorNames = ["magenta", "coral", "amber", "violet", "blue"]
    static let soundNames = ["messiah_processing_loop", "messiah_wake", "messiah_window_close",
                             "messiah_mic_on", "messiah_mic_off", "messiah_interrupt", "waves_error_ping2"]
    private static let soundExtensions = ["wav", "mp3", "m4a", "caf", "aif", "aiff"]

    @Published private(set) var config = HybridConfig()
    /// Bumped on every change so the whole UI redraws with the new values.
    @Published private(set) var revision = 0
    @Published var pendingAnnouncement: String?

    private let dir: URL
    private var configURL: URL { dir.appendingPathComponent("config.json") }
    private var soundsDir: URL { dir.appendingPathComponent("sounds", isDirectory: true) }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("hybrid", isDirectory: true)
        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: configURL),
           let saved = try? JSONDecoder().decode(HybridConfig.self, from: data) {
            config = saved
        }
    }

    // MARK: - Values used by the app

    func color(_ name: String) -> Color? {
        config.colors?[name].flatMap { Color(hex: $0) }
    }

    var appTitle: String { Self.nonEmpty(config.appTitle) ?? "Messiah" }
    var welcomeText: String { Self.nonEmpty(config.welcomeText) ?? "Ask Messiah anything." }
    var inputPlaceholder: String { Self.nonEmpty(config.inputPlaceholder) ?? "Message Messiah" }
    var baseSystemPrompt: String? { Self.nonEmpty(config.baseSystemPrompt) }

    var packLabel: String {
        guard let v = config.packVersion else { return "None (built-in)" }
        if let name = Self.nonEmpty(config.packName) { return "\(name) (#\(v))" }
        return "#\(v)"
    }

    func soundURL(_ name: String) -> URL? {
        guard let file = config.sounds?[name] else { return nil }
        let url = soundsDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var configJSON: Any {
        guard let data = try? JSONEncoder().encode(config),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [String: Any]() }
        return obj
    }

    // MARK: - Applying updates

    struct SoundUpload: Decodable {
        let ext: String
        let data: String
    }

    struct ApplyRequest: Decodable {
        let config: HybridConfig
        let soundUploads: [String: SoundUpload]?
        let keepSounds: [String]?
        let settings: [String: String]?
    }

    /// Replaces the current pack. Returns what changed, for the Updater's log.
    func apply(_ req: ApplyRequest) throws -> [String] {
        var new = req.config

        for (name, hex) in new.colors ?? [:] {
            guard Self.colorNames.contains(name), Color(hex: hex) != nil else {
                throw HybridError(message: "Invalid color \(name): \(hex)")
            }
        }

        var sounds: [String: String] = [:]
        for name in req.keepSounds ?? [] {
            if let file = config.sounds?[name] { sounds[name] = file }
        }
        for (name, upload) in req.soundUploads ?? [:] {
            let ext = upload.ext.lowercased()
            guard Self.soundNames.contains(name) else { throw HybridError(message: "Unknown sound \(name)") }
            guard Self.soundExtensions.contains(ext) else { throw HybridError(message: "Unsupported sound type .\(ext)") }
            guard let data = Data(base64Encoded: upload.data), !data.isEmpty, data.count < 15_000_000 else {
                throw HybridError(message: "Sound \(name) is empty or too large")
            }
            let file = name + "-" + String(UUID().uuidString.prefix(8)) + "." + ext
            try data.write(to: soundsDir.appendingPathComponent(file), options: .atomic)
            sounds[name] = file
        }
        new.sounds = sounds.isEmpty ? nil : sounds
        new.personalities = new.personalities?.filter { Self.nonEmpty($0.name) != nil && Self.nonEmpty($0.text) != nil }
        if new.personalities?.isEmpty == true { new.personalities = nil }
        new.packVersion = new.packVersion ?? (config.packVersion ?? 0) + 1
        new.appliedAt = Date()

        var changes = Self.describe(from: config, to: new, newSounds: !(req.soundUploads ?? [:]).isEmpty)
        changes += applySettings(req.settings ?? [:])

        config = new
        save()
        cleanSounds()
        revision += 1
        if let note = Self.nonEmpty(new.announcement) { pendingAnnouncement = note }
        return changes.isEmpty ? ["Nothing changed"] : changes
    }

    func reset() {
        config = HybridConfig()
        save()
        cleanSounds()
        revision += 1
    }

    var currentSettings: [String: String] {
        let d = UserDefaults.standard
        var out: [String: String] = [:]
        for key in Self.stringSettings { out[key] = d.string(forKey: key) ?? "" }
        out[AppSettings.speechEnabledKey] = d.bool(forKey: AppSettings.speechEnabledKey) ? "true" : "false"
        return out
    }

    private static let stringSettings = [AppSettings.providerKey, AppSettings.modelKey, AppSettings.ollamaURLKey,
                                         AppSettings.appearanceKey, AppSettings.speechProviderKey,
                                         AppSettings.fishVoiceIDKey, AppSettings.fishModelKey]

    /// Only known settings are accepted; an empty value leaves a setting as it is.
    private func applySettings(_ settings: [String: String]) -> [String] {
        let d = UserDefaults.standard
        var changed: [String] = []
        for (key, raw) in settings {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch key {
            case AppSettings.providerKey where ProviderKind(rawValue: value) == nil: continue
            case AppSettings.appearanceKey where AppAppearance(rawValue: value) == nil: continue
            case AppSettings.speechProviderKey where SpeechProvider(rawValue: value) == nil: continue
            case AppSettings.fishModelKey where FishModel(rawValue: value) == nil: continue
            default: break
            }
            if key == AppSettings.speechEnabledKey {
                let on = value == "true"
                if d.bool(forKey: key) != on { d.set(on, forKey: key); changed.append("Setting: \(key)") }
            } else if Self.stringSettings.contains(key), d.string(forKey: key) != value {
                d.set(value, forKey: key)
                changed.append("Setting: \(key)")
            }
        }
        return changed
    }

    private static func describe(from a: HybridConfig, to b: HybridConfig, newSounds: Bool) -> [String] {
        var out: [String] = []
        if a.colors != b.colors { out.append("Colors") }
        if a.appTitle != b.appTitle { out.append("App title") }
        if a.welcomeText != b.welcomeText { out.append("Welcome text") }
        if a.inputPlaceholder != b.inputPlaceholder { out.append("Message box text") }
        if a.baseSystemPrompt != b.baseSystemPrompt { out.append("System prompt") }
        if a.personalities != b.personalities { out.append("Personalities") }
        if a.sounds != b.sounds || newSounds { out.append("Sounds") }
        if nonEmpty(b.announcement) != nil { out.append("Announcement") }
        return out
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    /// Deletes sound files the current pack no longer uses.
    private func cleanSounds() {
        let used = Set((config.sounds ?? [:]).values)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: soundsDir.path)) ?? []
        for f in files where !used.contains(f) {
            try? FileManager.default.removeItem(at: soundsDir.appendingPathComponent(f))
        }
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}
