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

    // Audio — Fives-family candidates, pending Phase 1 verification on Lumina
    public static let volume = uuid("fa2")        // 1 byte, 0..0x24 (36 steps)
    public static let mute = uuid("fa3")          // 1 byte, 0/1
    public static let channelVolume = uuid("fa4") // 2 bytes [channel, level]; subwoofer = channel 0x04
    public static let bass = uuid("f02")          // byte = dB + 10, dB in -10..+6
    public static let mid = uuid("f03")
    public static let treble = uuid("f04")
    public static let nightMode = uuid("f05")     // 1 byte, 0/1
    public static let vocal = uuid("f06")         // 0..3 — sound-mode candidate
    public static let eqMode = uuid("f12")        // 0..5 — sound-mode candidate
    public static let input = uuid("fd2")         // 0..6

    /// NEVER write these. fe8 is FACTORY RESET on this family; the others are
    /// unidentified write-only channels (fc6 is likely firmware update).
    public static let writeDenylist: Set<CBUUID> = [
        uuid("fe8"), uuid("fc6"), uuid("fa5"), uuid("fa6"), uuid("fe3"),
    ]
}
