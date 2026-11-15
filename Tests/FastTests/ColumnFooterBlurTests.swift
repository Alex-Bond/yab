import AppKit
import QuartzCore
import Testing
@testable import Fast

/// The footer's native row mask and backdrop must use the same geometry
/// in the transaction that moves the footer, before a later AppKit pass.
@MainActor
@Suite(.serialized)
struct ColumnFooterBlurTests {
    private final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    private func fixture(_ check: (ColumnEndsLayers, NSView, NSView, EdgeBlurView) throws -> Void) throws {
        _ = NSApplication.shared
        let rect = CGRect(x: 0, y: 0, width: 240, height: 500)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = Flipped(frame: rect)
        host.wantsLayer = true
        let rows = Flipped(frame: rect)
        rows.wantsLayer = true
        window.contentView = host
        host.addSubview(rows)
        defer { window.close() }
        let ends = ColumnEndsLayers()
        ends.install(in: host, over: rows)
        ends.lay(in: rect, frame: frame(37))
        ends.depth(.init(above: 0, below: 1), grain: 0, tone: false)
        host.layoutSubtreeIfNeeded()
        let blur = try #require(host.subviews.compactMap { $0 as? EdgeBlurView }.first { $0.edge == .bottom })
        try check(ends, host, rows, blur)
    }

    private func frame(_ room: CGFloat) -> ColumnPages.Frame {
        .init(lead: 44, footRoom: room, top: 36, foot: true)
    }

    private func coherent(_ rows: NSView, _ blur: EdgeBlurView) throws {
        let backdrop = try #require(blur.layer?.sublayers?.first)
        let fade = try #require(backdrop.mask as? CAGradientLayer)
        #expect(backdrop.frame == blur.bounds)
        #expect(fade.frame == blur.bounds)
        let locations = try #require(fade.locations)
        // The first stop after zero is the end of the opaque footer;
        // the remaining native gradient is the ordinary 24-point fall.
        let start = try #require(locations.dropFirst().first).doubleValue
        #expect(abs((1 - start) * blur.bounds.height - ColumnEnds.footFall) < 0.001)
        let mask = try #require(rows.layer?.mask)
        let rowFade = try #require(mask.sublayers?.compactMap { $0 as? CAGradientLayer }.last)
        #expect(abs(rowFade.frame.minY - blur.frame.minY) < 0.001)
        #expect(abs(rowFade.frame.height - blur.frame.height) < 0.001)
        #expect(blur.hitTest(.zero) == nil)
    }

    @Test func risingPlayerUpdatesBackdropBeforeAnotherLayoutPass() throws {
        try fixture { ends, host, rows, blur in
            ends.lay(in: host.bounds, frame: frame(70))
            try coherent(rows, blur)
        }
    }

    @Test func hidingPlayerKeepsTheOrdinaryFalloff() throws {
        try fixture { ends, host, rows, blur in
            ends.lay(in: host.bounds, frame: frame(70))
            host.layoutSubtreeIfNeeded()
            ends.lay(in: host.bounds, frame: frame(37))
            try coherent(rows, blur)
        }
    }

    @Test func sameTransactionReversalsNeverReuseAnOldCurve() throws {
        try fixture { ends, host, rows, blur in
            for room in [CGFloat(70), 37, 53, 70] {
                ends.lay(in: host.bounds, frame: frame(room))
                try coherent(rows, blur)
                #expect(host.bounds == CGRect(x: 0, y: 0, width: 240, height: 500))
            }
        }
    }
}
