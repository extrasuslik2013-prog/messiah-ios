import SwiftUI

/// Settings > Updater: pairing code, connection status and the installed pack.
struct UpdaterView: View {
    @ObservedObject private var server = UpdateServer.shared
    @ObservedObject private var hybrid = HybridStore.shared
    @AppStorage(UpdateServer.enabledKey) private var enabled = true
    @State private var wifi = UpdateServer.wifiAddress()
    @State private var confirmReset = false
    @State private var confirmForget = false

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Accept updates from computer", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on { server.start() } else { server.stop() }
                    }
            } footer: {
                Text("While Messiah is open, Messiah Updater on your PC can connect over Wi-Fi or USB to change colors, text, sounds, the AI prompt and personalities, or send a whole new IPA.")
            }

            if enabled {
                Section {
                    LabeledContent("Status", value: server.status)
                    LabeledContent("Wi-Fi address", value: wifi.map { "\($0):\(UpdateServer.port)" } ?? "Not on Wi-Fi")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pairing code")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(server.pairingCode)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Connect")
                } footer: {
                    Text("Enter this code in Messiah Updater the first time you connect. Keep this screen or the chat open while updating.")
                }
            }

            Section("Installed") {
                LabeledContent("App version", value: appVersion)
                LabeledContent("Update pack", value: hybrid.packLabel)
                if let date = hybrid.config.appliedAt {
                    LabeledContent("Applied", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let event = server.lastEvent {
                    Text(event)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Remove update pack", role: .destructive) { confirmReset = true }
                    .disabled(hybrid.config.packVersion == nil)
                Button("Forget paired computers", role: .destructive) { confirmForget = true }
            }
        }
        .navigationTitle("Updater")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            wifi = UpdateServer.wifiAddress()
            server.start()
        }
        .confirmationDialog("Go back to the built-in look, text, sounds and prompt?",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Remove update pack", role: .destructive) { hybrid.reset() }
        }
        .confirmationDialog("The Updater will need the pairing code again.",
                            isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget paired computers", role: .destructive) { server.forgetComputers() }
        }
    }
}
