import SwiftUI
import Observation
import CoreBluetooth
import ServiceManagement
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

    // MARK: App-side streams (device in Static, ff3 streamed from screen or audio)

    /// At most one stream drives the LEDs; nil = the device's own modes.
    var stream: LightStream?
    var ambientActive: Bool { stream == .screen }
    var audioActive: Bool { stream == .audio }

    /// Latest sampled screen color (before the brightness slider is applied).
    /// Separate from `staticColor` so ambient never overwrites the user's pick.
    var ambientColor = RGB(r: 255, g: 255, b: 255)
    var ambientStatus: AmbientStatus = .stopped
    /// nil = main display.
    var ambientDisplayID: CGDirectDisplayID?
    var displays: [DisplayInfo] = []

    /// Latest audio-reactive color, same role as `ambientColor`.
    var audioColor = AmbientTracker.off
    var audioStatus: AmbientStatus = .stopped
    var audioPalette: AudioPalette = .bluePurple
    /// The `.custom` palette's color — its own pick, separate from `staticColor`.
    var audioCustomColor = RGB(r: 255, g: 40, b: 0)

    // MARK: App settings

    var launchAtLogin = SMAppService.mainApp.status == .enabled

    // MARK: Audio state

    var volume: Double = 50  // percent
    var muted = false
    var soundMode: SoundMode = .music
    /// nil until the speaker reports one, so the picker shows no false selection.
    var inputSource: InputSource?
    var nightMode = false
    var subGain: Double = 0  // dB
    var eqBands: [Double] = Array(repeating: 0, count: eqBandLabels.count)

    // MARK: Internals

    @ObservationIgnored private var lastActiveMode: LightMode = .rainbow
    @ObservationIgnored private var client = LuminaClient()
    @ObservationIgnored private var sampler = ScreenSampler()
    @ObservationIgnored private var audioSampler = AudioSampler()
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
        sampler.onColor = { [weak self] c in
            MainActor.assumeIsolated { self?.streamSample(c, from: .screen) }
        }
        sampler.onStatus = { [weak self] s in
            MainActor.assumeIsolated { self?.ambientStatus = s }
        }
        audioSampler.palette = audioPalette
        audioSampler.customColor = audioCustomColor
        audioSampler.onColor = { [weak self] c in
            MainActor.assumeIsolated { self?.streamSample(c, from: .audio) }
        }
        audioSampler.onStatus = { [weak self] s in
            MainActor.assumeIsolated { self?.audioStatus = s }
        }
    }

    // MARK: App settings

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            // Fall through: the status below is the truth either way.
        }
        if on && service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = service.status == .enabled
    }

    // MARK: Connection actions

    func releaseToPhone() {
        connection = .released
        client.release()
        syncSampler()
    }

    func reconnect() {
        connection = .searching
        client.reconnect()
        syncSampler()
    }

    // MARK: Lighting actions

    func setLights(on: Bool) {
        lightsOn = on
        write(Lumina.lightMode, Data([on ? lastActiveMode.rawValue : lightsOffByte]))
        if on { pushColorPayload(for: lastActiveMode) }
        syncSampler()
    }

    func setMode(_ m: LightMode) {
        // Leaving a stream for a solid-color mode keeps the color showing at
        // that moment (exact swatch value, so the LEDs don't jump) — unless
        // the stream was showing "off" (black screen, silence).
        if stream != nil && (m == .staticColor || m == .breathe) && displayedSolidColor != AmbientTracker.off {
            staticColor = displayedSolidColor
        }
        stopStream()
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
        case .staticColor, .breathe:
            pushStaticColor()
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

    /// Brightness is applied by re-scaling the displayed color (fea is a
    /// read-only mirror). It therefore affects Static and Breathe, whose color
    /// we own; Rainbow/Aurora/Music render their own colors and can't be dimmed
    /// from a BLE central without breaking their gradients.
    func setBrightness(_ p: Double) {
        brightness = p
        persist()
        if mode == .staticColor || mode == .breathe {
            pushStaticColor(throttled: true)
        }
    }

    var brightnessAffectsCurrentMode: Bool {
        mode == .staticColor || mode == .breathe
    }

    func setStaticColor(_ c: RGB) {
        staticColor = c
        persist()
        pushStaticColor(throttled: true)
    }

    /// The solid color Static/Breathe should show: the streamed color while a
    /// stream is on, otherwise the user's pick.
    private var displayedSolidColor: RGB {
        switch stream {
        case .screen: ambientColor
        case .audio: audioColor
        case nil: staticColor
        }
    }

    private func pushStaticColor(throttled: Bool = false) {
        // Scale the true color by brightness (fea can't be driven externally).
        write(
            Lumina.staticColor,
            Encodings.solidColorData(displayedSolidColor, brightnessPercent: brightness),
            throttled: throttled
        )
    }

    // MARK: Stream actions (Ambient / Audio)

    func setAmbient(_ on: Bool) {
        on ? startStream(.screen) : stopStream()
    }

    func setAudioReactive(_ on: Bool) {
        on ? startStream(.audio) : stopStream()
    }

    func setAudioPalette(_ p: AudioPalette) {
        audioPalette = p
        audioSampler.palette = p
        persist()
    }

    func setAudioCustomColor(_ c: RGB) {
        audioCustomColor = c
        audioSampler.customColor = c
        if audioPalette != .custom { setAudioPalette(.custom) } else { persist() }
    }

    private func startStream(_ s: LightStream) {
        stream = s
        mode = .staticColor
        lastActiveMode = .staticColor
        lightsOn = true
        persist()
        // ff2 then ff3 on the same connection (mode writes clear ff3).
        write(Lumina.lightMode, Data([LightMode.staticColor.rawValue]))
        pushStaticColor()
        syncSampler()
    }

    func setAmbientDisplay(_ id: CGDirectDisplayID?) {
        ambientDisplayID = id
        persist()
        syncSampler()
    }

    /// After granting Screen Recording (or a capture error), try again.
    func retryAmbient() {
        sampler.stop()
        syncSampler()
    }

    func refreshDisplays() {
        displays = ScreenSampler.displays()
    }

    private func stopStream() {
        guard stream != nil else { return }
        stream = nil
        persist()
        syncSampler()
    }

    /// Capture only while it can reach the LEDs; paused (not cancelled) while
    /// lights are off, released to the phone, or disconnected. At most one
    /// sampler runs — the one matching `stream`.
    private func syncSampler() {
        let live = lightsOn && connection == .connected
        if live && stream == .screen {
            let id = ambientDisplayID.flatMap { id in displays.contains { $0.id == id } ? id : nil }
            sampler.start(displayID: id)
        } else if ambientStatus != .stopped {
            sampler.stop()
        }
        if live && stream == .audio {
            audioSampler.start()
        } else if audioStatus != .stopped {
            audioSampler.stop()
        }
    }

    func retryAudio() {
        audioSampler.stop()
        syncSampler()
    }

    private func streamSample(_ c: RGB, from s: LightStream) {
        guard stream == s, lightsOn else { return }
        switch s {
        case .screen: ambientColor = c
        case .audio: audioColor = c
        }
        // Unthrottled: LuminaClient keeps one write in flight and replaces a
        // queued ff3 write, so the stream self-limits to the BLE round trip.
        pushStaticColor()
    }

    func setAuroraTone(_ t: AuroraTone) {
        stopStream()
        auroraTone = t
        mode = .aurora
        lastActiveMode = .aurora
        lightsOn = true
        write(Lumina.lightMode, Data([LightMode.aurora.rawValue]))
        write(Lumina.staticColor, Encodings.colorPairData(t.start, t.end))
    }

    func setMusicPreset(_ id: Int) {
        stopStream()
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

    func setInputSource(_ s: InputSource) {
        inputSource = s
        write(Lumina.input, Data([s.rawValue]))
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
            // The UI owns the Static/Breathe color and brightness; push the
            // scaled color so the device matches (its retained value is the
            // last scaled write, which we must not read back — see apply()).
            if mode == .staticColor || mode == .breathe { pushStaticColor() }
            syncSampler()
        case .disconnected:
            if connection != .released { connection = .searching }
            syncSampler()
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
                // Pod or phone switched away from Static: they own the lights now.
                if m != .staticColor { stopStream() }
                lightsOn = true
                mode = m
                lastActiveMode = m
                persist()
            }
            syncSampler()
        case Lumina.staticColor:
            guard data.count >= 6 else { break }
            let a = RGB(r: data[0], g: data[1], b: data[2])
            let b = RGB(r: data[3], g: data[4], b: data[5])
            let black = RGB(r: 0, g: 0, b: 0)
            if b == black || a == b {
                // Solid Static/Breathe color. We write a brightness-SCALED
                // value here and never want to read it back (that would
                // compound the dimming), so in those modes the UI is
                // authoritative and inbound values are ignored. Only adopt a
                // solid color when we're NOT the source (other modes active).
                if mode != .staticColor && mode != .breathe && a != black && a != staticColor {
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
        case Lumina.input:
            if let s = InputSource(rawValue: first) { inputSource = s }
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
        displays = ScreenSampler.displays()
        if let id = d.object(forKey: "lumina.ambientDisplay") as? Int {
            ambientDisplayID = CGDirectDisplayID(id)
        }
        // Resumes on connect (syncSampler waits for .connected). Pre-1.3
        // builds stored ambient as a bool.
        if let raw = d.string(forKey: "lumina.stream") {
            stream = LightStream(rawValue: raw)
        } else if d.bool(forKey: "lumina.ambient") {
            stream = .screen
        }
        if lastActiveMode != .staticColor { stream = nil }
        if let raw = d.object(forKey: "lumina.audioPalette") as? Int,
           let p = AudioPalette(rawValue: raw) {
            audioPalette = p
        }
        if let c = d.data(forKey: "lumina.audioCustomColor"),
           let rgb = try? JSONDecoder().decode(RGB.self, from: c) {
            audioCustomColor = rgb
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(Int(lastActiveMode.rawValue), forKey: "lumina.lastMode")
        d.set(brightness, forKey: "lumina.brightness")
        if let c = try? JSONEncoder().encode(staticColor) {
            d.set(c, forKey: "lumina.staticColor")
        }
        d.set(stream?.rawValue ?? "", forKey: "lumina.stream")
        d.removeObject(forKey: "lumina.ambient")
        d.set(audioPalette.rawValue, forKey: "lumina.audioPalette")
        if let c = try? JSONEncoder().encode(audioCustomColor) {
            d.set(c, forKey: "lumina.audioCustomColor")
        }
        if let id = ambientDisplayID {
            d.set(Int(id), forKey: "lumina.ambientDisplay")
        } else {
            d.removeObject(forKey: "lumina.ambientDisplay")
        }
    }
}
