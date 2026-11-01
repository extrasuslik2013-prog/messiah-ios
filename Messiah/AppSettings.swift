import Foundation
import Security

enum ProviderKind: String, CaseIterable, Identifiable {
    case ollama, openrouter
    var id: String { rawValue }
    var label: String { self == .ollama ? "Ollama" : "OpenRouter" }
}

enum SpeechProvider: String, CaseIterable, Identifiable {
    case system, fish
    var id: String { rawValue }
    var label: String { self == .system ? "iPhone voice" : "Fish Audio" }
}

/// UserDefaults keys (same names as the original app) + Keychain for API keys.
enum AppSettings {
    static let providerKey = "provider"
    static let modelKey = "model"
    static let ollamaURLKey = "ollamaURL"
    static let speechEnabledKey = "speechEnabled"
    static let speechProviderKey = "speechProvider"
    static let fishVoiceIDKey = "fishVoiceID"
    static let fishModelKey = "fishModel"
    static let personalityKey = "personality"

    static let openRouterKeyName = "openrouter_api_key"
    static let fishKeyName = "fish_audio_api_key"

    static let defaultOllamaURL = "http://192.168.1.10:11434"
    static let openRouterBase = "https://openrouter.ai/api/v1"

    static let baseSystemPrompt = """
    You are Messiah, a practical mobile assistant. Be clear and concise.
    Never format any response as a table. Always use concise prose or simple headings.
    Never use emoji characters; if you want to express a feeling, use an occasional bracketed cue such as [happy], [thinking] or [laughing].
    """

    private static var d: UserDefaults { .standard }
    static var provider: ProviderKind { ProviderKind(rawValue: d.string(forKey: providerKey) ?? "") ?? .ollama }
    static var model: String { (d.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespaces) }
    static var ollamaURL: String { d.string(forKey: ollamaURLKey) ?? defaultOllamaURL }
    static var speechEnabled: Bool { d.bool(forKey: speechEnabledKey) }
    static var speechProvider: SpeechProvider { SpeechProvider(rawValue: d.string(forKey: speechProviderKey) ?? "") ?? .system }
    static var fishVoiceID: String { (d.string(forKey: fishVoiceIDKey) ?? "").trimmingCharacters(in: .whitespaces) }
    static var fishModel: String { d.string(forKey: fishModelKey) ?? FishModel.s1.rawValue }
    static var personality: String { (d.string(forKey: personalityKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Base rules + the personality written in Settings.
    static var systemPrompt: String {
        let p = personality
        guard !p.isEmpty else { return baseSystemPrompt }
        return baseSystemPrompt + "\n\nPersonality (stay in this character in every reply):\n" + p
    }
}

enum FishModel: String, CaseIterable, Identifiable {
    case s1 = "s1"
    case speech16 = "speech-1.6"
    case speech15 = "speech-1.5"
    var id: String { rawValue }
}

struct PersonalityPreset: Identifiable {
    let name: String
    let text: String
    var id: String { name }

    static let all: [PersonalityPreset] = [
        .init(name: "Default", text: ""),
        .init(name: "Friendly", text: "Warm, upbeat and encouraging. Talks casually, like a supportive friend who is genuinely happy to help."),
        .init(name: "Witty", text: "Playful and clever, with dry humour and the occasional light tease, but always actually helpful."),
        .init(name: "Mentor", text: "A patient teacher. Explains the why behind things step by step and checks that I understood."),
        .init(name: "Blunt", text: "Direct and to the point. Gives the answer first, no fluff, no hedging, no pep talk."),
        .init(name: "Calm", text: "Soft-spoken and grounding. Slow, reassuring, thoughtful replies that lower the stress level."),
        .init(name: "Hype", text: "High energy and motivating. Celebrates progress and pushes me to go further."),
    ]
}

enum Keychain {
    private static let service = "com.imronaripov.messiah"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func set(_ value: String, for account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
