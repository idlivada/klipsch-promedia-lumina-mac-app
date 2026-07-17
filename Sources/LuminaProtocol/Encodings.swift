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

    // MARK: EQ (f02/03/04) — CANDIDATE: byte = dB + 10, dB in -10..+6

    public static let eqRangeDB = -10...6

    public static func eqData(db: Int) -> Data {
        Data([UInt8(min(max(db, eqRangeDB.lowerBound), eqRangeDB.upperBound) + 10)])
    }

    public static func eqDB(byte: UInt8) -> Int { Int(byte) - 10 }

    // MARK: Sub gain (fa4) — CANDIDATE: [0x04, raw], Fives: dB = raw - 21.
    // The Lumina app shows -20..+10; calibrate subOffsetDB with 3-point Phase 1 data.

    public static let subChannel: UInt8 = 0x04
    public static let subOffsetDB = 21
    public static let subGainRangeDB = -20...10

    public static func subGainData(db: Int) -> Data {
        let clamped = min(max(db, subGainRangeDB.lowerBound), subGainRangeDB.upperBound)
        return Data([subChannel, UInt8(clamped + subOffsetDB)])
    }

    public static func subGainDB(raw: UInt8) -> Int { Int(raw) - subOffsetDB }

    // MARK: Brightness (fea) — VERIFIED: two identical percent bytes

    public static func brightnessData(percent: Double) -> Data {
        let p = UInt8(min(max(percent, 0), 100).rounded())
        return Data([p, p])
    }

    // MARK: Static color (ff3) — VERIFIED: RGB triplet written twice

    public static func colorData(_ c: RGB) -> Data {
        Data([c.r, c.g, c.b, c.r, c.g, c.b])
    }

    /// Brightness has no effect in Static mode (fea is animated-modes-only),
    /// so static dimming scales the RGB value locally before sending.
    public static func scaled(_ c: RGB, brightnessPercent: Double) -> RGB {
        let f = min(max(brightnessPercent, 0), 100) / 100
        return RGB(
            r: UInt8((Double(c.r) * f).rounded()),
            g: UInt8((Double(c.g) * f).rounded()),
            b: UInt8((Double(c.b) * f).rounded())
        )
    }
}
