import Foundation

/// Streaming speech-to-text. Emits partial text while the interviewer talks and a
/// complete utterance once Deepgram's endpointing decides they have stopped.
final class Deepgram {
    private let key: String
    private var task: URLSessionWebSocketTask?
    private var utterance = ""
    private var keepAlive: Timer?
    var onPartial: ((String) -> Void)?
    var onUtterance: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    init(key: String) { self.key = key }

    func connect() {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            ("model", "nova-3"), ("language", "multi"), ("encoding", "linear16"),
            ("sample_rate", "16000"), ("channels", "1"), ("interim_results", "true"),
            ("endpointing", "400"), ("smart_format", "true"), ("utterance_end_ms", "1000"),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        // Names and jargon the transcriber should recognise (one per line in keyterms.txt).
        let terms = (try? String(contentsOf: Config.dir.appendingPathComponent("keyterms.txt"), encoding: .utf8)) ?? ""
        for term in terms.split(separator: "\n") where !term.trimmingCharacters(in: .whitespaces).isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "keyterm", value: term.trimmingCharacters(in: .whitespaces)))
        }
        var req = URLRequest(url: comps.url!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        receive(on: t)
        DispatchQueue.main.async { [weak self] in guard let self else { return }
            self.keepAlive?.invalidate()
            self.keepAlive = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.task?.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
            }
        }
    }

    func send(_ pcm: Data) {
        task?.send(.data(pcm)) { _ in }
    }

    /// Text heard so far in the current, not-yet-finished utterance.
    func flush() -> String {
        defer { utterance = "" }
        return utterance
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure(let err):
                self.onStatus?("Transcription disconnected (\(err.localizedDescription)). Reconnecting…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.connect() }
            case .success(let msg):
                if case .string(let text) = msg { self.handle(text) }
                self.receive(on: t)
            }
        }
    }

    private func handle(_ text: String) {
        guard let j = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        // Fallback: Deepgram reports a word gap even when its endpointing did not fire.
        if j["type"] as? String == "UtteranceEnd", !utterance.isEmpty {
            let done = utterance
            utterance = ""
            onUtterance?(done)
            return
        }
        guard j["type"] as? String == "Results",
              let channel = j["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let transcript = alts.first?["transcript"] as? String else { return }
        let isFinal = j["is_final"] as? Bool ?? false
        if ProcessInfo.processInfo.environment["COPILOT_DEBUG"] != nil, !transcript.isEmpty {
            log("DG final=\(isFinal) speech_final=\(j["speech_final"] as? Bool ?? false) \(transcript)")
        }
        let speechFinal = j["speech_final"] as? Bool ?? false

        if isFinal, !transcript.isEmpty {
            utterance += (utterance.isEmpty ? "" : " ") + transcript
        }
        let live = isFinal ? utterance : utterance + (utterance.isEmpty ? "" : " ") + transcript
        if !live.isEmpty { onPartial?(live) }

        if speechFinal, !utterance.isEmpty {
            let done = utterance
            utterance = ""
            onUtterance?(done)
        }
    }
}
