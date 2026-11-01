import Foundation
import AVFoundation

/// Switches the audio session between plain playback and mic + speaker.
enum AudioSessionMode {
    static func playback() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    static func record() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
        try s.setActive(true)
    }
}

/// Every sound effect, each with its own on/off switch in Settings.
enum Sfx: String, CaseIterable, Identifiable {
    case thinking, liveOpen, liveClose, mic, interrupt, error

    var id: String { rawValue }
    var key: String { "sfx_" + rawValue }

    var label: String {
        switch self {
        case .thinking: return "Thinking loop"
        case .liveOpen: return "Live chat opens"
        case .liveClose: return "Live chat closes"
        case .mic: return "Mic on / off"
        case .interrupt: return "Interrupt / cancel"
        case .error: return "Error"
        }
    }

    var file: String {
        switch self {
        case .thinking: return "messiah_processing_loop"
        case .liveOpen: return "messiah_wake"
        case .liveClose: return "messiah_window_close"
        case .mic: return "messiah_mic_on"
        case .interrupt: return "messiah_interrupt"
        case .error: return "waves_error_ping2"
        }
    }

    static let masterKey = "sfx_enabled"

    static var defaults: [String: Any] {
        var d: [String: Any] = [masterKey: true]
        for s in allCases { d[s.key] = true }
        return d
    }

    var isOn: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: Sfx.masterKey) && d.bool(forKey: key)
    }
}

@MainActor
final class SoundManager {
    static let shared = SoundManager()
    private var loop: AVAudioPlayer?
    private var cues: [AVAudioPlayer] = []

    private func make(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav")
                ?? Bundle.main.url(forResource: name, withExtension: "mp3") else { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }

    /// Thinking loop (text chat and live chat).
    func startLoop() {
        loop?.stop()
        loop = nil
        guard Sfx.thinking.isOn else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        loop = make(Sfx.thinking.file)
        loop?.numberOfLoops = -1
        loop?.volume = 0.7
        loop?.play()
    }

    func stopLoop() {
        guard let old = loop else { return }
        loop = nil
        old.setVolume(0, fadeDuration: 0.25)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { old.stop() }
    }

    func playError() { play(.error) }
    func micOn() { play(.mic, file: "messiah_mic_on") }
    func micOff() { play(.mic, file: "messiah_mic_off") }
    func liveOpen() { play(.liveOpen) }
    func liveClose() { play(.liveClose) }
    func interrupt() { play(.interrupt) }

    /// Plays any effect regardless of its switch (used by the Settings preview).
    func preview(_ s: Sfx) { play(s, force: true) }

    private func play(_ s: Sfx, file: String? = nil, force: Bool = false) {
        guard force || s.isOn else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        cues.removeAll { !$0.isPlaying }
        guard let p = make(file ?? s.file) else { return }
        p.volume = 0.8
        p.play()
        cues.append(p)
        if s == .thinking, force {
            // preview only a few seconds of the loop
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { p.setVolume(0, fadeDuration: 0.3) }
        }
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

    /// Fish Audio text-to-speech. Returns MP3 data.
    func fishAudio(_ text: String, key: String, voiceID: String, model: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.fish.audio/v1/tts")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !model.isEmpty { req.setValue(model, forHTTPHeaderField: "model") }
        var body: [String: Any] = [
            "text": Self.clean(text),
            "format": "mp3",
            "latency": "normal",
        ]
        if !voiceID.isEmpty { body["reference_id"] = voiceID }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code != .cancelled {
            throw ProviderError(message: "Could not reach Fish Audio (\(e.localizedDescription)).")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            throw ProviderError(message: Self.fishError(status: status, body: data))
        }
        return data
    }

    private static func fishError(status: Int, body: Data) -> String {
        var detail = ""
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            detail = (obj["message"] as? String) ?? (obj["detail"] as? String) ?? ""
        } else if let s = String(data: body.prefix(200), encoding: .utf8) {
            detail = s
        }
        switch status {
        case 401, 403: return "Fish Audio rejected the API key. Check it in Settings."
        case 402: return "Your Fish Audio account is out of credit."
        case 404: return "Fish Audio couldn't find that voice ID."
        case 429: return "Fish Audio is rate limiting requests. Try again shortly."
        default:
            return "Fish Audio failed (HTTP \(status))" + (detail.isEmpty ? "." : ": \(detail)")
        }
    }

    func play(_ data: Data) throws {
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = try AVAudioPlayer(data: data)
        p.delegate = self
        player = p
        isSpeaking = p.play()
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

/// Speaks `text` with the voice chosen in Settings. Falls back to the
/// iPhone voice (and reports why) if Fish Audio fails.
extension SpeechService {
    func speakWithChosenVoice(_ text: String, notice: (String) -> Void) async {
        guard AppSettings.speechProvider == .fish else {
            speakSystem(text)
            return
        }
        guard let key = Keychain.get(AppSettings.fishKeyName) else {
            notice("Add your Fish Audio API key in Settings. Using the iPhone voice for now.")
            speakSystem(text)
            return
        }
        do {
            let audio = try await fishAudio(text, key: key, voiceID: AppSettings.fishVoiceID, model: AppSettings.fishModel)
            if Task.isCancelled { return }
            try play(audio)
        } catch {
            if Task.isCancelled { return }
            notice(error.localizedDescription + " Using the iPhone voice instead.")
            speakSystem(text)
        }
    }
}
