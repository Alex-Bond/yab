import AppKit
import Testing
@testable import Fast

/// Share the handoff suite's serialization: both own LinkWindow's open
/// windows across run-loop turns, and placement cascades from any open one.
extension LinkWindowHandoffTests {
    /// Identical on BASE and candidate: actual LinkWindow construction, native
    /// delegate messages and Store.settings. No candidate-only geometry helper.
    @Suite(.serialized)
    @MainActor
    struct SmallWindowGeometryTests {
        private static let key = "links.small.frame"

        private func fixture(_ body: (Browser) throws -> Void) throws {
            _ = NSApplication.shared
            try #require(Store.testing, "Only a synthetic test profile may own this fixture")
            try #require(LinkWindow.all.isEmpty, "Small Window fixtures must not overlap")
            let previous = Store.settings.object(forKey: Self.key)
            Store.settings.removeObject(forKey: Self.key)
            let id = UUID()
            let browser = Browser(windowID: id)
            try #require(browser.activeID == nil, "Do not select a tab or enter MailCenter in a geometry fixture")
            defer {
                for link in LinkWindow.all where browser.outside.contains(where: { $0 === link.tab }) {
                    link.window.close()
                    link.window.contentView = nil
                }
                browser.letGo()
                Store.settings.set(previous, forKey: Self.key)
                for space in browser.spaces {
                    let suffix = space.id == Space.firstID ? "" : "-\(space.id.uuidString)"
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)\(suffix).json"))
                }
            }
            try body(browser)
        }

        private func open(_ browser: Browser, size: NSSize? = nil, child: Bool = false) throws -> LinkWindow {
            let tab = browser.blankTab()
            if child { tab.opener = UUID(); tab.scripted = Date() }
            browser.prepare(tab)
            browser.outside.append(tab)
            LinkWindow.present(tab, for: browser, size: size)
            try #require(browser.activeID == nil)
            return try #require(LinkWindow.all.last { $0.tab === tab })
        }

        private func adjusted(_ link: LinkWindow) throws -> NSRect {
            let room = try #require(link.window.screen).visibleFrame
            return NSRect(x: room.minX + 36, y: room.minY + 42,
                          width: min(room.width - 80, 760), height: min(room.height - 80, 520)).integral
        }

        private func userResize(_ link: LinkWindow, to frame: NSRect) {
            // Deliver the same completion used by a native live resize. Direct
            // setFrame alone is tested separately and must never save a choice.
            let began = Notification(name: NSWindow.willStartLiveResizeNotification, object: link.window)
            link.window.delegate?.windowWillStartLiveResize?(began)
            link.window.setFrame(frame, display: false)
            link.window.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: link.window))
        }

        @Test func userResizeAndMoveSurviveClosingAndOpeningAnotherWindow() throws {
            try fixture { browser in
                let first = try open(browser)
                var frame = try adjusted(first)
                userResize(first, to: frame)
                frame.origin.x += 12
                first.window.delegate?.windowWillMove?(Notification(name: NSWindow.willMoveNotification, object: first.window))
                first.window.setFrame(frame, display: false)
                first.window.delegate?.windowDidMove?(Notification(name: NSWindow.didMoveNotification, object: first.window))
                #expect(Store.settings.array(forKey: Self.key) as? [Double] == [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) })
                first.window.close()
                let second = try open(browser)
                #expect(second.window.frame == frame)
                let viewport = try #require(second.window.contentView)
                #expect(viewport.bounds.size == second.window.contentRect(forFrameRect: frame).size)
            }
        }

        @Test func initialPlacementProgrammaticChangesAndCascadeNeverSave() throws {
            try fixture { browser in
                let first = try open(browser)
                #expect(Store.settings.object(forKey: Self.key) == nil)
                first.window.setFrame(try adjusted(first), display: false)
                #expect(Store.settings.object(forKey: Self.key) == nil)
                let second = try open(browser)
                #expect(second.window.frame.origin != first.window.frame.origin)
                #expect(Store.settings.object(forKey: Self.key) == nil)
                second.window.close()
                first.window.close()
                #expect(Store.settings.object(forKey: Self.key) == nil)
            }
        }

        @Test func pageSizedPopupNeitherReadsNorOverwritesOrdinaryChoice() throws {
            try fixture { browser in
                let ordinary = try open(browser)
                let frame = try adjusted(ordinary)
                userResize(ordinary, to: frame)
                ordinary.window.close()
                let saved = Store.settings.array(forKey: Self.key) as? [Double]
                #expect(saved != nil)
                for size in [NSSize(width: 500, height: 340), nil] as [NSSize?] {
                    let popup = try open(browser, size: size, child: true)
                    if size != nil { #expect(popup.window.frame.width == 500) }
                    #expect(popup.window.frame.size != frame.size)
                    userResize(popup, to: try adjusted(popup))
                    popup.window.delegate?.windowWillMove?(Notification(name: NSWindow.willMoveNotification, object: popup.window))
                    popup.window.setFrameOrigin(NSPoint(x: frame.minX + 24, y: frame.minY + 24))
                    popup.window.delegate?.windowDidMove?(Notification(name: NSWindow.didMoveNotification, object: popup.window))
                    #expect(Store.settings.array(forKey: Self.key) as? [Double] == saved)
                    popup.window.close()
                }
                #expect(try open(browser).window.frame == frame)
            }
        }

        @Test func removedOrSmallerDisplayFitsTheSavedFrameWithoutReplacingIt() throws {
            try fixture { browser in
                let saved = [50000.0, 50000.0, 5000.0, 4000.0]
                Store.settings.set(saved, forKey: Self.key)
                let link = try open(browser)
                let room = try #require(link.window.screen).visibleFrame
                #expect(link.window.frame == room.integral)
                #expect(Store.settings.array(forKey: Self.key) as? [Double] == saved)
            }
        }
    }
}
