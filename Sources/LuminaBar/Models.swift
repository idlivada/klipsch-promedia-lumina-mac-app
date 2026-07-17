import Foundation
import LuminaProtocol

enum LightMode: UInt8, CaseIterable, Codable {
    case rainbow = 1
    case breathe = 2
    case staticColor = 3
    case aurora = 4
    case music = 5

    var label: String {
        switch self {
        case .rainbow: "Rainbow"
        case .breathe: "Breathe"
        case .staticColor: "Static"
        case .aurora: "Aurora"
        case .music: "Music"
        }
    }

    var symbol: String {
        switch self {
        case .rainbow: "rainbow"
        case .breathe: "wind"
        case .staticColor: "circle.fill"
        case .aurora: "sparkles"
        case .music: "music.note"
        }
    }
}

/// "Off" is not a mode: writing 0x06 to ff2 turns the lights off, and the last
/// active mode is restored on "on".
let lightsOffByte: UInt8 = 0x06

/// f24 — verified 2026-07-17: 00 rejected, Music confirmed 02, Surround
/// confirmed 03 by ear, Movie = 01 by elimination.
enum SoundMode: UInt8, CaseIterable {
    case movie = 1
    case music = 2
    case surround = 3

    var label: String {
        switch self {
        case .movie: "Movie"
        case .music: "Music"
        case .surround: "Surround"
        }
    }
}

/// Aurora tone = a gradient pair in ff3, same mechanism as Music React.
/// Byte values captured from the phone app 2026-07-17.
enum AuroraTone: String, CaseIterable {
    case cool = "Cool"
    case warm = "Warm"

    var start: RGB {
        switch self {
        case .cool: RGB(r: 0, g: 0, b: 255)
        case .warm: RGB(r: 255, g: 0, b: 0)
        }
    }

    var end: RGB {
        switch self {
        case .cool: RGB(r: 0, g: 255, b: 255)
        case .warm: RGB(r: 255, g: 127, b: 0)
        }
    }
}

/// Music React gradient presets — EXACT phone-app byte pairs (captured
/// 2026-07-17). The device only accepts these pairs as fixed gradients; any
/// other pair falls back to cycling through all presets.
struct MusicPreset: Identifiable {
    let id: Int
    let name: String
    let start: RGB
    let end: RGB

    static let all: [MusicPreset] = [
        MusicPreset(id: 0, name: "Blue to Purple", start: RGB(r: 0, g: 0, b: 255), end: RGB(r: 255, g: 0, b: 255)),
        MusicPreset(id: 1, name: "Cyan to Blue", start: RGB(r: 0, g: 255, b: 255), end: RGB(r: 0, g: 0, b: 255)),
        MusicPreset(id: 2, name: "Red to Purple", start: RGB(r: 255, g: 0, b: 0), end: RGB(r: 255, g: 0, b: 127)),
        MusicPreset(id: 3, name: "Yellow to Orange", start: RGB(r: 255, g: 255, b: 0), end: RGB(r: 255, g: 127, b: 0)),
    ]
}

/// Which controls render. Flip flags to true as Phase 1 verifies each mapping
/// (see PROTOCOL.md); unverified features stay hidden rather than silently broken.
struct ProtocolCapabilities {
    // Verified on Lumina fw 1.0.1 (see PROTOCOL.md)
    var lighting = true
    var staticColorPicker = true
    var breatheColor = true   // Breathe reads its color from ff3, same as Static
    var subGain = true        // fa4, 1 byte, dB = raw - 20
    var soundModes = true     // f24: Movie 01 / Music 02 / Surround 03
    var sixBandEQ = true      // f17 blob, gains signed dB -6..+6
    // Strong candidates — fa2/fa3/f05 present with plausible values; the app
    // itself is the final write-and-observe test
    var volume = true
    var mute = true
    var nightMode = true
    var auroraTone = true     // ff3 gradient pair while in mode 04
    var musicPresets = true   // ff3 gradient pair while in mode 05
}

let eqBandLabels = ["50", "150", "400", "1k", "3.5k", "8k"]
