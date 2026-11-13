import AppKit
import SwiftUI
import AVFoundation

/// Appends a line to ~/.interviewcopilot/log.txt so a session can be reviewed afterwards.
func log(_ line: String) {
    let url = Config.dir.appendingPathComponent("log.txt")
    let stamp = ISO8601DateFormatter().string(from: Date())
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

    func start() {
        guard !config.deepgramKey.isEmpty, !config.anthropicKey.isEmpty else {
            status = "Add your keys to ~/.interviewcopilot/keys.json, then relaunch."
            return
        }
        let claude = Claude(key: config.anthropicKey, model: config.model, context: config.context)
        self.claude = claude
        Task { await claude.warmUp() }

        let dg = Deepgram(key: config.deepgramKey)
        dg.onPartial = { [weak self] t in Task { @MainActor in self?.hearing = t } }
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
                status = config.context.isEmpty
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
        var utterance = heard
        // Very short fragments ("okay", "right") are not worth a round trip.
        guard utterance.split(separator: " ").count >= 3 || utterance.count >= 8 else { return }
        current?.cancel()
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
        var buffer = ""
        log("INTERVIEWER \(utterance)")
        let asked = Date()
        current = Task {
            do {
                try await claude.answer(history: past, latest: utterance) { delta in
                    buffer += delta
                    let text = buffer
                    Task { @MainActor in
                        // "…" means "no answer needed": keep the previous answer on screen.
                        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !shown.isEmpty, !(shown.hasPrefix("…") && shown.count <= 3) else { return }
                        self.question = utterance
                        self.answer = text
                    }
                }
                log(String(format: "ANSWER (%.1fs) %@", Date().timeIntervalSince(asked), buffer.replacingOccurrences(of: "\n", with: " / ")))
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
