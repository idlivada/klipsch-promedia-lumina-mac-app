import AppKit
import CoreMedia
import ScreenCaptureKit
import LuminaProtocol

enum AmbientStatus: Equatable {
    case stopped
    case starting
    case running
    case needsPermission
    case failed(String)
}

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

/// Captures one display at a tiny resolution via ScreenCaptureKit and turns it
/// into a stream of LED colors (`AmbientColor` + `AmbientTracker`). Control
/// methods are called on the main thread; frame processing and the smoothing
/// timer run on a private serial queue that owns the tracker.
final class ScreenSampler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Delivered on the main queue.
    var onColor: ((RGB) -> Void)?
    var onStatus: ((AmbientStatus) -> Void)?

    /// Captured at this width (height follows the display's aspect so
    /// ScreenCaptureKit never adds its own bars), then box-averaged 2×2.
    private static let captureWidth = 128
    private static let framesPerSecond: Int32 = 20
    private static let tickInterval: TimeInterval = 1.0 / 30

    private let queue = DispatchQueue(label: "lumina.ambient.sampler")
    private var tracker = AmbientTracker()  // queue-confined
    private var lastFrame: AmbientFrame?  // queue-confined
    private var timer: DispatchSourceTimer?  // queue-confined

    // Main-thread state.
    private var stream: SCStream?
    private var displayID: CGDirectDisplayID?
    private var generation = 0

    // MARK: Control

    /// Starts (or retargets) capture. `nil` = main display.
    func start(displayID requested: CGDirectDisplayID?) {
        let target = requested ?? CGMainDisplayID()
        // Already running or starting on this display. (Failure paths clear
        // displayID, so a later start() retries.)
        if displayID == target { return }
        stop()
        displayID = target
        generation += 1
        let gen = generation

        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt once; access only takes effect after relaunch.
            CGRequestScreenCaptureAccess()
            displayID = nil
            onStatus?(.needsPermission)
            return
        }
        onStatus?(.starting)

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard gen == self.generation else { return }
                guard let display = content.displays.first(where: { $0.displayID == target })
                        ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    self.displayID = nil
                    self.onStatus?(.failed("No display found"))
                    return
                }
                // Keep our own popover (color swatches, wheel) out of the sample.
                let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.width = Self.captureWidth
                config.height = max(2, Int((Double(Self.captureWidth) * Double(display.height) / Double(display.width)).rounded()))
                config.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.showsCursor = false
                config.queueDepth = 3

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
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
                self.displayID = nil
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
        displayID = nil
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.tracker.reset()
            self.lastFrame = nil
        }
        onStatus?(.stopped)
    }

    static func displays() -> [DisplayInfo] {
        let screens = NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(n.uint32Value), s.localizedName)
        }
        let main = CGMainDisplayID()
        return screens.enumerated().map { i, pair in
            let (id, name) = pair
            // Identical monitors share a name — disambiguate.
            let dupes = screens.filter { $0.1 == name }.count > 1
            var label = dupes ? "\(name) (\(i + 1))" : name
            if id == main { label += " — Main" }
            return DisplayInfo(id: id, name: label)
        }
    }

    // MARK: Queue side

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.tickInterval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            // A static screen delivers no new frames; re-evaluate the last one
            // so time-based gates in the tracker still mature.
            if let f = self.lastFrame { self.tracker.ingest(f, at: now) }
            guard let c = self.tracker.tick(at: now) else { return }
            DispatchQueue.main.async { self.onColor?(c) }
        }
        t.resume()
        timer = t
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pb = sampleBuffer.imageBuffer,
              let frame = Self.frame(from: pb) else { return }
        lastFrame = frame
        tracker.ingest(frame, at: CACurrentMediaTime())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard stream === self.stream else { return }
            self.stream = nil
            self.displayID = nil
            self.queue.async {
                self.timer?.cancel()
                self.timer = nil
            }
            self.onStatus?(.failed(error.localizedDescription))
        }
    }

    /// BGRA pixel buffer → sRGB floats, box-averaged 2×2 (ScreenCaptureKit's
    /// own downscale is point-sampled enough to sparkle on fine detail).
    private static func frame(from pb: CVPixelBuffer) -> AmbientFrame? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let ow = w / 2, oh = h / 2
        guard ow > 0, oh > 0 else { return nil }

        var pixels = [SIMD3<Float>](repeating: .zero, count: ow * oh)
        for y in 0..<oh {
            for x in 0..<ow {
                var sum = SIMD3<Float>.zero
                for sy in 0..<2 {
                    for sx in 0..<2 {
                        let o = (y * 2 + sy) * bpr + (x * 2 + sx) * 4
                        sum += SIMD3(Float(p[o + 2]), Float(p[o + 1]), Float(p[o]))
                    }
                }
                pixels[y * ow + x] = sum / (4 * 255)
            }
        }
        return AmbientFrame(width: ow, height: oh, pixels: pixels)
    }
}
