import Foundation

struct ProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Streams replies from any OpenAI-compatible /chat/completions endpoint
/// (Ollama's /v1 API or OpenRouter).
struct ChatProvider {
    let base: URL
    let apiKey: String?
    let model: String

    static func fromSettings() throws -> ChatProvider {
        let model = AppSettings.model
        guard !model.isEmpty else {
            throw ProviderError(message: "Choose a model in Settings before sending a message.")
        }
        switch AppSettings.provider {
        case .ollama:
            var raw = AppSettings.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.lowercased().hasPrefix("http") { raw = "http://" + raw }
            while raw.hasSuffix("/") { raw.removeLast() }
            if raw.hasSuffix("/v1") { raw.removeLast(3) }
            guard let url = URL(string: raw + "/v1"), url.host != nil else {
                throw ProviderError(message: "The Ollama server address is invalid.")
            }
            return ChatProvider(base: url, apiKey: nil, model: model)
        case .openrouter:
            guard let key = Keychain.get(AppSettings.openRouterKeyName) else {
                throw ProviderError(message: "Add your OpenRouter API key in Settings.")
            }
            return ChatProvider(base: URL(string: AppSettings.openRouterBase)!, apiKey: key, model: model)
        }
    }

    func stream(_ messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 45
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let apiKey {
                        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        req.setValue("Messiah", forHTTPHeaderField: "X-Title")
                    }
                    let body: [String: Any] = ["model": model, "stream": true, "messages": messages]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let result: (URLSession.AsyncBytes, URLResponse)
                    do {
                        result = try await URLSession.shared.bytes(for: req)
                    } catch let e as URLError where e.code != .cancelled {
                        throw ProviderError(message: "Could not reach the provider (\(e.localizedDescription)).")
                    }
                    let (bytes, response) = result
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        switch status {
                        case 401, 403: throw ProviderError(message: "The API key was rejected. Check it in Settings.")
                        case 404: throw ProviderError(message: "The selected model was not found.")
                        case 429: throw ProviderError(message: "The provider is rate limiting requests. Try again shortly.")
                        default: throw ProviderError(message: "The provider returned an error (HTTP \(status)).")
                        }
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let err = obj["error"] as? [String: Any] {
                            throw ProviderError(message: err["message"] as? String ?? "The provider returned an error.")
                        }
                        if let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let piece = delta["content"] as? String, !piece.isEmpty {
                            continuation.yield(piece)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
