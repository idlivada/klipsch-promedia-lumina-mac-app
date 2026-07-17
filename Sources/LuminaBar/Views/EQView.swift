import SwiftUI
import LuminaProtocol

struct EQView: View {
    @Environment(AppState.self) private var state

    private var range: ClosedRange<Double> {
        Double(Encodings.eqRangeDB.lowerBound)...Double(Encodings.eqRangeDB.upperBound)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(eqBandLabels.indices, id: \.self) { i in
                    VStack(spacing: 4) {
                        Text(dbLabel(state.eqBands[i]))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                        VerticalSlider(
                            value: Binding(
                                get: { state.eqBands[i] },
                                set: { state.setEQBand(i, $0.rounded()) }
                            ),
                            range: range
                        )
                        .frame(width: 24, height: 90)
                        Text(eqBandLabels[i])
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Button("Flat") {
                for i in eqBandLabels.indices { state.setEQBand(i, 0) }
            }
            .controlSize(.small)
        }
    }

    private func dbLabel(_ v: Double) -> String {
        let i = Int(v.rounded())
        return i > 0 ? "+\(i)" : "\(i)"
    }
}

struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 4)
                    .frame(maxWidth: .infinity)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: max(0, fraction * h))
                    .frame(maxWidth: .infinity)
                Circle()
                    .fill(.white)
                    .shadow(radius: 1)
                    .frame(width: 12, height: 12)
                    .offset(y: -(fraction * (h - 12)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = 1 - min(max(g.location.y / h, 0), 1)
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
}
