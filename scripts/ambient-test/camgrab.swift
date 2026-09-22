// Webcam frame grabber for scripts/ambient-test.sh — bundled as an .app so
// macOS TCC shows a camera prompt (shell ffmpeg is silently denied).
// Usage (via open --args): <outDir> <count> <intervalSec> [deviceNameSubstring]
// intervalSec 0 = every frame the camera delivers.
// Writes frame_NNN.jpg + frames.txt ("<index> <epochSeconds>"), then DONE.
import AVFoundation
import AppKit
import CoreImage

let args = Array(CommandLine.arguments.dropFirst())
let outDir = URL(fileURLWithPath: args.count > 0 ? args[0] : "/tmp/camgrab")
let count = args.count > 1 ? Int(args[1])! : 1
let interval = args.count > 2 ? Double(args[2])! : 0
let deviceMatch = args.count > 3 ? args[3] : "BRIO"
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let log = outDir.appendingPathComponent("frames.txt")
FileManager.default.createFile(atPath: log.path, contents: nil)
let logHandle = try! FileHandle(forWritingTo: log)

func note(_ s: String) {
    logHandle.write((s + "\n").data(using: .utf8)!)
}
func finish(_ msg: String) -> Never {
    note(msg)
    note("DONE")
    exit(0)
}

final class Grabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let ctx = CIContext()
    var taken = 0
    var nextAt: CFTimeInterval = 0
    var warmup = 15  // let auto-exposure settle

    func start() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices
        guard let dev = devices.first(where: { $0.localizedName.contains(deviceMatch) }) else {
            finish("ERROR no device matching \(deviceMatch): \(devices.map(\.localizedName))")
        }
        session.sessionPreset = .hd1280x720
        guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            finish("ERROR cannot open \(dev.localizedName)")
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cam"))
        session.addOutput(out)
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        if warmup > 0 { warmup -= 1; return }
        let now = CACurrentMediaTime()
        guard now >= nextAt, let pb = sb.imageBuffer else { return }
        nextAt = (nextAt == 0 ? now : nextAt) + interval
        let img = CIImage(cvPixelBuffer: pb)
        let url = outDir.appendingPathComponent(String(format: "frame_%03d.jpg", taken))
        try? ctx.writeJPEGRepresentation(of: img, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        note(String(format: "%d %.3f", taken, Date().timeIntervalSince1970))
        taken += 1
        if taken >= count {
            session.stopRunning()
            finish("OK")
        }
    }
}

let grabber = Grabber()
AVCaptureDevice.requestAccess(for: .video) { ok in
    guard ok else { finish("ERROR camera access denied") }
    DispatchQueue.main.async { grabber.start() }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { finish("ERROR timeout") }
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
