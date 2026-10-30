import AppKit
import CoreMedia
import ScreenCaptureKit
import LuminaProtocol

/// Captures this Mac's system audio via ScreenCaptureKit (same Screen & System
/// Audio Recording grant as Ambient) and turns it into a stream of LED colors
/// (`AudioAnalyzer` + `AudioTracker`). Mirrors `ScreenSampler`: control methods
/// on the main thread, sample processing and the 30 Hz tick on a private serial
/// queue that owns the analyzer and tracker.
final class AudioSampler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Delivered on the main queue.
    var onColor: ((RGB) -> Void)?
    var onStatus: ((AmbientStatus) -> Void)?

    /// Set from the main thread; applied on the queue.
    var palette: AudioPalette = .bluePurple {
        didSet {
            let p = palette
            queue.async { self.tracker.palette = p }
        }
    }
    var customColor = RGB(r: 255, g: 40, b: 0) {
        didSet {
            let c = customColor
            queue.async { self.tracker.customColor = c }
        }
    }

    private static let sampleRate = 48_000
    private static let tickInterval: TimeInterval = 1.0 / 30

    private let queue = DispatchQueue(label: "lumina.audio.sampler")
    private var analyzer = AudioAnalyzer(sampleRate: Float(sampleRate))  // queue-confined
    private var tracker = AudioTracker()  // queue-confined
    private var mono: [Float] = []  // queue-confined scratch
    private var timer: DispatchSourceTimer?  // queue-confined

    // Main-thread state.
    private var stream: SCStream?
    private var active = false
    private var generation = 0

    // MARK: Control

    func start() {
        // Already running or starting. (Failure paths clear `active`, so a
        // later start() retries.)
        if active { return }
        stop()
        active = true
        generation += 1
        let gen = generation

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            active = false
            onStatus?(.needsPermission)
            return
        }
        onStatus?(.starting)

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard gen == self.generation else { return }
                // Audio capture still needs a display filter; any display will do.
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                        ?? content.displays.first else {
                    self.active = false
                    self.onStatus?(.failed("No display found"))
                    return
                }
                let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Self.sampleRate
                config.channelCount = 2
                // Video can't be turned off; make it as cheap as possible.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                // A screen output too, so ScreenCaptureKit doesn't log a
                // dropped-frame error per video frame; frames are ignored.
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                guard gen == self.generation else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.queue.async { self.startTimer() }
                self.onStatus?(.running)
            } catch {
                guard gen == self.generation else { return }
                self.active = false
                self.onStatus?(CGPreflightScreenCaptureAccess()
                               ? .failed(error.localizedDescription)
                               : .needsPermission)
            }
        }
    }

    func stop() {
        generation += 1
        if let s = stream {
            Task { try? await s.stopCapture() }
        }
        stream = nil
        active = false
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.tracker.reset()
            self.analyzer = AudioAnalyzer(sampleRate: Float(Self.sampleRate))
        }
        onStatus?(.stopped)
    }

    // MARK: Queue side

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.tickInterval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Runs on silence too (ScreenCaptureKit may deliver nothing when
            // nothing plays), so the fade-out gate still matures.
            let f = self.analyzer.features()
            guard let c = self.tracker.tick(f, at: CACurrentMediaTime()) else { return }
            DispatchQueue.main.async { self.onColor?(c) }
        }
        t.resume()
        timer = t
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let fmt = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        try? sampleBuffer.withAudioBufferList { abl, _ in
            guard channels > 0, let first = abl.first, first.mData != nil else { return }
            let frames = interleaved
                ? Int(first.mDataByteSize) / (4 * channels)
                : Int(first.mDataByteSize) / 4
            if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
            for i in 0..<frames { mono[i] = 0 }
            if interleaved {
                let p = first.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    for c in 0..<channels { mono[i] += p[i * channels + c] }
                }
            } else {
                for buf in abl {
                    guard let d = buf.mData else { continue }
                    let p = d.assumingMemoryBound(to: Float.self)
                    for i in 0..<min(frames, Int(buf.mDataByteSize) / 4) { mono[i] += p[i] }
                }
            }
            let scale = 1 / Float(interleaved ? channels : max(abl.count, 1))
            for i in 0..<frames { mono[i] *= scale }
            mono.withUnsafeBufferPointer { analyzer.push($0) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard stream === self.stream else { return }
            self.stream = nil
            self.active = false
            self.queue.async {
                self.timer?.cancel()
                self.timer = nil
            }
            self.onStatus?(.failed(error.localizedDescription))
        }
    }
}
