// Full-screen test patterns for ambient-mode verification (scripts/ambient-test.sh).
// Usage: swift colorwall.swift <displayIndex> <scenario[:seconds]>...
//   scenarios: red green blue yellow cyan magenta white black
//              edges (red edges, blue center) letterbox (orange + 12% black bars)
//              darkmovie (black + small teal object) alternate (red/blue at 1 Hz)
// Prints "<epoch-seconds> <scenario>" at each switch.
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let screenIndex = Int(args.first ?? "0") ?? 0
let steps: [(String, Double)] = args.dropFirst().map {
    let p = $0.split(separator: ":")
    return (String(p[0]), p.count > 1 ? Double(p[1])! : 4)
}

final class Pattern: NSView {
    var scenario = "black"
    var phase = false
    override func draw(_ r: NSRect) {
        let b = bounds
        func fill(_ c: NSColor, _ rect: NSRect) { c.setFill(); rect.fill() }
        func rgb(_ r: CGFloat, _ g: CGFloat, _ bl: CGFloat) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: bl, alpha: 1)
        }
        switch scenario {
        case "red": fill(rgb(1, 0, 0), b)
        case "green": fill(rgb(0, 1, 0), b)
        case "blue": fill(rgb(0, 0, 1), b)
        case "yellow": fill(rgb(1, 1, 0), b)
        case "cyan": fill(rgb(0, 1, 1), b)
        case "magenta": fill(rgb(1, 0, 1), b)
        case "white": fill(rgb(1, 1, 1), b)
        case "edges":
            fill(rgb(1, 0, 0), b)
            fill(rgb(0, 0, 1), b.insetBy(dx: b.width * 0.2, dy: b.height * 0.2))
        case "letterbox":
            fill(.black, b)
            fill(rgb(1, 0.5, 0), b.insetBy(dx: 0, dy: b.height * 0.12))
        case "darkmovie":
            fill(.black, b)
            fill(rgb(0, 0.8, 0.7), NSRect(x: b.midX - b.width * 0.08, y: b.midY - b.height * 0.1,
                                          width: b.width * 0.16, height: b.height * 0.2))
        case "alternate": fill(phase ? rgb(0, 0, 1) : rgb(1, 0, 0), b)
        default: fill(.black, b)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[min(screenIndex, NSScreen.screens.count - 1)]
let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
win.level = .screenSaver
win.collectionBehavior = [.canJoinAllSpaces, .stationary]
let view = Pattern(frame: NSRect(origin: .zero, size: screen.frame.size))
win.contentView = view
win.setFrame(screen.frame, display: true)
win.orderFrontRegardless()

func show(_ name: String) {
    view.scenario = name
    view.needsDisplay = true
    print(String(format: "%.3f %@", Date().timeIntervalSince1970, name))
    fflush(stdout)
}

Task { @MainActor in
    for (name, secs) in steps {
        show(name)
        if name == "alternate" {
            let end = Date().addingTimeInterval(secs)
            while Date() < end {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                view.phase.toggle()
                view.needsDisplay = true
                print(String(format: "%.3f alternate-%@", Date().timeIntervalSince1970, view.phase ? "blue" : "red"))
                fflush(stdout)
            }
        } else {
            try? await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        }
    }
    exit(0)
}
app.run()
