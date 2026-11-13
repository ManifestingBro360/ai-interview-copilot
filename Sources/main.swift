import AppKit
import SwiftUI
import AVFoundation

/// Appends a line to ~/.interviewcopilot/log.txt so a session can be reviewed afterwards.
func log(_ line: String) {
    let url = Config.dir.appendingPathComponent("log.txt")
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = f.string(from: Date())
    guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try? data.write(to: url) }
}

/// True when two transcripts are mostly the same words: the microphone picking up
/// the interviewer's voice from the speakers rather than the candidate talking.
func isEcho(_ a: String, _ b: String) -> Bool {
    func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    let x = words(a), y = words(b)
    guard !x.isEmpty, !y.isEmpty else { return false }
    return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.7
}

/// Letters and digits only, lower-cased: used to compare a romaji sentence with the vetted ones.
func normalised(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

func isEnglishOrJapanese(_ s: String) -> Bool {
    s.unicodeScalars.allSatisfy { u in
        u.value < 0x250 || (0x2000...0x206F).contains(u.value) || (0x3000...0x30FF).contains(u.value)
            || (0x4E00...0x9FFF).contains(u.value) || (0xFF00...0xFFEF).contains(u.value)
    }
}

/// Removes stray characters from other scripts that the transcriber sometimes prepends.
func cleaned(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { u in isEnglishOrJapanese(String(u)) }))
        .trimmingCharacters(in: .whitespaces)
}

func isJapanese(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
}

typealias Vetted = [(words: Set<String>, original: String)]

func wordSet(_ s: String) -> Set<String> {
    Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
}

/// For answers to Japanese questions: every romaji sentence is replaced by the closest sentence that
/// appears in the user's context files, and dropped if nothing is close. The model sometimes invents
/// or rewords Japanese with wrong words, and the user cannot check it.
func keepVettedRomaji(_ text: String, vetted: Vetted, kana: [String: String], mode: String, finished: Bool) -> String {
    let fallback = "Sumimasen, kore wa eigo de kotaemasu."
    var lines = text.components(separatedBy: "\n")
    if !finished, !lines.isEmpty { lines.removeLast() }      // last line may still be streaming
    var out: [String] = []
    var english = false, dropped = false, kept = 0
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("Q:") || t.hasPrefix("(EN:") || english { out.append(line); continue }
        var safe: [String] = []
        for part in t.components(separatedBy: ". ") {
            let words = wordSet(part).subtracting(["hai"])
            guard !words.isEmpty else { continue }
            let best = vetted.map { v in (Double(v.words.intersection(words).count) / Double(v.words.union(words).count), v.original) }
                .max { $0.0 < $1.0 }
            if let best, best.0 >= 0.6 { safe.append(best.1) } else { dropped = true }
        }
        guard !safe.isEmpty else { continue }
        let rebuilt = safe.joined(separator: " ")
        // Show the vetted sentence in spaced kana, in romaji, or both, as the user prefers.
        let inKana = safe.map { kana[normalised($0)] ?? $0 }.joined(separator: " ")
        switch mode {
        case "romaji": out.append(rebuilt)
        case "hiragana": out.append(inKana)
        default: out.append(inKana); if inKana != rebuilt { out.append(rebuilt) }; out.append("")
        }
        kept += 1
        if normalised(rebuilt).contains(normalised("kore wa eigo de kotaemasu")) { english = true }
    }
    if dropped, kept == 0, let q = out.firstIndex(where: { $0.hasPrefix("Q:") }) {
        let shown = mode == "romaji" ? [fallback] : mode == "hiragana" ? [kana[normalised(fallback)] ?? fallback]
            : [kana[normalised(fallback)] ?? fallback, fallback]
        out.insert(contentsOf: [""] + shown, at: q + 1)
    }
    // Some Japanese was removed, so the English meaning below no longer matches what is shown.
    // Add the "I'll answer in English" line; the (EN: …) text then serves as the English answer.
    if dropped, kept > 0, !english, let en = out.firstIndex(where: { $0.hasPrefix("(EN:") }) {
        let shown = mode == "romaji" ? [fallback] : mode == "hiragana" ? [kana[normalised(fallback)] ?? fallback]
            : [kana[normalised(fallback)] ?? fallback, fallback]
        out.insert(contentsOf: shown + [""], at: en)
    }
    return out.joined(separator: "\n")
}

@MainActor
final class AppState: ObservableObject {
    @Published var status = "Starting…" { didSet { log("STATUS \(status)") } }
    @Published var hearing = ""
    @Published var question = ""
    @Published var answer = ""

    private var config = Config.load()
    private let audio = AudioCapture()
    private var deepgram: Deepgram?      // interviewer (system audio)
    private var myDeepgram: Deepgram?    // me (microphone)
    private var claude: Claude?
    private var history: [String] = []
    private var current: Task<Void, Never>?
    private var lastInterviewer: (text: String, at: Date)?
    private var spokeSinceInterviewer = false
    private var currentKey = ""      // the question the running answer is for, normalised
    private var generation = 0       // guards against a cancelled answer writing to the screen late
    private lazy var vettedRomaji: Vetted = config.contextJapanese.components(separatedBy: "\n")
        .filter { !$0.hasPrefix("(EN:") && !$0.hasPrefix("#") }
        .flatMap { $0.components(separatedBy: ". ") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.count > 8 }
        .map { (wordSet($0), $0.hasSuffix(".") || $0.hasSuffix("?") ? $0 : $0 + ".") }

    func start() {
        guard !config.deepgramKey.isEmpty, !config.anthropicKey.isEmpty else {
            status = "Add your keys to ~/.interviewcopilot/keys.json, then relaunch."
            return
        }
        let claude = Claude(key: config.anthropicKey, model: config.model, context: config.context, japanese: config.contextJapanese)
        self.claude = claude
        Task { await claude.warmUp() }
        // The provider forgets the cached context after 5 idle minutes. A tiny request every 4 minutes
        // keeps it (and the network connection) warm, so no question pays the slow cold-start.
        Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { _ in Task { await claude.warmUp() } }

        let dg = Deepgram(key: config.deepgramKey)
        dg.onPartial = { [weak self] t in Task { @MainActor in self?.hearing = t; self?.speculate(t) } }
        dg.onUtterance = { [weak self] t in Task { @MainActor in self?.respond(to: t) } }
        dg.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        dg.connect()
        deepgram = dg

        // My own speech is only recorded into the conversation history; it never triggers an answer.
        let mine = Deepgram(key: config.deepgramKey)
        mine.onUtterance = { [weak self] t in Task { @MainActor in self?.heardMe(t) } }
        mine.connect()
        myDeepgram = mine

        audio.onPCM = { [weak dg, weak mine] speaker, data in
            (speaker == .interviewer ? dg : mine)?.send(data)
        }
        audio.onError = { [weak self] s in Task { @MainActor in self?.status = s } }
        Task {
            // Ask for both permissions explicitly so macOS shows its prompts on first launch.
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            let screen = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
            log("PERMISSIONS microphone=\(mic) screen=\(screen)")
            do {
                try await audio.start()
                status = config.context.isEmpty && config.contextJapanese.isEmpty
                    ? "Listening. No context files found in ~/.interviewcopilot/context"
                    : "Listening · \(config.context.count / 1000)k chars of context"
            } catch {
                log("CAPTURE ERROR \(error)")
                status = "Can't capture audio: allow Screen & System Audio Recording and Microphone in System Settings, then relaunch."
            }
        }
    }

    private func heardMe(_ text: String) {
        // Ignore the interviewer's voice leaking from the speakers into the microphone.
        if history.suffix(4).contains(where: { $0.hasPrefix("INTERVIEWER: ") && isEcho($0.dropFirst(13).description, text) }) {
            log("ECHO IGNORED \(text)")
            return
        }
        // Background voices get transcribed in whatever language they resemble. The candidate speaks
        // English and Japanese, so anything in another script is noise, not an answer.
        guard isEnglishOrJapanese(text) else { log("NOISE IGNORED \(text)"); return }
        history.append("CANDIDATE: \(text)")
        spokeSinceInterviewer = true
        log("CANDIDATE \(text)")
    }

    /// Manual trigger for when the interviewer pauses mid-thought and you want an answer now.
    func answerNow() {
        let text = deepgram?.flush() ?? ""
        if !text.isEmpty { respond(to: text) }
    }

    private func respond(to heard: String) {
        guard let claude else { return }
        var utterance = cleaned(heard)
        // Very short fragments ("okay", "right") are not worth a round trip.
        guard utterance.split(separator: " ").count >= 3 || utterance.count >= 8 else { return }
        // Include whatever I am saying right now, even if I have not paused yet.
        if let mid = myDeepgram?.flush(), !mid.isEmpty, !isEcho(mid, utterance) { history.append("CANDIDATE: \(mid)") }
        // The microphone sometimes finishes first: drop its copy of this same utterance.
        let recent = history.count - min(history.count, 3)
        history = history.enumerated().filter { i, line in
            !(i >= recent && line.hasPrefix("CANDIDATE: ") && isEcho(line.dropFirst(11).description, utterance))
        }.map(\.element)
        // The interviewer paused and then carried on: treat both parts as one question,
        // so the answer covers the whole thing instead of only the last fragment.
        if let last = lastInterviewer, !spokeSinceInterviewer, Date().timeIntervalSince(last.at) < 8,
           history.last == "INTERVIEWER: \(last.text)" {
            history.removeLast()
            utterance = last.text + " " + utterance
            log("CONTINUED")
        }
        lastInterviewer = (utterance, Date())
        spokeSinceInterviewer = false
        let past = Array(history.suffix(14))
        history.append("INTERVIEWER: \(utterance)")
        hearing = ""
        log("INTERVIEWER \(utterance)")
        if currentKey == normalised(utterance) {
            // The early start already asked exactly this question: keep its answer streaming.
            log("EARLY START USED")
        } else {
            launch(utterance, past: past)
        }
    }

    /// Starts answering as soon as the live transcript looks like a finished question, without waiting
    /// for the pause that confirms it. If the confirmed question turns out the same, the answer is
    /// already on screen; if not, it is replaced.
    private func speculate(_ live: String) {
        let t = live.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("?") || t.hasSuffix("？") || t.hasSuffix("か。") else { return }
        guard t.split(separator: " ").count >= 4 || (isJapanese(t) && t.count >= 8) else { return }
        guard normalised(t) != currentKey else { return }
        var past = Array(history.suffix(14))
        var text = t
        if let last = lastInterviewer, !spokeSinceInterviewer, Date().timeIntervalSince(last.at) < 8,
           past.last == "INTERVIEWER: \(last.text)" {
            past.removeLast()
            text = last.text + " " + t
            guard normalised(text) != currentKey else { return }
        }
        launch(text, past: past)
    }

    private func launch(_ utterance: String, past: [String]) {
        guard let claude else { return }
        current?.cancel()
        currentKey = normalised(utterance)
        generation += 1
        let gen = generation
        var buffer = ""
        let japanese = isJapanese(utterance)
        let vetted = vettedRomaji
        let kana = config.kana, mode = config.japanese
        let asked = Date()
        current = Task {
            do {
                try await claude.answer(history: past, latest: utterance, japanese: japanese) { delta in
                    buffer += delta
                    let text = japanese ? keepVettedRomaji(buffer, vetted: vetted, kana: kana, mode: mode, finished: false) : buffer
                    Task { @MainActor in
                        // "…" means "no answer needed": keep the previous answer on screen.
                        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard gen == self.generation, !shown.isEmpty, !(shown.hasPrefix("…") && shown.count <= 3) else { return }
                        self.question = utterance
                        self.answer = text
                    }
                }
                guard gen == self.generation else { return }
                if japanese {
                    buffer = keepVettedRomaji(buffer, vetted: vetted, kana: kana, mode: mode, finished: true)
                    if !buffer.isEmpty { self.question = utterance; self.answer = buffer }
                }
                log(String(format: "ANSWER (%.1fs from start) %@", Date().timeIntervalSince(asked), buffer.replacingOccurrences(of: "\n", with: " / ")))
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
    }
}

struct OverlayView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                Spacer()
                Button("Answer now") { state.answerNow() }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                Button("✕") { NSApp.terminate(nil) }.buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6)).accessibilityLabel("Quit")
            }
            if !state.hearing.isEmpty {
                Text(state.hearing).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
            }
            if !state.question.isEmpty {
                Text(state.question).font(.system(size: 12, weight: .medium)).foregroundStyle(.cyan.opacity(0.9)).lineLimit(3)
            }
            ScrollView {
                Text(state.answer).font(.system(size: 16)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.82)))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    let state = AppState()

    func applicationDidFinishLaunching(_ note: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 460, height: 300)
        panel = NSPanel(
            contentRect: NSRect(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        panel.sharingType = .none            // excluded from screen sharing and screenshots
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayView(state: state))
        panel.orderFrontRegardless()
        state.start()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no app switcher entry
    app.run()
}
