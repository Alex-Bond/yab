import AppKit
import QuartzCore
import Testing
@testable import Fast

/// The native rows at their end must follow the foot while the player's
/// room disappears, rather than jump to the inset's final scroll limit.
@MainActor
@Suite(.serialized)
struct ColumnFooterTests {
    private func withPage(_ check: (ColumnPage, [ColumnItem]) async throws -> Void) async rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tabs = (0..<60).map { number in
            let tab = Fast.Tab()
            tab.restore(url: URL(string: "https://column-footer.invalid/\(number)")!, title: "Tab \(number)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        defer {
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        let room = CGRect(x: 0, y: 0, width: 240, height: 500)
        let window = NSWindow(contentRect: room, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: room); root.wantsLayer = true
        window.contentView = root
        defer { window.close() }
        let page = ColumnPage(browser: browser, space: browser.spaceID)
        page.frame = room
        root.addSubview(page)
        let items = ColumnLayout.live(browser, folders: browser.folderBook)
        page.live(items, head: [], frame: frame(70), look: look)
        page.layoutSubtreeIfNeeded()
        try await check(page, items)
    }

    private var look: ColumnPages.Look {
        ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0)
    }
    private func frame(_ foot: CGFloat) -> ColumnPages.Frame {
        ColumnPages.Frame(lead: 44, footRoom: foot, top: 36, foot: true)
    }

    /// The rows' own clock, held by the test: the document layer's
    /// animations stand where `put` and `advance` place them, however long
    /// a busy farm Mac takes between two lines. On m2 (11-05, 22 GB of
    /// swap) a 50 ms sleep ran past the whole 0.26 s hide, and the checks
    /// that need it still moving failed. Sublayers keep this clock; the
    /// clip above it keeps the real one.
    @MainActor private final class HeldClock {
        let layer: CALayer
        init(_ layer: CALayer) {
            self.layer = layer
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            hold { layer.timeOffset = now; layer.speed = 0 }
        }
        /// The clock `seconds` after the animation under `key` began.
        func put(_ key: String, at seconds: CFTimeInterval) throws {
            let begun = try #require(layer.animation(forKey: key)?.beginTime)
            try #require(begun > 0, "\(key) has no begin time: commit it first")
            hold { layer.timeOffset = begun + seconds }
        }
        func advance(_ seconds: CFTimeInterval) {
            hold { layer.timeOffset += seconds }
        }
        /// How long ago, on this clock, the animation under `key` began.
        func since(_ key: String) -> CFTimeInterval? {
            layer.animation(forKey: key).map { layer.timeOffset - $0.beginTime }
        }
        private func hold(_ change: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            change()
            CATransaction.commit()
            CATransaction.flush()
        }
    }

    /// How far, 0 to 1, a motion's curve has brought it `elapsed` seconds in.
    static func progress(_ motion: CABasicAnimation, after elapsed: CFTimeInterval) -> Double {
        let time = min(1, max(0, elapsed / motion.duration))
        guard let timing = motion.timingFunction else { return time }
        var one: [Float] = [0, 0], two: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &one)
        timing.getControlPoint(at: 2, values: &two)
        func bezier(_ s: Double, _ a: Float, _ b: Float) -> Double {
            3 * (1 - s) * (1 - s) * s * Double(a) + 3 * (1 - s) * s * s * Double(b) + s * s * s
        }
        var low = 0.0, high = 1.0
        for _ in 0..<50 {
            let middle = (low + high) / 2
            if bezier(middle, one[0], two[0]) < time { low = middle } else { high = middle }
        }
        return bezier((low + high) / 2, one[1], two[1])
    }

    @Test func shrinkingTheFootCompensatesTheNativeEndClamp() async throws {
        try await withPage { page, items in
            let clip = page.scrollView.contentView
            let document = try #require(page.scrollView.documentView)
            let insets = page.scrollView.contentInsets
            page.scroll(to: document.frame.height - clip.bounds.height + insets.top + insets.bottom)
            let before = page.offset
            #expect(abs(before + page.rowsClip.height - ColumnLayout.height(items) - SideBar.rowsTail) < 0.5)
            let last = try #require(items.last)
            page.live(items, head: [], frame: frame(37), look: look)
            let after = page.offset
            let clearance = after + page.rowsClip.height - ColumnLayout.height(items)
            print("COLUMN_FOOTER before=\(before) after=\(after) delta=\(after - before) clearance=\(clearance) clip=\(clip.bounds)")
            // This is AppKit's actual inset clamp, not a modelled offset.
            #expect(abs(after - before + 33) < 0.5)
            #expect(abs(clearance - SideBar.rowsTail) < 0.5)
            let layer = try #require(document.layer)
            let motion = try #require((layer.animationKeys() ?? []).compactMap {
                layer.animation(forKey: $0) as? CABasicAnimation
            }.first { $0.keyPath == "transform.translation.y" && $0.isAdditive })
            let from = try #require(motion.fromValue as? NSNumber).doubleValue
            #expect(abs(from / Double(ColumnCell.down(layer)) + 33) < 0.5)
            #expect(abs(motion.duration - Band.sink) < 0.001)
            #expect((motion.toValue as? NSNumber)?.doubleValue == 0)
            let timing = try #require(motion.timingFunction)
            var first: [Float] = [0, 0], second: [Float] = [0, 0]
            timing.getControlPoint(at: 1, values: &first)
            timing.getControlPoint(at: 2, values: &second)
            #expect(abs(first[0] - 0.45) < 0.001 && first[1] == 0)
            #expect(abs(second[0] - 0.25) < 0.001 && second[1] == 1)
            #expect(page.items.last?.id == last.id)
        }
    }

    @Test func shrinkingTheFootDoesNotMoveAMiddleReader() async throws {
        try await withPage { page, items in
            page.scroll(to: 400)
            let before = page.offset
            page.live(items, head: [], frame: frame(37), look: look)
            #expect(abs(page.offset - before) < 0.5)
            let layer = try #require(page.scrollView.documentView?.layer)
            #expect((layer.animationKeys() ?? []).allSatisfy {
                (layer.animation(forKey: $0) as? CABasicAnimation)?.keyPath != "transform.translation.y"
            })
        }
    }

    @Test func aReturningPlayerRebasesTheRowsFromTheirActualPresentation() async throws {
        try await withPage { page, items in
            let window = try #require(page.window)
            window.orderFrontRegardless()
            let clip = page.scrollView.contentView
            let document = try #require(page.scrollView.documentView)
            let layer = try #require(document.layer)
            let insets = page.scrollView.contentInsets
            page.scroll(to: document.frame.height - clip.bounds.height + insets.top + insets.bottom)
            CATransaction.flush()
            try await Task.sleep(nanoseconds: 50_000_000)
            let initial = page.offset
            let last = try #require(items.last)
            let initialY = try #require(page.onScreen[last.id]?["y"] as? Double)
            let unrelated = CABasicAnimation(keyPath: "opacity")
            unrelated.fromValue = 1; unrelated.toValue = 1; unrelated.duration = 30
            layer.add(unrelated, forKey: "test.unrelated")
            let clock = HeldClock(layer)
            page.live(items, head: [], frame: frame(37), look: look)
            CATransaction.flush()
            // The hide 60 ms into its 0.26 s: the reversal comes mid-motion,
            // on the rows' own clock. A detached layer's model value cannot
            // establish a reversal during visible motion.
            try clock.put("column.foot", at: 0.06)
            let hide = try #require(layer.animation(forKey: "column.foot") as? CABasicAnimation)
            let hideFrom = try #require(hide.fromValue as? NSNumber).doubleValue
            let presentation = try #require(layer.presentation())
            let drawn = presentation.transform.m42 - layer.transform.m42
            let down = ColumnCell.down(layer)
            #expect(abs(Double(drawn) - hideFrom * (1 - Self.progress(hide, after: 0.06))) < 0.05)
            #expect(drawn / down > -32.5 && drawn / down < -0.5)
            let yBefore = try #require(page.onScreen[last.id]?["y"] as? Double)
            let offsetBefore = page.offset
            page.live(items, head: [], frame: frame(70), look: look)
            let motion = try #require((layer.animationKeys() ?? []).compactMap {
                layer.animation(forKey: $0) as? CABasicAnimation
            }.first { $0.keyPath == "transform.translation.y" && $0.isAdditive })
            let from = try #require(motion.fromValue as? NSNumber).doubleValue
            #expect(abs(from - Double(drawn + (page.offset - offsetBefore) * down)) < 0.5)
            #expect(abs(motion.duration - 0.3) < 0.001)
            #expect(layer.animation(forKey: "test.unrelated") != nil)
            #expect(abs(page.offset - initial) < 0.5)
            CATransaction.flush()
            // At the turn the rows stand where they were drawn, and a frame
            // later where the return curve has brought them: no jump.
            try clock.put("column.foot", at: 0)
            let yTurn = try #require(page.onScreen[last.id]?["y"] as? Double)
            #expect(abs(yTurn - yBefore) < 0.5)
            clock.advance(1.0 / 60)
            let yAfter = try #require(page.onScreen[last.id]?["y"] as? Double)
            let travel = yBefore - initialY
            let expected = initialY + travel * (1 - Self.progress(motion, after: 1.0 / 60))
            #expect(abs(yAfter - expected) < 0.5, "y \(yAfter), the curve's \(expected)")
            clock.advance(0.35)
            let endY = try #require(page.onScreen[last.id]?["y"] as? Double)
            #expect(abs(endY - initialY) < 0.5)
            #expect(abs(page.offset + page.rowsClip.height - ColumnLayout.height(items) - SideBar.rowsTail) < 0.5)
            print("COLUMN_FOOTER_REVERSE initialY=\(initialY) beforeY=\(yBefore) turnY=\(yTurn) afterY=\(yAfter) "
                  + "expected=\(expected) endY=\(endY) drawn=\(drawn) from=\(from) since=\(clock.since("column.foot") ?? -1)")
        }
    }

    @Test func hideAndReturnBeforeCommitKeepTheAlreadyDrawnRow() async throws {
        try await withPage { page, items in
            let window = try #require(page.window)
            window.orderFrontRegardless()
            let clip = page.scrollView.contentView
            let document = try #require(page.scrollView.documentView)
            let layer = try #require(document.layer)
            let insets = page.scrollView.contentInsets
            page.scroll(to: document.frame.height - clip.bounds.height + insets.top + insets.bottom)
            CATransaction.flush()
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = try #require(layer.presentation())
            _ = try #require(clip.layer?.presentation())
            let last = try #require(items.last)
            let initialY = try #require(page.onScreen[last.id]?["y"] as? Double)
            let initialOffset = page.offset
            // Deliberately no await or CA commit between the two changes.
            page.live(items, head: [], frame: frame(37), look: look)
            page.live(items, head: [], frame: frame(70), look: look)
            #expect(layer.animation(forKey: "column.foot") == nil)
            #expect(abs(page.offset - initialOffset) < 0.5)
            CATransaction.flush()
            try await Task.sleep(nanoseconds: 16_000_000)
            let firstY = try #require(page.onScreen[last.id]?["y"] as? Double)
            #expect(abs(firstY - initialY) < 3)
            try await Task.sleep(nanoseconds: 350_000_000)
            let endY = try #require(page.onScreen[last.id]?["y"] as? Double)
            #expect(abs(endY - initialY) < 0.5)
            #expect(abs(page.offset + page.rowsClip.height - ColumnLayout.height(items) - SideBar.rowsTail) < 0.5)
            print("COLUMN_FOOTER_SAME_TICK initialY=\(initialY) firstY=\(firstY) endY=\(endY)")
        }
    }

    @Test(arguments: [false, true])
    func aMiddleScrollAnimationIsNotTakenForFooterMotion(duringHide: Bool) async throws {
        try await withPage { page, items in
            let window = try #require(page.window)
            window.orderFrontRegardless()
            let clip = page.scrollView.contentView
            let document = try #require(page.scrollView.documentView)
            let documentLayer = try #require(document.layer)
            // During the hide, the rows' clock is held 60 ms into it: the
            // middle scroll and the return come while it still moves.
            var clock: HeldClock?
            if duringHide {
                let insets = page.scrollView.contentInsets
                page.scroll(to: document.frame.height - clip.bounds.height + insets.top + insets.bottom)
                CATransaction.flush()
                try await Task.sleep(nanoseconds: 50_000_000)
                let held = HeldClock(documentLayer)
                page.live(items, head: [], frame: frame(37), look: look)
                CATransaction.flush()
                try held.put("column.foot", at: 0.06)
                clock = held
            } else {
                page.scroll(to: 400)
            }
            CATransaction.flush()
            try await Task.sleep(nanoseconds: 50_000_000)
            let clipLayer = try #require(clip.layer)
            page.scroll(to: 400)
            let oldOrigin = clip.bounds.minY
            page.scroll(to: 440)
            let scrolling = CABasicAnimation(keyPath: "bounds.origin.y")
            scrolling.fromValue = oldOrigin; scrolling.toValue = clip.bounds.minY
            scrolling.duration = 30
            clipLayer.add(scrolling, forKey: "test.scrolling")
            CATransaction.flush()
            try await Task.sleep(nanoseconds: 16_000_000)
            let shown = try #require(clipLayer.presentation())
            #expect(abs(clip.bounds.minY - shown.bounds.minY) > 30)
            let clipBefore = shown.bounds.minY
            let docShown = try #require(documentLayer.presentation())
            let footShift = docShown.transform.m42 - documentLayer.transform.m42
            if duringHide { #expect(abs(footShift) > 0.5) }
            let witness = try #require(items.first { page.onScreen[$0.id] != nil })
            let yBefore = try #require(page.onScreen[witness.id]?["y"] as? Double)
            page.live(items, head: [], frame: frame(duringHide ? 70 : 37), look: look)
            #expect(abs(page.offset - 440) < 0.5)
            if duringHide {
                let foot = try #require(documentLayer.animation(forKey: "column.foot") as? CABasicAnimation)
                let from = try #require(foot.fromValue as? NSNumber).doubleValue
                #expect(abs(from - Double(footShift)) < 0.5)
            } else {
                #expect(documentLayer.animation(forKey: "column.foot") == nil)
            }
            #expect(clipLayer.animation(forKey: "test.scrolling") != nil)
            CATransaction.flush()
            // The return stands at its start on the held clock, so the rows
            // move only with the clip's own scroll, on the real clock: none
            // of the foot's path is the scroll's, nor the scroll's the foot's.
            try clock?.put("column.foot", at: 0)
            try await Task.sleep(nanoseconds: 16_000_000)
            let yAfter = try #require(page.onScreen[witness.id]?["y"] as? Double)
            let clipAfter = try #require(clipLayer.presentation()).bounds.minY
            let scrollingDistance = abs(clipAfter - clipBefore)
            // One point of pixel rounding.
            #expect(abs(yAfter - yBefore) <= Double(scrollingDistance) + 1)
            print("COLUMN_FOOTER_MIDDLE_ANIMATED duringHide=\(duringHide) beforeY=\(yBefore) afterY=\(yAfter) footShift=\(footShift) scrollMove=\(scrollingDistance)")
        }
    }
}
