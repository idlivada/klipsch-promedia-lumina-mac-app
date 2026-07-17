import SwiftUI

@main
struct LuminaApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra("Lumina", systemImage: "hifispeaker.2.fill") {
            PopoverView()
                .environment(state)
        }
        .menuBarExtraStyle(.window)
    }
}
