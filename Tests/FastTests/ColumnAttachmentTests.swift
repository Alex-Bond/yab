import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct ColumnAttachmentTests {
    private func withBrowser(hidden: Bool, flank: Flank,
                             _ check: (Browser) async throws -> Void) async rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideWidth, prefs.sideFlank)
        prefs.sidebar = true; prefs.sideShut = hidden
        prefs.sideWidth = 240; prefs.sideFlank = flank
        defer {
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            prefs.sidebar = old.0; prefs.sideShut = old.1
            prefs.sideWidth = old.2; prefs.sideFlank = old.3
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        try await check(browser)
    }

    @Test(arguments: [Flank.left, .right])
    func hiddenColumnDoesNotClaimPageSwipes(flank: Flank) async throws {
        try await withBrowser(hidden: true, flank: flank) { browser in
            let frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: frame)
            root.wantsLayer = true
            window.contentView = root
            let column = ColumnView(browser: browser)
            column.frame = root.bounds
            root.addSubview(column)
            let catcher = SpaceSwipe.Catch(frame: NSRect(x: flank == .left ? 0 : 660, y: 0, width: 240, height: 650))
            catcher.browser = browser
            catcher.column = true
            root.addSubview(catcher)
            column.slide(out: false, animated: false)
            #expect(!catcher.acceptsInput)
            let local = NSPoint(x: catcher.frame.midX, y: 300)
            for phase: Int64 in [0, 1, 2, 4] {
                let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                    wheelCount: 2, wheel1: 0, wheel2: -80, wheel3: 0))
                cg.flags = []
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
                typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
                let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
                unsafeBitCast(symbol, to: Place.self)(cg, CGPoint(x: local.x, y: frame.height - local.y))
                let event = try #require(NSEvent(cgEvent: cg))
                try #require(event.window === window)
                #expect(!SpaceSwipe.claims(event))
                #expect(catcher.heard(event) === event)
            }
            column.slide(out: true, animated: false)
            #expect(catcher.acceptsInput)
            catcher.isHidden = true
            #expect(!catcher.acceptsInput)
            catcher.isHidden = false
            column.slide(out: false, animated: false)
            #expect(!catcher.acceptsInput)
            // Top tabs have their own catcher and stay usable with the
            // sidebar put away.
            catcher.column = false
            #expect(catcher.acceptsInput)
        }
    }

    /// The layer's actual position in the column, independent of which
    /// layer carries its drawing. The host's native frame stays full-window.
    private func origin(_ column: ColumnView) throws -> CGFloat {
        let host = try #require(column.subviews.first)
        let child = try #require(host.layer), parent = try #require(column.layer)
        #expect(host.frame == column.bounds)
        // A conversion across detached layer trees cannot measure the
        // parent-carried drawing. Require the real native ancestry first.
        var ancestor = child.superlayer
        while let layer = ancestor, layer !== parent { ancestor = layer.superlayer }
        try #require(ancestor === parent)
        return child.convert(child.bounds, to: parent).minX
    }

    @Test(arguments: [false, true], [Flank.left, .right])
    func zeroSizedUpdateSurvivesTheFirstNativeSize(hidden: Bool, flank: Flank) async throws {
        try await withBrowser(hidden: hidden, flank: flank) { browser in
            let column = ColumnView(browser: browser)
            let frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            let root = NSView(frame: frame); root.wantsLayer = true
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = root
            root.addSubview(column)
            // Real startup traces call updateNSView's slide at zero size,
            // then NSHostingView.setFrameSize clears its backing transform.
            #expect(column.frame == .zero)
            column.slide(out: !hidden, animated: false)
            column.frame = frame
            window.layoutIfNeeded(); root.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            let expected: CGFloat = hidden ? -280 * flank.sign : 0
            print("COLUMN_FIRST_SIZE hidden=\(hidden) flank=\(flank) state=\(column.benchState)")
            let initialX = try origin(column)
            #expect(abs(initialX - expected) < 0.5)
            #expect(column.shown == !hidden)
            column.setFrameSize(NSSize(width: 1100, height: 750))
            column.layoutSubtreeIfNeeded()
            let resizedX = try origin(column)
            #expect(abs(resizedX - expected) < 0.5)
        }
    }

    @Test(arguments: [false, true], [Flank.left, .right])
    func representableStartupKeepsItsInitialPosition(hidden: Bool, flank: Flank) async throws {
        try await withBrowser(hidden: hidden, flank: flank) { browser in
            let frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            let root = NSHostingView(rootView: ColumnHost(browser: browser, prefs: browser.prefs))
            root.sizingOptions = []; root.frame = frame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = root
            window.layoutIfNeeded(); root.layoutSubtreeIfNeeded()
            // Let the first hosted SwiftUI/native update finish, without a
            // resize, pointer event, preference change or explicit slide.
            try await Task.sleep(nanoseconds: 50_000_000)
            let column = try #require(browser.column)
            let expected: CGFloat = hidden ? -280 * flank.sign : 0
            print("COLUMN_HOSTED_STARTUP hidden=\(hidden) flank=\(flank) state=\(column.benchState)")
            #expect(column.window === window)
            #expect(column.bounds.size == frame.size)
            let initialX = try origin(column)
            #expect(abs(initialX - expected) < 0.5)
            #expect(column.shown == !hidden)
        }
    }

    @Test(arguments: [Flank.left, .right])
    func layoutAndReversalKeepTheSlideAndOtherAnimations(flank: Flank) async throws {
        try await withBrowser(hidden: true, flank: flank) { browser in
            let column = ColumnView(browser: browser)
            let frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: frame); root.wantsLayer = true
            window.contentView = root
            root.addSubview(column); column.frame = frame
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            // Validate native attachment before beginning the motion.
            _ = try origin(column)
            column.slide(out: false, animated: false)
            column.slide(out: true, animated: true)
            // Search both storage sites so this same regression compiles
            // and exercises actual animations on pristine main too.
            let layers = [column.layer, column.subviews.first?.layer].compactMap { $0 }
            let carrier = try #require(layers.first { layer in
                (layer.animationKeys() ?? []).contains { $0.hasPrefix("column.slide.") }
            })
            let unrelated = CABasicAnimation(keyPath: "opacity")
            unrelated.fromValue = 1; unrelated.toValue = 1; unrelated.duration = 30
            carrier.add(unrelated, forKey: "test.unrelated")
            let first = try #require(carrier.animationKeys()?.first { $0.hasPrefix("column.slide.") })
            column.setFrameSize(NSSize(width: 1000, height: 700)); column.layoutSubtreeIfNeeded()
            #expect(carrier.animation(forKey: first) != nil)
            let resizedX = try origin(column)
            #expect(abs(resizedX) < 0.5)
            let expected: CGFloat = -280 * flank.sign
            column.slide(out: false, animated: true)
            #expect(carrier.animation(forKey: first) == nil)
            #expect((carrier.animationKeys() ?? []).filter { $0.hasPrefix("column.slide.") }.count == 1)
            #expect(carrier.animation(forKey: "test.unrelated") != nil)
            let reversedX = try origin(column)
            #expect(abs(reversedX - expected) < 0.5)
            column.settleSlide(out: true)
            #expect(!(carrier.animationKeys() ?? []).contains { $0.hasPrefix("column.slide.") })
            #expect(carrier.animation(forKey: "test.unrelated") != nil)
            let settledX = try origin(column)
            #expect(abs(settledX) < 0.5)
        }
    }
}
