import SwiftUI
import LuminaProtocol

struct AudioTab: View {
    @Environment(AppState.self) private var state
    @AppStorage("lumina.eqExpanded") private var eqExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.caps.volume {
                volumeRow
            }

            if state.caps.soundModes {
                Picker("Sound Mode", selection: Binding(
                    get: { state.soundMode },
                    set: { state.setSoundMode($0) }
                )) {
                    ForEach(SoundMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if state.caps.nightMode {
                Toggle("Night Mode", isOn: Binding(
                    get: { state.nightMode },
                    set: { state.setNightMode($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if state.caps.subGain {
                subGainRow
            }

            if state.caps.sixBandEQ {
                DisclosureGroup("Equalizer", isExpanded: $eqExpanded) {
                    EQView()
                        .padding(.top, 6)
                }
                .font(.subheadline)
            } else {
                Text("EQ and sound modes appear after protocol discovery (see PROTOCOL.md).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            if state.caps.mute {
                Button {
                    state.setMuted(!state.muted)
                } label: {
                    Image(systemName: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.muted ? .red : .primary)
            }
            Slider(
                value: Binding(get: { state.volume }, set: { state.setVolume($0) }),
                in: 0...100,
                onEditingChanged: { state.setEditing(Lumina.volume, $0) }
            )
            Text("\(Int(state.volume))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var subGainRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Sub Gain")
                    .font(.subheadline)
                Spacer()
                Text(state.subGain >= 0 ? "+\(Int(state.subGain)) dB" : "\(Int(state.subGain)) dB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { state.subGain }, set: { state.setSubGain($0) }),
                in: Double(Encodings.subGainRangeDB.lowerBound)...Double(Encodings.subGainRangeDB.upperBound),
                step: 1,
                onEditingChanged: { state.setEditing(Lumina.channelVolume, $0) }
            )
        }
    }
}
