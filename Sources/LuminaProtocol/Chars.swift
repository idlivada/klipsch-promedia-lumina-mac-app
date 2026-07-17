import CoreBluetooth

/// Characteristic table for the Klipsch ProMedia Lumina (da6d0fXX vendor scheme,
/// shared with The Fives / Sevens / Nines). Verification status lives in PROTOCOL.md.
public enum Lumina {
    /// Expands a 3-hex-digit short id ("ff2") to the full vendor UUID,
    /// e.g. DA6D0FF2-0D18-442C-BABE-F85B5BAA6F11.
    public static func uuid(_ short: String) -> CBUUID {
        precondition(short.count == 3, "short char id must be 3 hex digits, e.g. \"ff2\"")
        return CBUUID(string: "DA6D0\(short.uppercased())-0D18-442C-BABE-F85B5BAA6F11")
    }

    public static let lightingService = CBUUID(string: "DA6D0FE1-0D18-442C-BABE-F85B5BAA6F11")

    // Lighting — verified on Lumina fw 1.0.1 (LUMINA_SPEAKER_APP.md §1)
    public static let lightMode = uuid("ff2")     // 1 byte: 0x01–0x05 modes, 0x06 = lights off
    public static let brightness = uuid("fea")    // 2 bytes: [pct, pct], 0–100 each, written identical
    public static let staticColor = uuid("ff3")   // 6 bytes: RGB triplet twice

    // Audio — verified on Lumina fw 1.0.1 during Phase 1 (2026-07-17), see PROTOCOL.md
    public static let volume = uuid("fa2")        // 1 byte, 0..0x24 (36 steps)
    public static let mute = uuid("fa3")          // 1 byte, 0/1
    public static let subGain = uuid("fa4")       // 1 byte, dB = raw - 20 (NOT the Fives' 2-byte format)
    public static let nightMode = uuid("f05")     // 1 byte, 0/1
    public static let eqBandCount = uuid("f16")   // read-only, reads 6
    public static let eqBlob = uuid("f17")        // 48 bytes: 6 records [band, 0, freqLE16, 0, 1, 0, gain(i8 dB)]
    public static let soundMode = uuid("f24")     // 1 byte: 01 Movie, 02 Music, 03 Virtual Surround (00 rejected)
    public static let input = uuid("fd2")         // 0..6

    // Present but vestigial/unused on Lumina (f02/f03/f04 legacy bass/mid/treble
    // all read 0x06; the 6-band EQ is f17). f27/f2c are unidentified.

    /// NEVER write these. fe8 is FACTORY RESET on this family; the others are
    /// unidentified write-only channels (fc6 is likely firmware update).
    public static let writeDenylist: Set<CBUUID> = [
        uuid("fe8"), uuid("fc6"), uuid("fa5"), uuid("fa6"), uuid("fe3"),
    ]
}
