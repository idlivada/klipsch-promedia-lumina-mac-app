import Foundation

public struct RGB: Equatable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Pure byte <-> value codecs. Formulas marked CANDIDATE come from the
/// Fives-family protocol and must be confirmed against the Lumina in Phase 1.
public enum Encodings {
    // MARK: Volume (fa2) — CANDIDATE: 1 byte, 0..0x24

    public static let volumeMaxRaw = 36

    public static func volumeData(percent: Double) -> Data {
        let raw = Int((percent / 100 * Double(volumeMaxRaw)).rounded())
        return Data([UInt8(min(max(raw, 0), volumeMaxRaw))])
    }

    public static func volumePercent(raw: UInt8) -> Double {
        Double(min(Int(raw), volumeMaxRaw)) * 100 / Double(volumeMaxRaw)
    }

    // MARK: On/off toggles (fa3 mute, f05 night)

    public static func boolData(_ on: Bool) -> Data { Data([on ? 1 : 0]) }

    // MARK: 6-band EQ (f17) — VERIFIED 2026-07-17: 48-byte blob, six 8-byte
    // records [band, 0, freqLE16, 0, 1, 0, gain]; gain is signed dB, -6..+6.
    // Partial writes are ignored — always write the full 48 bytes.

    public static let eqRangeDB = -6...6
    public static let eqBandFrequencies = [50, 150, 400, 1000, 3500, 8000]

    public static func eqBlobTemplate() -> Data {
        var d = Data()
        for (i, f) in eqBandFrequencies.enumerated() {
            d.append(contentsOf: [UInt8(i), 0, UInt8(f & 0xff), UInt8(f >> 8), 0, 1, 0, 0])
        }
        return d
    }

    /// Patches only the gain bytes so unknown fields survive round-trips.
    /// Pass the last blob read from the device as `template` when available.
    public static func eqBlobData(gains: [Int], template: Data? = nil) -> Data? {
        var d = template ?? eqBlobTemplate()
        guard d.count == 48, gains.count == eqBandFrequencies.count else { return nil }
        for (i, g) in gains.enumerated() {
            let clamped = min(max(g, eqRangeDB.lowerBound), eqRangeDB.upperBound)
            d[d.startIndex + i * 8 + 7] = UInt8(bitPattern: Int8(clamped))
        }
        return d
    }

    public static func eqBlobGains(_ data: Data) -> [Int]? {
        guard data.count >= 48 else { return nil }
        return (0..<eqBandFrequencies.count).map {
            Int(Int8(bitPattern: data[data.startIndex + $0 * 8 + 7]))
        }
    }

    // MARK: Sub gain (fa4) — VERIFIED 2026-07-17: 1 byte, dB = raw - 20
    // (phone app showed +2 dB while fa4 read 22; unlike the Fives' 2-byte format)

    public static let subOffsetDB = 20
    public static let subGainRangeDB = -20...10

    public static func subGainData(db: Int) -> Data {
        let clamped = min(max(db, subGainRangeDB.lowerBound), subGainRangeDB.upperBound)
        return Data([UInt8(clamped + subOffsetDB)])
    }

    public static func subGainDB(raw: UInt8) -> Int { Int(raw) - subOffsetDB }

    // MARK: Mode color register (ff3) — two RGB triplets, meaning per mode.
    // Static/Breathe: [color, 000000] (phone-app format; brightness lives in
    // fea, which works in ALL modes). Music React / Aurora: gradient pair.
    // Pair writes must ride the same connection as the ff2 mode write.

    public static func colorPairData(_ a: RGB, _ b: RGB) -> Data {
        Data([a.r, a.g, a.b, b.r, b.g, b.b])
    }

    /// Static/Breathe brightness: the fea register is a read-only status mirror
    /// (the pod updates it; a BLE central cannot drive it), so brightness is
    /// applied by scaling the color the device displays — verified on hardware.
    /// Non-zero channels floor at 1 so an all-zero write (which flashes the
    /// device bright) never happens; brightness 0 reads as visually off.
    public static func scaled(_ c: RGB, brightnessPercent: Double) -> RGB {
        let f = min(max(brightnessPercent, 0), 100) / 100
        func s(_ v: UInt8) -> UInt8 {
            v == 0 ? 0 : UInt8(max(1, (Double(v) * f).rounded()))
        }
        return RGB(r: s(c.r), g: s(c.g), b: s(c.b))
    }

    /// Solid-color payload (Static/Breathe): the scaled color written twice.
    public static func solidColorData(_ c: RGB, brightnessPercent: Double) -> Data {
        let s = scaled(c, brightnessPercent: brightnessPercent)
        return Data([s.r, s.g, s.b, s.r, s.g, s.b])
    }
}
