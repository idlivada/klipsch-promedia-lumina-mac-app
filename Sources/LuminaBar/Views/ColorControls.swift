import SwiftUI
import LuminaProtocol

/// Color wheel + swatch grid for Static and Breathe.
struct ColorControls: View {
    @Environment(AppState.self) private var state

    private static let swatches: [RGB] = [
        RGB(r: 255, g: 0, b: 0),     // red
        RGB(r: 255, g: 100, b: 0),   // orange
        RGB(r: 255, g: 220, b: 0),   // yellow
        RGB(r: 0, g: 255, b: 60),    // green
        RGB(r: 0, g: 255, b: 255),   // cyan
        RGB(r: 0, g: 90, b: 255),    // blue
        RGB(r: 130, g: 0, b: 255),   // purple
        RGB(r: 255, g: 0, b: 200),   // magenta
        RGB(r: 255, g: 150, b: 170), // pink
        RGB(r: 255, g: 255, b: 255), // white
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorWheelView(
                rgb: state.staticColor,
                onChange: { state.setStaticColor($0) },
                onEditingChanged: { state.setEditing(Lumina.staticColor, $0) }
            )
            .frame(maxWidth: .infinity)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(Self.swatches.indices, id: \.self) { i in
                    let swatch = Self.swatches[i]
                    Button {
                        state.setStaticColor(swatch)
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(rgb: swatch))
                            .frame(height: 26)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        state.staticColor == swatch ? Color.primary : Color.black.opacity(0.15),
                                        lineWidth: state.staticColor == swatch ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
