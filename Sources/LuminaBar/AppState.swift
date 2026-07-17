import SwiftUI
import Observation
import CoreBluetooth
import LuminaProtocol

enum ConnectionState {
    case searching
    case connected
    case released
}

/// Single source of truth. Writes are optimistic: state mutates immediately,
/// the BLE write follows (throttled for sliders). Incoming notifications sync
/// external changes (pod button, phone app); echoes of our own recent writes
/// are suppressed so sliders don't fight the device.
@MainActor
@Observable
final class AppState {
    let caps = ProtocolCapabilities()
    var connection: ConnectionState = .searching

    // MARK: Lighting state

    var lightsOn = true
    var mode: LightMode = .rainbow
    var brightness: Double = 100
    var staticColor = RGB(r: 255, g: 40, b: 0)
    var auroraTone: AuroraTone = .cool
    var musicPresetID = 0

    // MARK: Audio state

    var volume: Double = 50  // percent
    var muted = false
    var soundMode: SoundMode = .music
    var nightMode = false
    var subGain: Double = 0  // dB
    var eqBands: [Double] = Array(repeating: 0, count: eqBandLabels.count)

    // MARK: Internals

    @ObservationIgnored private var lastActiveMode: LightMode = .rainbow
    @ObservationIgnored private var client = LuminaClient()
    @ObservationIgnored private var throttler: Throttler!
    @ObservationIgnored private var recentWrites: [CBUUID: Date] = [:]
    @ObservationIgnored private var editingChars: Set<CBUUID> = []
    private let echoWindow: TimeInterval = 1.5

    init() {
        restorePersisted()
        throttler = Throttler { [weak self] uuid, data in
            self?.recentWrites[uuid] = Date()
            self?.client.write(uuid, data)
        }
        client.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    // MARK: Connection actions

    func releaseToPhone() {
        connection = .released
        client.release()
    }

    func reconnect() {
        connection = .searching
        client.reconnect()
    }

    // MARK: Lighting actions

    func setLights(on: Bool) {
        lightsOn = on
        write(Lumina.lightMode, Data([on ? lastActiveMode.rawValue : lightsOffByte]))
    }

    func setMode(_ m: LightMode) {
        mode = m
        lastActiveMode = m
        lightsOn = true
        persist()
        write(Lumina.lightMode, Data([m.rawValue]))
        if m == .staticColor { pushStaticColor() }
    }

    func setBrightness(_ p: Double) {
        brightness = p
        persist()
        if mode == .staticColor {
            // fea has no visible effect in Static — scale the RGB locally instead.
            pushStaticColor(throttled: true)
        } else {
            write(Lumina.brightness, Encodings.brightnessData(percent: p), throttled: true)
        }
    }

    func setStaticColor(_ c: RGB) {
        staticColor = c
        persist()
        pushStaticColor(throttled: true)
    }

    private func pushStaticColor(throttled: Bool = false) {
        let out = mode == .staticColor
            ? Encodings.scaled(staticColor, brightnessPercent: brightness)
            : staticColor
        write(Lumina.staticColor, Encodings.colorData(out), throttled: throttled)
    }

    func setAuroraTone(_ t: AuroraTone) {
        auroraTone = t
        // TODO(Phase 1): write once the Aurora tone characteristic is discovered.
    }

    func setMusicPreset(_ id: Int) {
        musicPresetID = id
        // TODO(Phase 1): hypothesis — ff3's two triplets may be the gradient
        // endpoints in Music mode. If confirmed, write start+end here.
    }

    // MARK: Audio actions

    func setVolume(_ p: Double) {
        volume = p
        write(Lumina.volume, Encodings.volumeData(percent: p), throttled: true)
    }

    func setMuted(_ on: Bool) {
        muted = on
        write(Lumina.mute, Encodings.boolData(on))
    }

    func setNightMode(_ on: Bool) {
        nightMode = on
        write(Lumina.nightMode, Encodings.boolData(on))
    }

    func setSubGain(_ db: Double) {
        subGain = db
        write(Lumina.channelVolume, Encodings.subGainData(db: Int(db.rounded())), throttled: true)
    }

    func setSoundMode(_ m: SoundMode) {
        soundMode = m
        // TODO(Phase 1): write once the sound-mode characteristic (f06? f12?) is mapped.
    }

    func setEQBand(_ index: Int, _ db: Double) {
        eqBands[index] = db
        // TODO(Phase 1): write once the 6-band EQ mapping is discovered.
    }

    // MARK: Slider editing (notification suppression while dragging)

    func setEditing(_ uuid: CBUUID, _ editing: Bool) {
        if editing {
            editingChars.insert(uuid)
        } else {
            editingChars.remove(uuid)
            throttler.flush(uuid)
        }
    }

    // MARK: Write path

    private func write(_ uuid: CBUUID, _ data: Data, throttled: Bool = false) {
        if throttled {
            throttler.submit(uuid, data)
        } else {
            recentWrites[uuid] = Date()
            client.write(uuid, data)
        }
    }

    // MARK: Incoming events

    private func handle(_ event: LuminaEvent) {
        switch event {
        case .connected:
            connection = .connected
        case .disconnected:
            if connection != .released { connection = .searching }
        case .value(let uuid, let data):
            apply(uuid, data)
        }
    }

    private func apply(_ uuid: CBUUID, _ data: Data) {
        // Drop echoes of our own recent writes and anything for a slider mid-drag.
        if editingChars.contains(uuid) { return }
        if let t = recentWrites[uuid], Date().timeIntervalSince(t) < echoWindow { return }
        guard let first = data.first else { return }

        switch uuid {
        case Lumina.lightMode:
            if first == lightsOffByte {
                lightsOn = false
            } else if let m = LightMode(rawValue: first) {
                lightsOn = true
                mode = m
                lastActiveMode = m
                persist()
            }
        case Lumina.brightness:
            brightness = Double(min(first, 100))
        case Lumina.staticColor:
            if data.count >= 3 {
                staticColor = RGB(r: data[0], g: data[1], b: data[2])
                persist()
            }
        case Lumina.volume:
            volume = Encodings.volumePercent(raw: first)
        case Lumina.mute:
            muted = first != 0
        case Lumina.nightMode:
            nightMode = first != 0
        case Lumina.channelVolume:
            if data.count >= 2, data[0] == Encodings.subChannel {
                subGain = Double(Encodings.subGainDB(raw: data[1]))
            }
        default:
            break
        }
    }

    // MARK: Persistence (so the on/off toggle works before first sync)

    private func restorePersisted() {
        let d = UserDefaults.standard
        if let raw = d.object(forKey: "lumina.lastMode") as? Int,
           let m = LightMode(rawValue: UInt8(raw)) {
            lastActiveMode = m
            mode = m
        }
        if d.object(forKey: "lumina.brightness") != nil {
            brightness = d.double(forKey: "lumina.brightness")
        }
        if let c = d.data(forKey: "lumina.staticColor"),
           let rgb = try? JSONDecoder().decode(RGB.self, from: c) {
            staticColor = rgb
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(Int(lastActiveMode.rawValue), forKey: "lumina.lastMode")
        d.set(brightness, forKey: "lumina.brightness")
        if let c = try? JSONEncoder().encode(staticColor) {
            d.set(c, forKey: "lumina.staticColor")
        }
    }
}
