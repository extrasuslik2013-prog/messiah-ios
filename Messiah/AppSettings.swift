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

    static let openRouterKeyName = "openrouter_api_key"
    static let fishKeyName = "fish_audio_api_key"

    static let defaultOllamaURL = "http://192.168.1.10:11434"
    static let openRouterBase = "https://openrouter.ai/api/v1"

    static let systemPrompt = """
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
