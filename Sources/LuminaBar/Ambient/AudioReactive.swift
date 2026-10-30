import Accelerate
import Foundation
import LuminaProtocol

/// What one tick of system audio looks like to the lights.
struct AudioFeatures {
    /// RMS of every sample since the previous tick (0...1 full scale).
    var rms: Float
    /// Spectral energy (sum of squared magnitudes) in the bass band.
    var bass: Float
    /// Magnitude-weighted mean frequency in Hz (40 Hz–8 kHz); 0 if silent.
    var centroid: Float

    static let silent = AudioFeatures(rms: 0, bass: 0, centroid: 0)
}

/// Mono samples → `AudioFeatures`. Loudness covers every sample since the last
/// `features()` call (so short peaks between ticks still count); the spectrum
/// is a Hann-windowed FFT of the most recent `fftSize` samples. Pure, no I/O.
struct AudioAnalyzer {
    static let fftSize = 2048  // ≈ 23 Hz bins at 48 kHz: enough to split bass
    static let bassBand: ClosedRange<Float> = 20...250
    static let centroidBand: ClosedRange<Float> = 40...8000

    let sampleRate: Float
    private var ring = [Float](repeating: 0, count: fftSize)
    private var head = 0
    private var sumSquares: Float = 0
    private var fresh = 0
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: fftSize, isHalfWindow: false)
    private let dft = try? vDSP.DiscreteFourierTransform(
        previous: nil, count: fftSize, direction: .forward,
        transformType: .complexComplex, ofType: Float.self)

    init(sampleRate: Float) { self.sampleRate = sampleRate }

    mutating func push(_ samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            ring[head] = s
            head = (head + 1) % Self.fftSize
            sumSquares += s * s
        }
        fresh += samples.count
    }

    /// Features since the previous call; `.silent` if nothing arrived (a
    /// stalled stream must not keep replaying the last spectrum).
    mutating func features() -> AudioFeatures {
        defer { sumSquares = 0; fresh = 0 }
        guard fresh > 0, let dft else { return .silent }
        let rms = (sumSquares / Float(fresh)).squareRoot()

        // Oldest → newest, windowed.
        let ordered = Array(ring[head...] + ring[..<head])
        let real = vDSP.multiply(ordered, window)
        let imag = [Float](repeating: 0, count: Self.fftSize)
        var outReal = [Float](repeating: 0, count: Self.fftSize)
        var outImag = [Float](repeating: 0, count: Self.fftSize)
        dft.transform(inputReal: real, inputImaginary: imag,
                      outputReal: &outReal, outputImaginary: &outImag)

        let binHz = sampleRate / Float(Self.fftSize)
        var bass: Float = 0, weighted: Float = 0, total: Float = 0
        for k in 1..<(Self.fftSize / 2) {
            let f = Float(k) * binHz
            let power = outReal[k] * outReal[k] + outImag[k] * outImag[k]
            if Self.bassBand.contains(f) { bass += power }
            if Self.centroidBand.contains(f) {
                let mag = power.squareRoot()
                weighted += mag * f
                total += mag
            }
        }
        return AudioFeatures(rms: rms, bass: bass, centroid: total > 0 ? weighted / total : 0)
    }
}

/// Audio features over time → one LED color per tick. Loudness drives
/// intensity (fast attack, slower release, auto-gained so quiet and loud
/// tracks both use the full range), bass onsets add a kick, and the palette
/// picks the color. Every gate is time-based (see `AmbientTracker`).
struct AudioTracker {
    static let attack: TimeInterval = 0.03
    static let release: TimeInterval = 0.25
    /// The auto-gain reference peak decays with this time constant.
    static let peakDecay: TimeInterval = 5
    /// Auto-gain never amplifies past this reference (keeps hiss dark).
    static let minPeak: Float = 0.01
    /// Below this RMS (≈ −54 dBFS) counts as silence…
    static let silenceRMS: Float = 0.002
    /// …and this much of it fades the lights to off.
    static let silenceHold: TimeInterval = 1.0
    static let fadeTau: TimeInterval = 0.3
    /// Lowest intensity while sound is playing, so the lights don't strobe to
    /// black between notes.
    static let floor: Float = 0.15
    /// A kick is bass energy above this multiple of its recent mean…
    static let kickRatio: Float = 1.5
    static let bassMeanTau: TimeInterval = 1.0
    /// …at most this often, decaying with `kickTau`.
    static let kickGap: TimeInterval = 0.15
    static let kickTau: TimeInterval = 0.15
    /// Spectrum hue smoothing (pitch jumps would otherwise flicker).
    static let hueTau: TimeInterval = 0.15
    /// Spectrum: centroid range mapped onto red → violet (log scale).
    static let centroidRange: ClosedRange<Float> = 80...5000
    static let maxHue: Float = 0.8

    var palette: AudioPalette = .bluePurple
    /// Used by `.custom`.
    var customColor = RGB(r: 255, g: 40, b: 0)

    private var level: Float = 0
    private var peak: Float = minPeak
    private var bassMean: Float = 0
    private var kick: Float = 0
    private var lastKick: TimeInterval = -.infinity
    private var silentSince: TimeInterval?
    private var gate: Float = 0
    private var hue: Float?
    private var lastTick: TimeInterval?
    private var lastEmitted: RGB?

    mutating func reset() {
        let (p, c) = (palette, customColor)
        self = AudioTracker()
        palette = p
        customColor = c
    }

    /// Returns a color only when it changed enough to send.
    mutating func tick(_ f: AudioFeatures, at t: TimeInterval) -> RGB? {
        let dt = Float(lastTick.map { max(0, t - $0) } ?? 0)
        lastTick = t
        func ease(_ tau: TimeInterval) -> Float { 1 - exp(-dt / Float(tau)) }

        // Loudness envelope + auto-gain.
        level += (f.rms - level) * ease(f.rms > level ? Self.attack : Self.release)
        peak = max(level, Self.minPeak, peak * exp(-dt / Float(Self.peakDecay)))
        let norm = min(level / peak, 1)

        // Bass onsets.
        if f.bass > Self.kickRatio * bassMean, bassMean > 0, t - lastKick >= Self.kickGap {
            kick = 1
            lastKick = t
        }
        bassMean += (f.bass - bassMean) * ease(Self.bassMeanTau)
        kick *= exp(-dt / Float(Self.kickTau))

        // Silence gate: fade out after a second of quiet, back in on sound.
        if f.rms < Self.silenceRMS {
            silentSince = silentSince ?? t
        } else {
            silentSince = nil
        }
        let playing = silentSince.map { t - $0 < Self.silenceHold } ?? true
        gate += ((playing ? 1 : 0) - gate) * ease(Self.fadeTau)

        // Squared for contrast: steady music sits mid-range, peaks pop.
        let drive = max(norm * norm, kick)
        let intensity = (Self.floor + (1 - Self.floor) * drive) * gate

        let out = gate < 0.02 ? AmbientTracker.off : Self.rgb(color(drive: drive, f, ease) * intensity)
        if let last = lastEmitted,
           abs(Int(last.r) - Int(out.r)) <= AmbientTracker.minStep,
           abs(Int(last.g) - Int(out.g)) <= AmbientTracker.minStep,
           abs(Int(last.b) - Int(out.b)) <= AmbientTracker.minStep {
            return nil
        }
        lastEmitted = out
        return out
    }

    /// Full-brightness color for this tick.
    private mutating func color(drive: Float, _ f: AudioFeatures,
                                _ ease: (TimeInterval) -> Float) -> SIMD3<Float> {
        if let p = palette.preset {
            let a = Self.vec(p.start), b = Self.vec(p.end)
            return a + (b - a) * drive
        }
        if palette == .custom { return Self.vec(customColor) }
        // Spectrum: keep the last hue through silence/gaps.
        if f.centroid > 0 {
            let r = Self.centroidRange
            let x = (log2(min(max(f.centroid, r.lowerBound), r.upperBound)) - log2(r.lowerBound))
                / (log2(r.upperBound) - log2(r.lowerBound))
            let target = x * Self.maxHue
            hue = hue.map { $0 + (target - $0) * ease(Self.hueTau) } ?? target
        }
        return Self.hueColor(hue ?? 0)
    }

    private static func vec(_ c: RGB) -> SIMD3<Float> {
        SIMD3(Float(c.r), Float(c.g), Float(c.b)) / 255
    }

    /// Fully saturated, full-value color for hue 0...1.
    static func hueColor(_ h: Float) -> SIMD3<Float> {
        let x = (h - h.rounded(.down)) * 6
        let i = Int(x) % 6, f = x - x.rounded(.down)
        switch i {
        case 0: return SIMD3(1, f, 0)
        case 1: return SIMD3(1 - f, 1, 0)
        case 2: return SIMD3(0, 1, f)
        case 3: return SIMD3(0, 1 - f, 1)
        case 4: return SIMD3(f, 0, 1)
        default: return SIMD3(1, 0, 1 - f)
        }
    }

    /// Never all-zero: an all-zero ff3 write flashes the device bright.
    private static func rgb(_ c: SIMD3<Float>) -> RGB {
        func b(_ v: Float) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        let out = RGB(r: b(c.x), g: b(c.y), b: b(c.z))
        return out == RGB(r: 0, g: 0, b: 0) ? AmbientTracker.off : out
    }
}
