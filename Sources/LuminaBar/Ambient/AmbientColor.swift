import Foundation
import LuminaProtocol

/// A small downscaled screen frame: row-major sRGB, 0...1 per channel.
struct AmbientFrame {
    let width: Int
    let height: Int
    var pixels: [SIMD3<Float>]

    subscript(x: Int, y: Int) -> SIMD3<Float> { pixels[y * width + x] }
}

/// Inclusive pixel rectangle inside an `AmbientFrame`.
struct PixelRect: Equatable {
    var minX, minY, maxX, maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }

    func contains(_ o: PixelRect) -> Bool {
        minX <= o.minX && minY <= o.minY && maxX >= o.maxX && maxY >= o.maxY
    }
}

/// Screen → one LED color. Edge-weighted (so the wall glow reads as the picture
/// continuing past the display), with letterbox/pillarbox detection so a movie's
/// black bars don't count as "edges", and a dominant-hue pick so a dark scene is
/// driven by wherever its color actually is. Pure and frame-local; temporal
/// behavior lives in `AmbientTracker`.
enum AmbientColor {
    // MARK: Tunables (validated against the webcam loop — see PROTOCOL.md)

    /// A row/column is a black bar when its 95th-percentile luminance is below this.
    static let barLuminance: Float = 0.06
    static let barPercentile: Float = 0.95
    /// If "content" would be smaller than this fraction of the frame, the whole
    /// screen is just dark — don't crop.
    static let minContentFraction: Float = 0.2
    /// Outer band (fraction of the half-size, ≈ outer 15% of the rect) at full weight.
    static let edgeBand: Float = 0.3
    /// Position weight at the very center.
    static let centerWeight: Float = 0.25
    /// Color weight = base + saturation × value.
    static let baseColorWeight: Float = 0.1
    static let hueBins = 24
    /// Top hue cluster (bin ± 1) must hold this share of chromatic weight to win.
    static let dominantShare: Float = 0.35
    /// Below this chromatic/total weight ratio the screen is treated as neutral.
    static let neutralChromaRatio: Float = 0.02
    /// Intensity floor so dark scenes glow faintly instead of going black.
    static let intensityFloor: Float = 0.15
    /// The screen is black (LEDs off) only when fewer than `minLitFraction` of
    /// pixels exceed `litValue`. Keyed on lit pixels, not the mean: a small
    /// bright object on black (dark movie scene) averages near zero but must
    /// still drive the LEDs. Off = the tracker's RGB(1,1,1) clamp (never all-zero),
    /// webcam-verified to read as off.
    static let litValue: Float = 0.15
    static let minLitFraction: Float = 0.005
    /// Intensity = mean value ^ this. Even vivid video averages only ~0.35–0.4
    /// value per pixel, so a linear map turned saturated reds into brown; 0.5
    /// lifts those to ~0.6 while dark scenes stay dim (0.19 → 0.44).
    static let intensityGamma: Float = 0.5
    /// Chosen colors below this saturation are white/gray and shown as white;
    /// everything else is pushed to full saturation (same hue). The LEDs look
    /// washed out otherwise — e.g. a red scene averaged to #b13526 (sat 0.79)
    /// and read as dull until pushed to the rim of the color wheel.
    static let whiteSaturation: Float = 0.2

    struct Sample {
        /// Chosen color at full value (max channel = 1) and, unless white, full
        /// saturation (min channel = 0).
        var color: SIMD3<Float>
        /// Mean HSV value of the content region, gamma-lifted and floored. HSV
        /// value rather than luminance: luminance weights red at 0.21, so vivid
        /// red scenes would read as nearly black.
        var intensity: Float
        /// Winning hue bin, or nil for blended-mean / neutral results.
        var hueBin: Int?
    }

    static func luminance(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    static func hsv(_ c: SIMD3<Float>) -> (h: Float, s: Float, v: Float) {
        let mx = c.max(), mn = c.min(), d = mx - mn
        let s: Float = mx > 0 ? d / mx : 0
        var h: Float = 0
        if d > 0 {
            if mx == c.x {
                h = (c.y - c.z) / d
                if h < 0 { h += 6 }
            } else if mx == c.y {
                h = (c.z - c.x) / d + 2
            } else {
                h = (c.x - c.y) / d + 4
            }
            h /= 6
        }
        return (h, s, mx)
    }

    // MARK: Black-bar detection

    static func contentRect(_ f: AmbientFrame) -> PixelRect {
        let full = PixelRect(minX: 0, minY: 0, maxX: f.width - 1, maxY: f.height - 1)
        func isBar(_ lums: [Float]) -> Bool {
            let s = lums.sorted()
            return s[Int(Float(s.count - 1) * barPercentile)] < barLuminance
        }
        func row(_ y: Int) -> [Float] { (0..<f.width).map { luminance(f[$0, y]) } }
        func col(_ x: Int, _ ys: ClosedRange<Int>) -> [Float] { ys.map { luminance(f[x, $0]) } }

        var top = 0
        while top < f.height / 2 && isBar(row(top)) { top += 1 }
        var bottom = f.height - 1
        while bottom > f.height / 2 && isBar(row(bottom)) { bottom -= 1 }
        var left = 0
        while left < f.width / 2 && isBar(col(left, top...bottom)) { left += 1 }
        var right = f.width - 1
        while right > f.width / 2 && isBar(col(right, top...bottom)) { right -= 1 }

        let r = PixelRect(minX: left, minY: top, maxX: right, maxY: bottom)
        if Float(r.width) < minContentFraction * Float(f.width)
            || Float(r.height) < minContentFraction * Float(f.height) {
            return full
        }
        return r
    }

    // MARK: Color extraction

    static func extract(_ f: AmbientFrame, in r: PixelRect) -> Sample {
        var binColor = [SIMD3<Float>](repeating: .zero, count: hueBins)
        var binWeight = [Float](repeating: 0, count: hueBins)
        var meanColor = SIMD3<Float>.zero
        var totalWeight: Float = 0
        var chromaWeight: Float = 0
        var valueSum: Float = 0
        var litCount = 0

        let halfW = Float(r.width) / 2, halfH = Float(r.height) / 2
        for y in r.minY...r.maxY {
            let dy = Float(min(y - r.minY, r.maxY - y)) / halfH
            for x in r.minX...r.maxX {
                let c = f[x, y]
                let (h, s, v) = hsv(c)
                let dx = Float(min(x - r.minX, r.maxX - x)) / halfW
                let d = min(dx, dy)  // 0 at the edge, ~1 at the center
                let wp: Float = d <= edgeBand
                    ? 1
                    : 1 - (1 - centerWeight) * min(1, (d - edgeBand) / (1 - edgeBand))
                let w = wp * (baseColorWeight + s * v)
                meanColor += w * c
                totalWeight += w

                let cw = wp * s * v
                chromaWeight += cw
                let bin = Int(h * Float(hueBins)) % hueBins
                binColor[bin] += cw * c
                binWeight[bin] += cw
                valueSum += v
                if v > litValue { litCount += 1 }
            }
        }
        let count = Float(r.width * r.height)
        let isBlack = Float(litCount) / count < minLitFraction
        let intensity = isBlack ? 0 : max(intensityFloor, pow(valueSum / count, intensityGamma))

        var color: SIMD3<Float>
        var hueBin: Int?
        if totalWeight == 0 || chromaWeight / totalWeight < neutralChromaRatio {
            color = SIMD3(1, 1, 1)
        } else {
            let top = binWeight.indices.max { binWeight[$0] < binWeight[$1] }!
            let cluster = [(top + hueBins - 1) % hueBins, top, (top + 1) % hueBins]
            let cw = cluster.reduce(Float(0)) { $0 + binWeight[$1] }
            if cw / chromaWeight >= dominantShare {
                color = cluster.reduce(SIMD3<Float>.zero) { $0 + binColor[$1] } / cw
                hueBin = top
            } else {
                color = meanColor / totalWeight
            }
        }
        let mx = color.max()
        color = mx > 0 ? color / mx : SIMD3(1, 1, 1)
        let mn = color.min()  // with max = 1, saturation = 1 - min
        if 1 - mn < whiteSaturation {
            color = SIMD3(1, 1, 1)
            hueBin = nil
        } else {
            color = (color - SIMD3(repeating: mn)) / (1 - mn)  // same hue, full saturation
            // A saturated blended mean is now a definite hue too — give it a bin
            // so the tracker's hue gate damps flips between hues.
            hueBin = hueBin ?? Int(hsv(color).h * Float(hueBins)) % hueBins
        }
        return Sample(color: color, intensity: intensity, hueBin: hueBin)
    }
}

/// Temporal layer over `AmbientColor`: stabilizes the letterbox crop, requires a
/// new dominant hue to persist before switching (no flicker between two close
/// competitors), and eases toward the target with an exponential moving average.
/// All gates are time-based, never frame-counted: ScreenCaptureKit only
/// delivers frames when the screen changes, so a static screen yields a single
/// frame. The sampler re-ingests its last frame on every timer tick so pending
/// crop/hue changes still mature and smoothing still converges.
/// (Webcam-verified: frame-counted gates stalled changes for seconds or forever.)
struct AmbientTracker {
    /// EMA time constant. Webcam step response (red↔blue): with 0.2 s plus the
    /// 0.15 s hue gate, the LED took ~0.8 s end to end; tightened to cut that.
    static let tau: TimeInterval = 0.12
    /// A shrinking crop (bars appearing) must hold this long — dark scenes
    /// shouldn't read as letterboxing.
    static let contractDelay: TimeInterval = 1.0
    /// A growing crop (bars disappearing) is adopted after this long.
    static let expandDelay: TimeInterval = 0.15
    /// A new dominant hue must keep winning this long before it replaces the
    /// current one.
    static let hueConfirmDelay: TimeInterval = 0.1
    /// Emit only when some channel moved by more than this (0...255).
    static let minStep = 3
    /// "Off" as sent to the device: visually off, but never all-zero (an
    /// all-zero ff3 write flashes the device bright).
    static let off = RGB(r: 1, g: 1, b: 1)

    private var rect: PixelRect?
    private var pendingRect: PixelRect?
    private var pendingRectSince: TimeInterval = 0

    private var bin: Int?
    private var pendingBin: Int?
    private var pendingBinSince: TimeInterval?

    private var target: SIMD3<Float>?
    private var smoothed: SIMD3<Float>?
    private var lastTick: TimeInterval?
    private var lastEmitted: RGB?

    mutating func reset() { self = AmbientTracker() }

    mutating func ingest(_ frame: AmbientFrame, at t: TimeInterval) {
        let r = stableRect(AmbientColor.contentRect(frame), at: t)
        let s = AmbientColor.extract(frame, in: r)
        let value = s.color * s.intensity

        if target == nil || sameHue(s.hueBin, bin) {
            bin = s.hueBin
            target = value
            pendingBinSince = nil
            return
        }
        if pendingBinSince == nil || !sameHue(s.hueBin, pendingBin) {
            pendingBin = s.hueBin
            pendingBinSince = t
        }
        if t - pendingBinSince! >= Self.hueConfirmDelay {
            bin = s.hueBin
            target = value
            pendingBinSince = nil
        }
    }

    /// Advances smoothing; returns a color only when it changed enough to send.
    mutating func tick(at t: TimeInterval) -> RGB? {
        guard let target else { return nil }
        let dt = lastTick.map { max(0, t - $0) } ?? 0
        lastTick = t
        if let s = smoothed {
            let a = Float(1 - exp(-dt / Self.tau))
            smoothed = s + (target - s) * a
        } else {
            smoothed = target
        }
        let out = Self.rgb(smoothed!)
        if let last = lastEmitted,
           abs(Int(last.r) - Int(out.r)) <= Self.minStep,
           abs(Int(last.g) - Int(out.g)) <= Self.minStep,
           abs(Int(last.b) - Int(out.b)) <= Self.minStep {
            return nil
        }
        lastEmitted = out
        return out
    }

    /// Adjacent bins count as the same hue (a color on a bin border shouldn't
    /// trigger the switch delay); nil (blended/neutral) only matches nil.
    private func sameHue(_ a: Int?, _ b: Int?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            let d = abs(x - y)
            return min(d, AmbientColor.hueBins - d) <= 1
        default: return false
        }
    }

    private mutating func stableRect(_ c: PixelRect, at t: TimeInterval) -> PixelRect {
        guard let cur = rect else {
            rect = c
            return c
        }
        if c == cur {
            pendingRect = nil
            return cur
        }
        if c != pendingRect {
            pendingRect = c
            pendingRectSince = t
        }
        let held = t - pendingRectSince
        if held >= (c.contains(cur) ? Self.expandDelay : Self.contractDelay) {
            rect = c
            pendingRect = nil
        }
        return rect!
    }

    /// Never all-zero: an all-zero ff3 write flashes the device bright.
    private static func rgb(_ c: SIMD3<Float>) -> RGB {
        func b(_ v: Float) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        let out = RGB(r: b(c.x), g: b(c.y), b: b(c.z))
        return out == RGB(r: 0, g: 0, b: 0) ? off : out
    }
}
