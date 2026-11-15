import AppKit
import SwiftUI
import Testing
@testable import Fast

/// Exercise the real sidebar in its native split/toolbar host. A calculation
/// of the intended inset alone misses the opening layout that caused the gap.
@MainActor
@Suite(.serialized)
struct SettingsSidebarLayoutTests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        var found = (view as? T).map { [$0] } ?? []
        found += view.subviews.flatMap { descendants($0, of: type) }
        return found
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func host(height: CGFloat, dark: Bool, check: (NSWindow, SettingsModel) throws -> Void) throws {
        _ = NSApplication.shared
        let screen = try #require(TestScreen.screen, "Settings layout needs the farm test screen")
        let model = SettingsModel()
        let sidebar = NSHostingController(rootView: SettingsSidebar(model: model))
        sidebar.sizingOptions = []
        let split = NSSplitViewController()
        split.view.frame = NSRect(x: 0, y: 0, width: 760, height: 540)
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 170
        side.maximumThickness = 210
        side.canCollapse = false
        split.addSplitViewItem(side)
        let detail = NSViewController()
        detail.view = NSView()
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        let window = NSWindow(contentRect: split.view.frame,
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = split
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "SettingsSidebarLayoutTests")
        // Match restoration after the host has been attached, before the
        // first presentation. No corrective resize is allowed before check.
        window.setContentSize(NSSize(width: 760, height: height))
        split.splitView.setPosition(180, ofDividerAt: 0)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
        window.orderFront(nil)
        settle(window)
        try check(window, model)
    }

    private func checkGap(_ window: NSWindow) throws -> CGFloat {
        let root = try #require(window.contentView)
        let table = try #require(descendants(root, of: NSTableView.self).first)
        // The search is a bare text field inside a glass capsule (GlassSearch),
        // not an NSSearchField, whose unbezeled text overlaps its own mark.
        let field = try #require(descendants(root, of: NSTextField.self).first {
            $0.isEditable && $0.placeholderString == SettingsWords.text("Search")
        })
        let scroll = try #require(table.enclosingScrollView)
        try #require(table.numberOfRows > 0)
        let search = field.convert(field.bounds, to: table)
        let first = table.rect(ofRow: 0)
        let gap = first.minY - search.maxY
        // The native field is 22 pt inside a 32 pt capsule: the existing
        // 14 pt spacing below that capsule is 19 pt below the field itself.
        #expect((10...32).contains(gap), "First row is \(gap) pt below Search")
        #expect(abs(scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top) < 1,
                "The initial list must be at its top")
        #expect(scroll.contentView.contentInsets.top < 160, "No opening layout may leave a window-sized inset")
        return gap
    }

    @Test(arguments: [CGFloat(440), 540, 800], [false, true])
    func firstOpenAndReopenNeedNoResize(height: CGFloat, dark: Bool) throws {
        try host(height: height, dark: dark) { window, _ in
            let opened = try checkGap(window)
            // A turn later must not reveal a delayed oversized inset.
            settle(window)
            #expect(abs(try checkGap(window) - opened) < 1)
            window.orderOut(nil)
            window.orderFront(nil)
            settle(window)
            #expect(abs(try checkGap(window) - opened) < 1)
            window.setContentSize(NSSize(width: 760, height: height + 2))
            settle(window)
            #expect(abs(try checkGap(window) - opened) < 1,
                    "A tiny resize must not be what repairs the spacing")
        }
    }

    @Test func clearingSearchRestoresTheFirstRowBelowSearch() throws {
        try host(height: 540, dark: true) { window, model in
            let opened = try checkGap(window)
            model.search = "privacy"
            settle(window)
            _ = try checkGap(window)
            model.search = ""
            settle(window)
            // The full list starts from its top again, then brings the page
            // the search picked (Privacy) into the part nothing floats over
            // (b3bf10308). In a 540 pt window Privacy sits below the fold,
            // so the list is scrolled just far enough to show it, not left
            // at General: the inset must be the opening one, and the picked
            // row whole and below Search.
            let root = try #require(window.contentView)
            let table = try #require(descendants(root, of: NSTableView.self).first)
            let field = try #require(descendants(root, of: NSTextField.self).first {
                $0.isEditable && $0.placeholderString == SettingsWords.text("Search")
            })
            let scroll = try #require(table.enclosingScrollView)
            #expect(scroll.contentView.contentInsets.top < 160, "No window-sized inset after the search")
            let picked = try #require(table.selectedRow >= 0 ? table.rect(ofRow: table.selectedRow) : nil)
            let search = field.convert(field.bounds, to: table)
            let visible = scroll.contentView.bounds
            #expect(picked.minY >= search.maxY, "The picked page is under Search")
            #expect(picked.maxY <= visible.maxY + 0.5, "The picked page is below the fold")
            if picked.maxY <= visible.height - scroll.contentView.contentInsets.top {
                #expect(abs(try checkGap(window) - opened) < 1)
            }
        }
    }
}
