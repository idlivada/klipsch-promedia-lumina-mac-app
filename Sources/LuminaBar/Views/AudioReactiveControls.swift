import SwiftUI

/// Audio mode: live swatch of the color being sent, palette picker, and the
/// Screen & System Audio Recording permission prompt (shared with Ambient).
struct AudioReactiveControls: View {
    @Environment(AppState.self) private var state

    private static let spectrumColors: [Color] = stride(from: 0.0, through: 0.8, by: 0.1).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(rgb: state.audioColor))
                    .frame(width: 44, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.15)))
                    .animation(.linear(duration: 0.05), value: state.audioColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(AudioPalette.allCases, id: \.self) { p in
                    GradientCapsuleButton(
                        colors: colors(for: p),
                        selected: state.audioPalette == p,
                        help: p.name
                    ) {
                        state.setAudioPalette(p)
                    }
                }
            }

            if state.audioPalette == .custom {
                ColorPickerPanel(rgb: state.audioCustomColor, onPick: { state.setAudioCustomColor($0) })
            }

            Text(state.inputSource == .bluetooth
                 ? "The speaker is on Bluetooth: the lights follow this Mac's audio, not your phone's."
                 : "The lights follow sound played by this Mac.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            switch state.audioStatus {
            case .needsPermission:
                Text("Lumina needs Screen & System Audio Recording access to hear your Mac. Enable it in System Settings, then relaunch Lumina.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    Button("Retry") { state.retryAudio() }
                }
                .controlSize(.small)
            case .failed:
                Button("Retry") { state.retryAudio() }
                    .controlSize(.small)
            default:
                EmptyView()
            }
        }
    }

    private func colors(for p: AudioPalette) -> [Color] {
        if let preset = p.preset { return [Color(rgb: preset.start), Color(rgb: preset.end)] }
        if p == .custom { return [Color(rgb: state.audioCustomColor)] }
        return Self.spectrumColors
    }

    private var statusText: String {
        switch state.audioStatus {
        case .running: state.audioColor == AmbientTracker.off ? "Waiting for audio" : "Following this Mac's audio"
        case .starting: "Starting…"
        case .stopped: "Paused"
        case .needsPermission: "Audio access needed"
        case .failed(let msg): "Capture stopped: \(msg)"
        }
    }
}
