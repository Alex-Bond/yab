import AppKit
import Testing
@testable import Fast

// Now's rows wear Settings' pen drawings: every kind names a drawing PenArt
// has, and draws it. YAB_NOW_SHEET=PATH writes every kind, light and dark,
// at a row's 22 points and at 64, to one PNG to look at.
@MainActor
struct NowPicturesTests {
    @Test func everyKindHasItsDrawing() {
        for (kind, drawing) in Pictures.kinds {
            #expect(PenArt.ink[drawing.ink] != nil, "\(kind) wears \(drawing.ink), which PenArt doesn't draw")
            #expect(Pictures.image(kind, side: 22, dark: false) != nil, "\(kind) has no picture")
        }
        #expect(PenArt.key("now") == "now")
    }

    @Test func aKindIsDrawnInkOnPaper() throws {
        let rep = try #require(Self.render(side: 22, scale: 2) { rect in
            Pictures.image("mail", side: 22, dark: false)?.draw(in: rect)
        })
        // The paper's corner is clear, its middle holds ink.
        #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.1)
        let middle = try #require(rep.colorAt(x: 22, y: 22))
        #expect(middle.alphaComponent > 0.9)
    }

    @Test func sheet() throws {
        guard let path = ProcessInfo.processInfo.environment["YAB_NOW_SHEET"] else { return }
        let kinds = ["now"] + Pictures.kinds.keys.sorted()
        let cell: CGFloat = 96, width = cell * 4
        let height = cell * CGFloat(kinds.count)
        let rep = try #require(Self.render(width: width, height: height, scale: 2) { _ in
            for (row, kind) in kinds.enumerated() {
                let y = height - cell * CGFloat(row + 1)
                for (column, dark) in [false, true].enumerated() {
                    let ground = NSRect(x: CGFloat(column) * cell * 2, y: y, width: cell * 2, height: cell)
                    (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.98, alpha: 1)).setFill()
                    ground.fill()
                    let big = NSRect(x: ground.minX + 12, y: y + 16, width: 64, height: 64)
                    let small = NSRect(x: ground.minX + 110, y: y + 37, width: 22, height: 22)
                    for rect in [big, small] {
                        if kind == "now" {
                            PenArt.draw("now", symbol: "now", color: .systemRed, in: rect, dark: dark, art: 0.78)
                        } else {
                            Pictures.image(kind, side: rect.width, dark: dark)?.draw(in: rect)
                        }
                    }
                    (kind as NSString).draw(at: NSPoint(x: ground.minX + 140, y: y + 40),
                                            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dark ? NSColor.white : NSColor.black])
                }
            }
        })
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    static func render(side: CGFloat, scale: CGFloat, _ draw: (NSRect) -> Void) -> NSBitmapImageRep? {
        render(width: side, height: side, scale: scale, draw)
    }

    static func render(width: CGFloat, height: CGFloat, scale: CGFloat, _ draw: (NSRect) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
