import AppKit
import QuartzCore
import Testing
@testable import Fast

/// The native rows at their end must follow the foot while the player's
/// room disappears, rather than jump to the inset's final scroll limit.
@MainActor
@Suite(.serialized)
struct ColumnFooterTests {
    /// The window's animations at a tenth of their speed, so a stall of the
    /// main thread can't carry the 0.3 s motion past what a test looks at.
    private func slowed(_ window: NSWindow) throws {
        try #require(window.contentView?.layer).speed = 0.1
    }

    /// Waits for what a test needs on screen, however busy the Mac is.
    private func until(_ seconds: Double = 5, _ done: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try !done(), Date() < deadline {
            CATransaction.flush()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

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
            try slowed(window)
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
            page.live(items, head: [], frame: frame(37), look: look)
            let down = ColumnCell.down(layer)
            // Require an actual frame between the ends. A detached layer's
            // model value cannot establish a reversal during visible motion.
            var drawn: CGFloat = 0
            try await until {
                drawn = try #require(layer.presentation()).transform.m42 - layer.transform.m42
                return drawn / down > -32.5 && drawn / down < -0.5
            }
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
            try await Task.sleep(nanoseconds: 16_000_000)
            let yAfter = try #require(page.onScreen[last.id]?["y"] as? Double)
            #expect(abs(yAfter - yBefore) < 3)
            try await until { !(layer.animationKeys() ?? []).contains { $0 != "test.unrelated" } }
            let endY = try #require(page.onScreen[last.id]?["y"] as? Double)
            #expect(abs(endY - initialY) < 0.5)
            #expect(abs(page.offset + page.rowsClip.height - ColumnLayout.height(items) - SideBar.rowsTail) < 0.5)
            print("COLUMN_FOOTER_REVERSE initialY=\(initialY) beforeY=\(yBefore) afterY=\(yAfter) endY=\(endY) drawn=\(drawn) from=\(from)")
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
            try slowed(window)
            let clip = page.scrollView.contentView
            let document = try #require(page.scrollView.documentView)
            if duringHide {
                let insets = page.scrollView.contentInsets
                page.scroll(to: document.frame.height - clip.bounds.height + insets.top + insets.bottom)
                CATransaction.flush()
                try await Task.sleep(nanoseconds: 50_000_000)
                page.live(items, head: [], frame: frame(37), look: look)
            } else {
                page.scroll(to: 400)
            }
            CATransaction.flush()
            try await Task.sleep(nanoseconds: 50_000_000)
            let clipLayer = try #require(clip.layer)
            let documentLayer = try #require(page.scrollView.documentView?.layer)
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
            var footShift: CGFloat = 0
            if duringHide {
                try await until {
                    footShift = try #require(documentLayer.presentation()).transform.m42 - documentLayer.transform.m42
                    return abs(footShift) > 0.5
                }
                #expect(abs(footShift) > 0.5)
            }
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
            try await Task.sleep(nanoseconds: 16_000_000)
            let yAfter = try #require(page.onScreen[witness.id]?["y"] as? Double)
            let clipAfter = try #require(clipLayer.presentation()).bounds.minY
            let scrollingDistance = abs(clipAfter - clipBefore)
            let remainingFoot = duringHide ? abs(footShift) : 0
            // The preserved arrival curve can move more than 3 points in
            // this interval. Bound the actual remaining path and the
            // independent scroll, allowing one point of pixel rounding.
            #expect(abs(yAfter - yBefore) <= Double(remainingFoot + scrollingDistance) + 1)
            print("COLUMN_FOOTER_MIDDLE_ANIMATED duringHide=\(duringHide) beforeY=\(yBefore) afterY=\(yAfter) remainingFoot=\(remainingFoot) scrollMove=\(scrollingDistance)")
        }
    }
}
