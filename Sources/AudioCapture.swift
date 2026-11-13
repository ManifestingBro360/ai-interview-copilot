import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

enum Speaker { case interviewer, me }

/// Captures both sides of the call as separate 16 kHz mono 16-bit PCM streams:
///   system audio  -> the interviewer (what Zoom/Meet/Teams plays)
///   microphone    -> you
/// Keeping them separate is what lets the app know who said what.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let systemQueue = DispatchQueue(label: "audio.system")
    private let micQueue = DispatchQueue(label: "audio.mic")
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converters: [SCStreamOutputType: AVAudioConverter] = [:]
    var onPCM: ((Speaker, Data) -> Void)?
    var onError: ((String) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        // Video is required by the API but unused: keep it as small and slow as possible.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, sb.isValid, let data = convert(sb, type: type) else { return }
        onPCM?(type == .audio ? .interviewer : .me, data)
    }

    /// The microphone arrives in the device's own format (often 48 kHz), so both
    /// streams go through a converter to the one format the transcriber expects.
    private func convert(_ sb: CMSampleBuffer, type: SCStreamOutputType) -> Data? {
        guard let desc = sb.formatDescription else { return nil }
        let inFormat = AVAudioFormat(cmAudioFormatDescription: desc)
        var out: Data?
        try? sb.withAudioBufferList { list, _ in
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: list.unsafePointer),
                  inBuf.frameLength > 0 else { return }
            if converters[type]?.inputFormat != inFormat {
                converters[type] = AVAudioConverter(from: inFormat, to: target)
            }
            let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * target.sampleRate / inFormat.sampleRate) + 64
            guard let conv = converters[type],
                  let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            if let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 {
                out = Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2)
            }
        }
        return out
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Audio capture stopped: \(error.localizedDescription)")
    }
}
