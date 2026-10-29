import AVFoundation
import CoreAudio

// Plays a different sine tone on several CoreAudio output devices at once, so
// a microphone can tell which speaker input is live. Runs until killed.
//   tonegen "pc=usb/ProMedia Lumina=1000,analog=Headphones=1500"
// Each entry is label=[transport/]deviceNameSubstring=hz; transport is one of
// usb, bluetooth, builtin (needed when two devices share a name, as the
// Lumina's USB and Bluetooth outputs do). Prints "TONE <label> <hz> <device>".

struct OutputDevice {
    let id: AudioDeviceID
    let name: String
    let transport: String
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func outputDevices() -> [OutputDevice] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids.compactMap { id in
        var streamsAddr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var streamsSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize)
        guard streamsSize > 0 else { return nil }
        var nameAddr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr,
              let n = name?.takeRetainedValue() as String? else { return nil }
        var transportAddr = address(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &tSize, &t)
        let transport = switch t {
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: "builtin"
        default: "other"
        }
        return OutputDevice(id: id, name: n, transport: transport)
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let spec = CommandLine.arguments.dropFirst().first ?? ""
let devices = outputDevices()
let available = devices.map { "\($0.transport)/\($0.name)" }.joined(separator: ", ")
var engines: [AVAudioEngine] = []

for entry in spec.split(separator: ",") {
    let parts = entry.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 3, let hz = Double(parts[2]) else { fail("bad entry '\(entry)', want label=[transport/]name=hz") }
    let label = parts[0]
    let target = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
    let (transport, match) = target.count == 2 ? (target[0], target[1]) : (nil, target[0])
    guard let dev = devices.first(where: { $0.name.contains(match) && (transport == nil || $0.transport == transport) }) else {
        fail("ERROR no output device for \(label) (\(parts[1])); available: \(available)")
    }

    let engine = AVAudioEngine()
    var id = dev.id
    guard let unit = engine.outputNode.audioUnit,
          AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                               &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
        fail("ERROR cannot route to \(dev.name)")
    }
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    var phase = 0.0
    let step = 2 * Double.pi * hz / rate
    let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
        for frame in 0..<Int(frames) {
            let v = Float(0.2 * sin(phase))
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            for buf in UnsafeMutableAudioBufferListPointer(buffers) {
                buf.mData!.assumingMemoryBound(to: Float.self)[frame] = v
            }
        }
        return noErr
    }
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    do { try engine.start() } catch { fail("ERROR cannot start output on \(dev.name): \(error)") }
    engines.append(engine)
    print("TONE \(label) \(Int(hz)) \(dev.transport)/\(dev.name)")
}
guard !engines.isEmpty else { fail("no tones given; available outputs: \(available)") }
fflush(stdout)
dispatchMain()
