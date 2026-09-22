import SwiftUI

/// Ambient mode: live swatch of the sampled screen color, display picker, and
/// the Screen Recording permission prompt.
struct AmbientControls: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(rgb: state.ambientColor))
                    .frame(width: 44, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.15)))
                    .animation(.linear(duration: 0.1), value: state.ambientColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if state.displays.count > 1 {
                Picker("Display", selection: Binding(
                    get: { state.ambientDisplayID ?? CGMainDisplayID() },
                    set: { state.setAmbientDisplay($0) }
                )) {
                    ForEach(state.displays) { Text($0.name).tag($0.id) }
                }
                .controlSize(.small)
            }

            switch state.ambientStatus {
            case .needsPermission:
                Text("Lumina needs Screen Recording access to follow your screen. Enable it in System Settings, then relaunch Lumina.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    Button("Retry") { state.retryAmbient() }
                }
                .controlSize(.small)
            case .failed:
                Button("Retry") { state.retryAmbient() }
                    .controlSize(.small)
            default:
                EmptyView()
            }
        }
        .onAppear { state.refreshDisplays() }
    }

    private var statusText: String {
        switch state.ambientStatus {
        case .running: "Following your screen"
        case .starting: "Starting…"
        case .stopped: "Paused"
        case .needsPermission: "Screen Recording access needed"
        case .failed(let msg): "Capture stopped: \(msg)"
        }
    }
}
