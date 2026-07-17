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
    /// Last EQ blob seen from the device — used as the write template so the
    /// non-gain bytes always round-trip unchanged.
    @ObservationIgnored private var eqTemplate: Data?
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
        if on { pushColorPayload(for: lastActiveMode) }
    }

    func setMode(_ m: LightMode) {
        mode = m
        lastActiveMode = m
        lightsOn = true
        persist()
        write(Lumina.lightMode, Data([m.rawValue]))
        // Mode transitions clear ff3 on the device — always re-push the
        // mode's color payload after the mode write.
        pushColorPayload(for: m)
    }

    private func pushColorPayload(for m: LightMode) {
        switch m {
        case .staticColor:
            pushStaticColor()
        case .breathe:
            write(Lumina.staticColor, Encodings.colorData(staticColor))
        case .music:
            if let p = MusicPreset.all.first(where: { $0.id == musicPresetID }) {
                write(Lumina.staticColor, Encodings.colorPairData(p.start, p.end))
            }
        case .aurora:
            write(Lumina.staticColor, Encodings.colorPairData(auroraTone.start, auroraTone.end))
        case .rainbow:
            break
        }
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
        mode = .aurora
        lastActiveMode = .aurora
        lightsOn = true
        write(Lumina.lightMode, Data([LightMode.aurora.rawValue]))
        write(Lumina.staticColor, Encodings.colorPairData(t.start, t.end))
    }

    func setMusicPreset(_ id: Int) {
        musicPresetID = id
        guard let p = MusicPreset.all.first(where: { $0.id == id }) else { return }
        mode = .music
        lastActiveMode = .music
        lightsOn = true
        write(Lumina.lightMode, Data([LightMode.music.rawValue]))
        write(Lumina.staticColor, Encodings.colorPairData(p.start, p.end))
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
        write(Lumina.subGain, Encodings.subGainData(db: Int(db.rounded())), throttled: true)
    }

    func setSoundMode(_ m: SoundMode) {
        soundMode = m
        write(Lumina.soundMode, Data([m.rawValue]))
    }

    func setEQBand(_ index: Int, _ db: Double) {
        eqBands[index] = db
        pushEQ()
    }

    func resetEQ() {
        eqBands = Array(repeating: 0, count: eqBandLabels.count)
        pushEQ()
    }

    private func pushEQ() {
        let gains = eqBands.map { Int($0.rounded()) }
        guard let data = Encodings.eqBlobData(gains: gains, template: eqTemplate) else { return }
        write(Lumina.eqBlob, data, throttled: true)
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
            guard data.count >= 6 else { break }
            let a = RGB(r: data[0], g: data[1], b: data[2])
            let b = RGB(r: data[3], g: data[4], b: data[5])
            if a == b {
                // Identical triplets = a solid Static/Breathe color. In Static
                // mode ff3 always holds a brightness-SCALED value (from us or
                // the phone app alike), never the true color — adopting it
                // compounds the dimming (echoes arrive after the suppression
                // window, and the initial connect read has the same problem).
                // Local state stays authoritative in Static; only Breathe
                // (unscaled) values are adopted.
                if mode == .breathe && a != staticColor {
                    staticColor = a
                    persist()
                }
            } else if let p = MusicPreset.all.first(where: { $0.start == a && $0.end == b }) {
                musicPresetID = p.id
            } else if let t = AuroraTone.allCases.first(where: { $0.start == a && $0.end == b }) {
                auroraTone = t
            }
        case Lumina.volume:
            volume = Encodings.volumePercent(raw: first)
        case Lumina.mute:
            muted = first != 0
        case Lumina.nightMode:
            nightMode = first != 0
        case Lumina.subGain:
            subGain = Double(Encodings.subGainDB(raw: first))
        case Lumina.soundMode:
            if let m = SoundMode(rawValue: first) { soundMode = m }
        case Lumina.eqBlob:
            eqTemplate = data
            if let gains = Encodings.eqBlobGains(data) {
                eqBands = gains.map(Double.init)
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
