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

/// Raw values unknown until Phase 1 discovery maps the sound-mode characteristic.
enum SoundMode: String, CaseIterable {
    case movie = "Movie"
    case music = "Music"
    case surround = "Surround"
}

enum AuroraTone: String, CaseIterable {
    case cool = "Cool"
    case warm = "Warm"
}

struct MusicPreset: Identifiable {
    let id: Int
    let name: String
    let start: RGB
    let end: RGB

    static let all: [MusicPreset] = [
        MusicPreset(id: 0, name: "Blue to Purple", start: RGB(r: 0, g: 64, b: 255), end: RGB(r: 128, g: 0, b: 128)),
        MusicPreset(id: 1, name: "Cyan to Blue", start: RGB(r: 0, g: 255, b: 255), end: RGB(r: 0, g: 64, b: 255)),
        MusicPreset(id: 2, name: "Red to Purple", start: RGB(r: 255, g: 0, b: 0), end: RGB(r: 128, g: 0, b: 128)),
        MusicPreset(id: 3, name: "Yellow to Orange", start: RGB(r: 255, g: 220, b: 0), end: RGB(r: 255, g: 120, b: 0)),
    ]
}

/// Which controls render. Flip flags to true as Phase 1 verifies each mapping
/// (see PROTOCOL.md); unverified features stay hidden rather than silently broken.
struct ProtocolCapabilities {
    // Verified on Lumina fw 1.0.1
    var lighting = true
    var staticColorPicker = true
    // Strong Fives-family candidates — the app itself is the write-and-observe test
    var volume = true
    var mute = true
    var nightMode = true
    var subGain = true
    // Unknown until discovery
    var breatheColor = false
    var auroraTone = false
    var musicPresets = false
    var soundModes = false
    var sixBandEQ = false
}

/// 6-band labels for the Lumina EQ; the characteristic mapping is filled in
/// after Phase 1 (per-band chars vs one multi-byte blob).
let eqBandLabels = ["50", "150", "400", "1k", "3.5k", "8k"]
