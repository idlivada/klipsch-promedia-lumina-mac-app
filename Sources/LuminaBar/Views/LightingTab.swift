import SwiftUI
import LuminaProtocol

struct LightingTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Lights", isOn: Binding(
                get: { state.lightsOn },
                set: { state.setLights(on: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            modeRow
                .disabled(!state.lightsOn)

            brightnessRow
                .disabled(!state.lightsOn)

            conditionalSection
                .disabled(!state.lightsOn)
        }
        .animation(.easeInOut(duration: 0.15), value: state.mode)
    }

    private var modeRow: some View {
        HStack(spacing: 6) {
            ForEach(LightMode.allCases, id: \.self) { m in
                modeTile(m.label, m.symbol, selected: state.mode == m && !state.ambientActive) {
                    state.setMode(m)
                }
            }
            if state.caps.ambient {
                modeTile("Ambient", "display", selected: state.ambientActive) {
                    state.setAmbient(true)
                }
            }
        }
    }

    private func modeTile(_ label: String, _ symbol: String, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .frame(height: 16)
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected && state.lightsOn
                          ? Color.accentColor.opacity(0.25)
                          : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var brightnessRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { state.brightness }, set: { state.setBrightness($0) }),
                    in: 0...100,
                    onEditingChanged: { state.setEditing(Lumina.staticColor, $0) }
                )
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.secondary)
            }
            .disabled(!state.brightnessAffectsCurrentMode)
            .opacity(state.brightnessAffectsCurrentMode ? 1 : 0.4)
            if !state.brightnessAffectsCurrentMode {
                Text("Brightness applies to Static and Breathe modes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var conditionalSection: some View {
        switch state.mode {
        case .staticColor where state.ambientActive:
            AmbientControls()
        case .staticColor:
            ColorControls()
        case .breathe:
            if state.caps.breatheColor {
                ColorControls()
            }
        case .aurora:
            if state.caps.auroraTone {
                Picker("Tone", selection: Binding(
                    get: { state.auroraTone },
                    set: { state.setAuroraTone($0) }
                )) {
                    ForEach(AuroraTone.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        case .music:
            if state.caps.musicPresets {
                MusicPresetGrid()
            }
        case .rainbow:
            EmptyView()
        }
    }
}

struct MusicPresetGrid: View {
    @Environment(AppState.self) private var state

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(MusicPreset.all) { preset in
                Button {
                    state.setMusicPreset(preset.id)
                } label: {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(rgb: preset.start), Color(rgb: preset.end)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(height: 24)
                        .overlay(
                            Capsule().strokeBorder(
                                state.musicPresetID == preset.id ? Color.primary : .clear,
                                lineWidth: 2
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }
}

extension Color {
    init(rgb: RGB) {
        self.init(
            red: Double(rgb.r) / 255,
            green: Double(rgb.g) / 255,
            blue: Double(rgb.b) / 255
        )
    }
}
