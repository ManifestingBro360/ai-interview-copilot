import Foundation

/// Streams an answer from Claude. The candidate context sits in a cached system block,
/// so each question only pays for (and waits on) the few new tokens.
final class Claude {
    private let key: String
    private let model: String
    private let context: String

    init(key: String, model: String, context: String) {
        self.key = key
        self.model = model
        self.context = context
    }

    private func request(user: String, maxTokens: Int, stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream,
            // No thinking step: it delays the first words by about half a second.
            // Haiku accepts "disabled"; larger models call the same thing "between_tools".
            "thinking": ["type": model.contains("haiku") ? "disabled" : "between_tools"],
            "system": [
                ["type": "text", "text": systemInstructions],
                ["type": "text",
                 "text": "CANDIDATE CONTEXT\n\n" + (context.isEmpty ? "(none provided)" : context),
                 "cache_control": ["type": "ephemeral"]],
            ],
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Fills the prompt cache so the first real question is fast.
    func warmUp() async {
        guard let req = try? request(user: "ping", maxTokens: 1, stream: false) else { return }
        _ = try? await URLSession.shared.data(for: req)
    }

    func answer(history: [String], latest: String, onDelta: @escaping (String) -> Void) async throws {
        var user = ""
        if !history.isEmpty {
            user += "Conversation so far (oldest first):\n" + history.joined(separator: "\n") + "\n\n"
        }
        user += "The INTERVIEWER just said:\n\(latest)"

        let (bytes, response) = try await URLSession.shared.bytes(for: try request(user: user, maxTokens: 500, stream: true))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw NSError(domain: "Claude", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Claude API \(http.statusCode): \(body.prefix(300))"])
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "),
                  let j = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  j["type"] as? String == "content_block_delta",
                  let delta = j["delta"] as? [String: Any],
                  let text = delta["text"] as? String else { continue }
            onDelta(text)
        }
    }
}
