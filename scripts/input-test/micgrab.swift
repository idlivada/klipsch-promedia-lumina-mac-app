import AVFoundation
import AppKit

// Records one WAV from the webcam microphone until <outDir>/stop appears (or
// <maxSeconds> elapse). Logs "START <epoch>" when samples begin, then DONE.
let args = Array(CommandLine.arguments.dropFirst())
let outDir = URL(fileURLWithPath: args.count > 0 ? args[0] : "/tmp/micgrab")
let maxSeconds = args.count > 1 ? Double(args[1])! : 60
let deviceMatch = args.count > 2 ? args[2] : "BRIO"
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let log = outDir.appendingPathComponent("rec.txt")
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

final class Recorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    let output = AVCaptureAudioFileOutput()

    func start() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        guard let dev = devices.first(where: { $0.localizedName.contains(deviceMatch) }) else {
            finish("ERROR no microphone matching \(deviceMatch): \(devices.map(\.localizedName))")
        }
        guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            finish("ERROR cannot open \(dev.localizedName)")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else { finish("ERROR cannot add audio file output") }
        session.addOutput(output)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.maxRecordedDuration = CMTime(seconds: maxSeconds, preferredTimescale: 600)
        session.startRunning()
        output.startRecording(to: outDir.appendingPathComponent("rec.wav"), outputFileType: .wav,
                              recordingDelegate: self)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            if FileManager.default.fileExists(atPath: outDir.appendingPathComponent("stop").path) {
                self.output.stopRecording()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from c: [AVCaptureConnection]) {
        note(String(format: "START %.3f", Date().timeIntervalSince1970))
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from c: [AVCaptureConnection], error: Error?) {
        session.stopRunning()
        // Hitting maxRecordedDuration reports an "error" but the file is complete.
        let ok = error == nil || (error as NSError?)?.code == AVError.maximumDurationReached.rawValue
        finish(ok ? "OK" : "ERROR recording failed: \(error!)")
    }
}

let recorder = Recorder()
AVCaptureDevice.requestAccess(for: .audio) { ok in
    guard ok else { finish("ERROR microphone access denied") }
    DispatchQueue.main.async { recorder.start() }
}
DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds + 30) { finish("ERROR timeout") }
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
