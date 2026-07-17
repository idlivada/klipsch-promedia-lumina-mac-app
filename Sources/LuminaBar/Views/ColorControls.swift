import SwiftUI
import LuminaProtocol

/// Swatch grid + native color picker for Static (and Breathe, once verified).
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
        VStack(alignment: .leading, spacing: 8) {
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

            ColorPicker(
                "Custom Color",
                selection: Binding(
                    get: { Color(rgb: state.staticColor) },
                    set: { state.setStaticColor(RGB(color: $0)) }
                ),
                supportsOpacity: false
            )
            .font(.subheadline)
        }
    }
}

extension RGB {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            r: UInt8((ns.redComponent * 255).rounded()),
            g: UInt8((ns.greenComponent * 255).rounded()),
            b: UInt8((ns.blueComponent * 255).rounded())
        )
    }
}
