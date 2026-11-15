import AppKit
import Testing
@testable import Fast

/// Rows must keep their inset in the window when their native parent's
/// bounds origin changes without its size changing. A sidebar resize used
/// to repair that stale page placement only because it invalidated the size.
@MainActor
@Suite(.serialized)
struct ColumnBoundsTests {
    @Test(arguments: [4.0, 8.0, 10.0])
    func sameSizeOriginChangesKeepTheRowsWindowInset(_ shift: Double) throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideWidth)
        prefs.sidebar = true; prefs.sideShut = false; prefs.sideWidth = 240
        let tab = Fast.Tab()
        tab.restore(url: URL(string: "https://column-bounds.invalid/")!, title: "Inset witness")
        browser.prepare(tab)
        browser.lay([tab])
        defer {
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.tabs.forEach { $0.close() }
            prefs.sidebar = old.0; prefs.sideShut = old.1; prefs.sideWidth = old.2
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }

        let room = CGRect(x: 0, y: 0, width: 240, height: 500)
        let root = NSView(frame: room)
        let window = NSWindow(contentRect: room, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        let pages = ColumnPages(browser: browser)
        pages.frame = room
        root.addSubview(pages)
        defer { pages.stop() }
        pages.given(ColumnPages.Frame(lead: 44, footRoom: 0, top: 36, foot: false),
                    look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0))
        pages.layoutSubtreeIfNeeded()
        pages.layout()
        let page = try #require(pages.shown)
        func row(in view: NSView) -> ColumnCell? {
            if let cell = view as? ColumnCell, cell.rowTab === tab { return cell }
            return view.subviews.lazy.compactMap { row(in: $0) }.first
        }
        let cell = try #require(row(in: page))
        #expect(cell.window === window)

        func agrees(_ phase: String) {
            let rect = cell.convert(cell.bounds, to: root)
            let parent = pages.convert(pages.bounds, to: root)
            let left = rect.minX - parent.minX
            let right = parent.maxX - rect.maxX
            print("COLUMN_BOUNDS phase=\(phase) shift=\(shift) left=\(left) right=\(right) page=\(page.frame) bounds=\(pages.bounds)")
            #expect(page.frame == pages.bounds)
            #expect(abs(left - SideBar.margin) < 0.01)
            #expect(abs(right - SideBar.margin) < 0.01)
        }
        agrees("initial")

        // No redundant sync for another pass at exactly the same bounds.
        let syncs = ColumnPages.laidSyncs
        pages.layout()
        #expect(ColumnPages.laidSyncs == syncs)

        pages.setBoundsOrigin(CGPoint(x: shift, y: 0))
        #expect(pages.bounds.size == room.size)
        pages.layout()
        agrees("same-size origin")

        // The reporter's workaround: changing the width must still lay out
        // correctly, but must no longer be required to restore the inset.
        pages.setFrameSize(CGSize(width: 260, height: room.height))
        pages.layout()
        agrees("resize control")

        pages.setBoundsOrigin(.zero)
        pages.layout()
        agrees("origin restored")

        // An origin-only pass during a live space slide must not move just
        // the active page relative to its neighbors. Landing already syncs.
        #expect(pages.beginSlide(order: [browser.spaceID], home: 0))
        let slidingFrame = page.frame
        let slidingSyncs = ColumnPages.laidSyncs
        pages.setBoundsOrigin(CGPoint(x: shift, y: 0))
        pages.layout()
        #expect(ColumnPages.laidSyncs == slidingSyncs)
        #expect(page.frame == slidingFrame)
        pages.endSlide()
        agrees("slide landed")
    }
}
