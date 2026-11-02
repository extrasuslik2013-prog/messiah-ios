import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.providerKey) private var provider = ProviderKind.ollama.rawValue
    @AppStorage(AppSettings.modelKey) private var model = ""
    @AppStorage(AppSettings.ollamaURLKey) private var ollamaURL = AppSettings.defaultOllamaURL
    @AppStorage(AppSettings.speechEnabledKey) private var speechEnabled = false
    @AppStorage(AppSettings.speechProviderKey) private var speechProvider = SpeechProvider.system.rawValue
    @AppStorage(AppSettings.fishVoiceIDKey) private var fishVoiceID = ""
    @AppStorage(AppSettings.fishModelKey) private var fishModel = FishModel.s1.rawValue
    @AppStorage(AppSettings.personalityKey) private var personality = ""
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system.rawValue

    @State private var openRouterKey = ""
    @State private var fishKey = ""
    @State private var hasOpenRouterKey = Keychain.get(AppSettings.openRouterKeyName) != nil
    @State private var hasFishKey = Keychain.get(AppSettings.fishKeyName) != nil

    var body: some View {
        NavigationStack {
            Form {
                providerSection

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    NavigationLink {
                        PersonalityView()
                    } label: {
                        HStack {
                            Label("Personality", systemImage: "sparkles")
                            Spacer()
                            Text(personalityName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                voiceSection

                Section {
                    NavigationLink {
                        SoundSettingsView()
                    } label: {
                        Label("Sound effects", systemImage: "speaker.wave.2")
                    }
                }

                Section {
                    NavigationLink {
                        UpdaterView()
                    } label: {
                        Label("Updater", systemImage: "arrow.triangle.2.circlepath")
                    }
                } footer: {
                    Text("Messiah \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
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
        // switch the open sheet right away too
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
    }

    private var personalityName: String {
        if personality.isEmpty { return "Default" }
        return PersonalityPreset.all.first { $0.text == personality }?.name ?? "Custom"
    }

    private var providerSection: some View {
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
                        Keychain.set(openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                     for: AppSettings.openRouterKeyName)
                        openRouterKey = ""
                        hasOpenRouterKey = true
                    }
                }
                TextField("Model ID (e.g. openai/gpt-4o-mini)", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private var voiceSection: some View {
        Section {
            Picker("Voice", selection: $speechProvider) {
                ForEach(SpeechProvider.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            if speechProvider == SpeechProvider.fish.rawValue {
                SecureField(hasFishKey ? "Fish key saved • enter to replace" : "Fish Audio API key",
                            text: $fishKey)
                if !fishKey.isEmpty {
                    Button("Save Fish Audio key") {
                        Keychain.set(fishKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                     for: AppSettings.fishKeyName)
                        fishKey = ""
                        hasFishKey = true
                    }
                }
                TextField("Voice ID (blank for default)", text: $fishVoiceID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Fish model", selection: $fishModel) {
                    ForEach(FishModel.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
            }

            VoiceTestRow()

            Toggle("Read answers aloud in text chat", isOn: $speechEnabled)
        } header: {
            Text("Voice")
        } footer: {
            Text(speechProvider == SpeechProvider.fish.rawValue
                 ? "Live chat always talks with this voice. The Voice ID is the model ID from a voice's page on fish.audio. If Fish Audio fails, Messiah tells you why and uses the iPhone voice."
                 : "Live chat always talks with this voice.")
        }
    }
}

/// "Test voice" button that plays a short line and shows any error.
private struct VoiceTestRow: View {
    @StateObject private var speech = SpeechService()
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Label(testing ? "Testing…" : "Test voice", systemImage: "play.circle")
                    if testing { Spacer(); ProgressView() }
                }
            }
            .disabled(testing)
            if let result {
                Text(result)
                    .font(.footnote)
                    .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.red)
            }
        }
    }

    private func test() async {
        testing = true
        result = nil
        speech.stop()
        AudioSessionMode.playback()
        var problem: String?
        await speech.speakWithChosenVoice("Hi, I'm Messiah. This is how I sound.") { problem = $0 }
        testing = false
        if let problem {
            result = problem
        } else {
            result = AppSettings.speechProvider == .fish ? "✓ Fish Audio is working." : "✓ iPhone voice is working."
        }
    }
}

struct SoundSettingsView: View {
    @AppStorage(Sfx.masterKey) private var master = true

    var body: some View {
        Form {
            Section {
                Toggle("Sound effects", isOn: $master)
            }
            if master {
                Section {
                    ForEach(Sfx.allCases) { SfxRow(sfx: $0) }
                } footer: {
                    Text("Tap the play button to hear a sound.")
                }
            }
        }
        .navigationTitle("Sound effects")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SfxRow: View {
    let sfx: Sfx
    @AppStorage private var isOn: Bool

    init(sfx: Sfx) {
        self.sfx = sfx
        self._isOn = AppStorage(wrappedValue: true, sfx.key)
    }

    var body: some View {
        HStack {
            Button {
                AudioSessionMode.playback()
                SoundManager.shared.preview(sfx)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.magenta)
            }
            .buttonStyle(.borderless)
            Toggle(sfx.label, isOn: $isOn)
        }
    }
}
