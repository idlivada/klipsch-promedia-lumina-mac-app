import SwiftUI
import LuminaProtocol

enum ColorMath {
    /// h in 0..<1, s and v in 0...1
    static func hsvToRGB(h: Double, s: Double, v: Double) -> RGB {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        func byte(_ x: Double) -> UInt8 { UInt8(min(255, max(0, Int(round(x * 255))))) }
        return RGB(r: byte(r), g: byte(g), b: byte(b))
    }

    static func rgbToHS(_ rgb: RGB) -> (h: Double, s: Double) {
        let r = Double(rgb.r) / 255, g = Double(rgb.g) / 255, b = Double(rgb.b) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        guard delta > 0, maxC > 0 else { return (0, 0) }
        var h: Double
        if maxC == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, delta / maxC)
    }
}

/// HSV color wheel: hue around the rim, saturation from center to edge.
/// Always emits full-value (v = 1) colors — `staticColor` is the *true* color
/// and brightness is applied separately by RGB-scaling on write, so baking
/// brightness in here would compound the dimming.
struct ColorWheelView: View {
    var rgb: RGB
    var onChange: (RGB) -> Void
    var onEditingChanged: (Bool) -> Void

    private let size: CGFloat = 140

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: hueColors, center: .center))
            Circle()
                .fill(RadialGradient(
                    colors: [.white, .white.opacity(0)],
                    center: .center, startRadius: 0, endRadius: size / 2
                ))
            Circle()
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            indicator
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged {
                    onEditingChanged(true)
                    handle($0.location)
                }
                .onEnded { _ in onEditingChanged(false) }
        )
    }

    private var hueColors: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
            Color(hue: $0, saturation: 1, brightness: 1)
        }
    }

    private var indicator: some View {
        let (h, s) = ColorMath.rgbToHS(rgb)
        let radius = s * (size / 2 - 8)
        let angle = h * 2 * .pi
        return Circle()
            .fill(Color(rgb: rgb))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: 16, height: 16)
            .shadow(radius: 1)
            .offset(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    private func handle(_ location: CGPoint) {
        let dx = location.x - size / 2
        let dy = location.y - size / 2
        var h = atan2(dy, dx) / (2 * .pi)
        if h < 0 { h += 1 }

        // Snap to the nearest 30° anchor hue (red, orange, yellow, ...) within ±4°.
        let anchor = (h * 12).rounded() / 12
        if abs(h - anchor) <= 4.0 / 360 {
            h = anchor.truncatingRemainder(dividingBy: 1)
        }

        // Snap near-rim picks to full saturation.
        var s = min(1, sqrt(dx * dx + dy * dy) / (size / 2 - 8))
        if s > 0.92 { s = 1 }

        onChange(ColorMath.hsvToRGB(h: h, s: s, v: 1))
    }
}
