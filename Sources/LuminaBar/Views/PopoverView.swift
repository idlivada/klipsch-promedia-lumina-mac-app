import SwiftUI

struct PopoverView: View {
    @Environment(AppState.self) private var state
    @AppStorage("lumina.tab") private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker("", selection: $tab) {
                Text("Audio").tag(0)
                Text("Lighting").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                if tab == 0 {
                    AudioTab()
                } else {
                    LightingTab()
                }
            }
            .disabled(state.connection != .connected)
            .opacity(state.connection == .connected ? 1 : 0.5)

            if state.connection == .searching {
                Text("Searching… close the Klipsch app on your phone to connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.headline)
            Spacer()
            Menu {
                if state.connection == .released {
                    Button("Reconnect") { state.reconnect() }
                } else {
                    Button("Release to Phone App") { state.releaseToPhone() }
                }
                Divider()
                Button("Quit Lumina") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var statusColor: Color {
        switch state.connection {
        case .connected: .green
        case .searching: .orange
        case .released: .gray
        }
    }

    private var statusText: String {
        switch state.connection {
        case .connected: "ProMedia Lumina"
        case .searching: "Searching…"
        case .released: "Released"
        }
    }
}
