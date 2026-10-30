import SwiftUI
import LuminaProtocol

/// Color wheel + swatch grid for Static and Breathe.
/// Static/Breathe color: the shared picker bound to `staticColor`.
struct ColorControls: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ColorPickerPanel(
            rgb: state.staticColor,
            onPick: { state.setStaticColor($0) },
            onEditingChanged: { state.setEditing(Lumina.staticColor, $0) }
        )
    }
}

/// Color wheel + preset swatches for any solid color (Static/Breathe, the
/// Audio mode's custom color).
struct ColorPickerPanel: View {
    let rgb: RGB
    let onPick: (RGB) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

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
                rgb: rgb,
                onChange: onPick,
                onEditingChanged: onEditingChanged
            )
            .frame(maxWidth: .infinity)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(Self.swatches.indices, id: \.self) { i in
                    let swatch = Self.swatches[i]
                    Button {
                        onPick(swatch)
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(rgb: swatch))
                            .frame(height: 26)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        rgb == swatch ? Color.primary : Color.black.opacity(0.15),
                                        lineWidth: rgb == swatch ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
