import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.providerKey) private var provider = ProviderKind.ollama.rawValue
    @AppStorage(AppSettings.modelKey) private var model = ""
    @AppStorage(AppSettings.ollamaURLKey) private var ollamaURL = AppSettings.defaultOllamaURL
    @AppStorage(AppSettings.speechEnabledKey) private var speechEnabled = false
    @AppStorage(AppSettings.speechProviderKey) private var speechProvider = SpeechProvider.system.rawValue
    @AppStorage(AppSettings.fishVoiceIDKey) private var fishVoiceID = ""

    @State private var openRouterKey = ""
    @State private var fishKey = ""
    @State private var hasOpenRouterKey = Keychain.get(AppSettings.openRouterKeyName) != nil
    @State private var hasFishKey = Keychain.get(AppSettings.fishKeyName) != nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $provider) {
                        ForEach(ProviderKind.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)

                    if provider == ProviderKind.ollama.rawValue {
                        TextField("Server (e.g. http://192.168.1.10:11434)", text: $ollamaURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Model (e.g. llama3.2)", text: $model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(hasOpenRouterKey ? "API key saved • enter to replace" : "OpenRouter API key",
                                    text: $openRouterKey)
                        if !openRouterKey.isEmpty {
                            Button("Save API key") {
                                Keychain.set(openRouterKey, for: AppSettings.openRouterKeyName)
                                openRouterKey = ""
                                hasOpenRouterKey = true
                            }
                        }
                        TextField("Model ID (e.g. openai/gpt-4o-mini)", text: $model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Toggle("Read answers aloud", isOn: $speechEnabled)
                    if speechEnabled {
                        Picker("Voice", selection: $speechProvider) {
                            ForEach(SpeechProvider.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        if speechProvider == SpeechProvider.fish.rawValue {
                            SecureField(hasFishKey ? "Fish key saved • enter to replace" : "Fish Audio API key",
                                        text: $fishKey)
                            if !fishKey.isEmpty {
                                Button("Save Fish Audio key") {
                                    Keychain.set(fishKey, for: AppSettings.fishKeyName)
                                    fishKey = ""
                                    hasFishKey = true
                                }
                            }
                            TextField("Voice ID (blank for default)", text: $fishVoiceID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } header: {
                    Text("Speech")
                } footer: {
                    if speechEnabled && speechProvider == SpeechProvider.fish.rawValue {
                        Text("With Fish Audio, the processing loop keeps playing until the full answer audio is ready, then the success cue plays before speech starts.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
