import Foundation
import AVFoundation

/// Switches the audio session between plain playback and mic + speaker.
enum AudioSessionMode {
    static func playback() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    static func record() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
        try? s.setActive(true, options: .notifyOthersOnDeactivation)
    }
}

/// The three bundled cues: processing loop, success ping, error ping.
@MainActor
final class SoundManager {
    static let shared = SoundManager()
    private var loop: AVAudioPlayer?
    private var cue: AVAudioPlayer?

    private func make(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }

    func startLoop() {
        try? AVAudioSession.sharedInstance().setActive(true)
        loop?.stop()
        loop = make("waves_loop")
        loop?.numberOfLoops = -1
        loop?.volume = 0.6
        loop?.play()
    }

    func stopLoop() {
        loop?.setVolume(0, fadeDuration: 0.25)
        let old = loop
        loop = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { old?.stop() }
    }

    func playSuccess() { play("success_ping_merged") }
    func playError() { play("waves_error_ping2") }

    private func play(_ name: String) {
        try? AVAudioSession.sharedInstance().setActive(true)
        cue = make(name)
        cue?.play()
    }
}

/// Reads answers aloud with the iPhone voice or Fish Audio.
@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speakSystem(_ text: String) {
        let u = AVSpeechUtterance(string: Self.clean(text))
        u.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
        try? AVAudioSession.sharedInstance().setActive(true)
        isSpeaking = true
        synth.speak(u)
    }

    func fishAudio(_ text: String, key: String, voiceID: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.fish.audio/v1/tts")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": Self.clean(text), "format": "mp3"]
        if !voiceID.isEmpty { body["reference_id"] = voiceID }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw ProviderError(message: "Fish Audio could not synthesize this response. Check the API key and account.")
        }
        return data
    }

    func play(_ data: Data) {
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
        isSpeaking = player?.play() ?? false
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isSpeaking = false }
    }

    /// Strip markdown symbols and [cue] tags so they aren't read aloud.
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\\[[a-zA-Z ]{1,20}\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_#`>]+", with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
