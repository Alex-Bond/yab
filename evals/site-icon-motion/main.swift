import AppKit
import SwiftUI

// Turns each Site Controls icon on and off in a window off every screen, reads
// its frames back, and measures how far anything is drawn outside its circle.
// A glyph part leaving the circle is the bug (2026-10-30, Automatic PiP row).

final class Model: ObservableObject { @Published var on = false }
struct Stage: View {
    let symbol: String
    @ObservedObject var model: Model
    var body: some View {
        SiteControlsIcon(symbol: symbol, on: model.on).frame(width: 160, height: 160)
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

struct Case { let symbol: String; let turnOn: Bool }
let cases = ["pip", "chevron.left.forwardslash.chevron.right", "moon", "checkmark.shield"]
    .flatMap { [Case(symbol: $0, turnOn: true), Case(symbol: $0, turnOn: false)] }
let frames = 40
var failed = false

/// Painted pixels farther from the center than the circle's edge, and how far.
func stray(_ rep: NSBitmapImageRep) -> (count: Int, reach: CGFloat) {
    let scale = CGFloat(rep.pixelsWide) / 160
    let center = CGFloat(rep.pixelsWide) / 2
    var count = 0
    var reach: CGFloat = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 else { continue }
            let distance = hypot(CGFloat(x) - center, CGFloat(y) - center) / scale
            if distance > 15.5 { count += 1; reach = max(reach, distance) }
        }
    }
    return (count, reach)
}

func run(_ index: Int) {
    guard index < cases.count else { exit(failed ? 1 : 0) }
    let turn = cases[index]
    let model = Model()
    model.on = !turn.turnOn
    let host = NSHostingView(rootView: Stage(symbol: turn.symbol, model: model))
    host.frame = NSRect(x: 0, y: 0, width: 160, height: 160)
    let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 160, height: 160),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .clear
    window.isOpaque = false
    window.contentView = host
    window.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        model.on = turn.turnOn
        var shots: [NSBitmapImageRep] = []
        var worst = (count: 0, reach: CGFloat(0))
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            shots.append(rep)
            let seen = stray(rep)
            if seen.count > worst.count { worst = seen }
            guard shots.count >= frames else { return }
            timer.invalidate()
            let name = "\(turn.symbol.prefix(8))-\(turn.turnOn ? "on" : "off")"
            write(shots, name: name)
            let good = worst.count == 0
            if !good { failed = true }
            print("\(good ? "PASS" : "FAIL") \(name): \(worst.count) stray pixels, reach \(String(format: "%.1f", worst.reach)) pt from center (circle is 14)")
            window.close()
            run(index + 1)
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// The first 24 frames as one sheet, 6 across.
func write(_ shots: [NSBitmapImageRep], name: String) {
    let side = 160, across = 6
    let picked = Array(shots.prefix(24))
    let sheet = NSImage(size: NSSize(width: side * across, height: side * 4))
    sheet.lockFocus()
    NSColor(white: 0.1, alpha: 1).setFill()
    NSRect(origin: .zero, size: sheet.size).fill()
    for (i, rep) in picked.enumerated() {
        rep.draw(in: NSRect(x: (i % across) * side, y: (3 - i / across) * side, width: side, height: side))
    }
    sheet.unlockFocus()
    if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: out.appendingPathComponent(name + ".png"))
    }
}

run(0)
app.run()
