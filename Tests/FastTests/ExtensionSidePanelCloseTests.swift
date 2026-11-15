import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Fast

/// #732: removing an extension's content must also return its reserved
/// width. These exercise actual panel methods and ChatRoom's native layout,
/// with generated local extension pages and an unshown window.
@MainActor
@Suite(.serialized)
struct ExtensionSidePanelCloseTests {
    private struct Page: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions()
        }
    }

    private struct Room: View {
        let browser: Browser
        let page: NSView
        var body: some View {
            ChatRoom(open: browser.chatOpen, rim: .init(card: true), width: 360, leading: browser.chatLeads) {
                Page(view: page)
                ChatColumnHost(browser: browser, shown: browser.chatOpen, corner: 12, width: 360, leading: browser.chatLeads)
            }
            .frame(width: 1000, height: 600)
        }
    }

    @MainActor
    private final class Fixture {
        let browser: Browser
        let owner = Extensions.shared
        let folder: URL
        let page: NSView
        let window: NSWindow
        let host: NSHostingView<Room>
        let oldPrefs: (Bool, Flank)
        private(set) var id: String?

        init(flank: Flank) throws {
            let madeBrowser = Browser(windowID: UUID())
            let madePage = NSView()
            browser = madeBrowser
            page = madePage
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("panel-close-732-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #"{"manifest_version":3,"name":"Panel close fixture","version":"1.0","side_panel":{"default_path":"panel.html"}}"#
                .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try "<!doctype html><title>Panel close fixture</title><p>Local panel</p>"
                .write(to: folder.appendingPathComponent("panel.html"), atomically: true, encoding: .utf8)
            oldPrefs = (madeBrowser.prefs.sidebar, madeBrowser.prefs.sideFlank)
            host = NSHostingView(rootView: Room(browser: madeBrowser, page: madePage))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            browser.prefs.sidebar = true
            browser.prefs.sideFlank = flank
            window.isReleasedWhenClosed = false
            window.contentView = host
            owner.follow(browser)
            layout()
        }

        func install() async throws {
            owner.installFolder(at: folder, confirm: false)
            for _ in 0..<200 {
                if let item = owner.installed.first(where: { $0.source == folder.path }), owner.contexts[item.id] != nil {
                    id = item.id
                    return
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            Issue.record("Generated local panel fixture did not load")
            _ = try #require(id)
        }

        func open(_ tabID: Int? = nil) throws {
            owner.openPanel(try #require(id), in: browser, tabID: tabID)
        }

        func panel(_ tabID: Int? = nil) throws -> ExtensionSidePanelPage {
            try #require(owner.panelPages(in: browser).first { $0.id == id && $0.targetTabID == tabID })
        }

        func layout() {
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
        }

        func settle() async throws {
            // Includes the next-frame model write. Then wait only for the
            // bounded real transition, rather than assuming a particular pace.
            try await Task.sleep(for: .milliseconds(60))
            for _ in 0..<250 {
                layout()
                if !browser.chatMoving { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Panel transition did not release its movement hold")
        }

        func geometry(open: Bool) throws {
            layout()
            let column = try #require(browser.chatColumnView)
            let native = try #require(column.subviews.first?.layer)
            native.removeAllAnimations()
            layout()
            let rect = page.convert(page.bounds, to: host)
            let room = open ? ChatRoom.room(.init(card: true), width: 360) : 0
            let expectedX = open && browser.chatLeads ? room : 0
            print("PANEL_CLOSE open=\(open) leading=\(browser.chatLeads) page=\(rect) model=\(browser.chatOpen) panels=\(owner.panelPages(in: browser).count)")
            #expect(abs(rect.width - (1000 - room)) < 0.5)
            #expect(abs(rect.minX - expectedX) < 0.5)
            #expect(browser.chatOpen == open)
            #expect(native.opacity == (open ? 1 : 0))
        }

        func close() {
            // Remove only this fixture, never another test's extensions.
            for item in owner.installed where item.source == folder.path { owner.remove(item.id) }
            owner.unfollow(browser)
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.sidebar = oldPrefs.0; browser.prefs.sideFlank = oldPrefs.1
            window.contentView = nil
            window.close()
            if let windowID = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func withPanel(_ flank: Flank, _ check: (Fixture) async throws -> Void) async throws {
        try #require(Store.testing, "Panel fixtures must never install into a personal profile")
        _ = NSApplication.shared
        let fixture = try Fixture(flank: flank)
        defer { fixture.close() }
        try await fixture.install()
        try await check(fixture)
    }

    @Test(arguments: [Flank.left, .right])
    func closingTheSelectedPanelReturnsPageWidthWithOtherPanelsCached(_ flank: Flank) async throws {
        try await withPanel(flank) { fixture in
            try fixture.open()
            try fixture.open(7)
            try await fixture.settle()
            #expect(fixture.owner.panelPages(in: fixture.browser).count == 2)
            try fixture.geometry(open: true)
            let selected = try fixture.panel(7)
            let id = try #require(fixture.id)
            let context = try #require(fixture.owner.contexts[id])
            try await selected.close(for: context)
            try await fixture.settle()
            #expect(fixture.browser.panelExtension == nil)
            #expect(fixture.owner.panelPages(in: fixture.browser).count == 1)
            try fixture.geometry(open: false)
            fixture.owner.closePanel(try #require(fixture.id), in: fixture.browser, tabID: 7)
            try await fixture.settle()
            try fixture.geometry(open: false)
        }
    }

    @Test(arguments: [Flank.left, .right])
    func closingAHiddenPanelPreservesTheSelectedPanelAndNativeChat(_ flank: Flank) async throws {
        try await withPanel(flank) { fixture in
            try fixture.open()
            try fixture.open(7)
            try await fixture.settle()
            // Another sign-in owns no cached page here. Matching extension
            // and target-tab strings alone cannot authorize closing ours.
            let foreign = Extensions(signIn: UUID())
            foreign.closePanel(try #require(fixture.id), in: fixture.browser, tabID: 7)
            try await fixture.settle()
            #expect(fixture.browser.panelExtension == fixture.id && fixture.browser.panelTabID == 7)
            try fixture.geometry(open: true)
            fixture.owner.closePanel(try #require(fixture.id), in: fixture.browser)
            try await fixture.settle()
            #expect(fixture.browser.panelExtension == fixture.id && fixture.browser.panelTabID == 7)
            #expect(fixture.owner.panelPages(in: fixture.browser).count == 1)
            try fixture.geometry(open: true)

            // Native chat selected in the same column: closing a cached
            // extension must not close that unrelated selection either.
            fixture.browser.panelExtension = nil
            fixture.owner.closePanel(try #require(fixture.id), in: fixture.browser, tabID: 7)
            try await fixture.settle()
            #expect(fixture.owner.panelPages(in: fixture.browser).isEmpty)
            try fixture.geometry(open: true)
        }
    }

    @Test(arguments: [Flank.left, .right])
    func openingThenClosingBeforeTheNextFrameEndsClosed(_ flank: Flank) async throws {
        try await withPanel(flank) { fixture in
            try fixture.open()
            #expect(!fixture.browser.chatOpen && fixture.browser.chatMoving)
            fixture.owner.closePanel(try #require(fixture.id), in: fixture.browser)
            try await fixture.settle()
            #expect(fixture.owner.panelPages(in: fixture.browser).isEmpty)
            try fixture.geometry(open: false)
        }
    }

    @Test(arguments: [Flank.left, .right])
    func closingThenReopeningBeforeTheNextFrameKeepsTheNewestPanel(_ flank: Flank) async throws {
        try await withPanel(flank) { fixture in
            try fixture.open()
            try await fixture.settle()
            fixture.browser.hideChat()
            try fixture.open(7)
            try await fixture.settle()
            // Also cross the old hideChat cleanup deadline: it must not
            // remove a reopened panel or take its room away.
            try await Task.sleep(for: .milliseconds(650))
            #expect(fixture.browser.panelExtension == fixture.id && fixture.browser.panelTabID == 7)
            _ = try fixture.panel(7)
            try fixture.geometry(open: true)
        }
    }

    @Test func aSupersededHideCannotCleanUpPanelsWhileTheNextOpenIsPending() async throws {
        try await withPanel(.left) { fixture in
            try fixture.open()
            try await fixture.settle()
            fixture.browser.hideChat()
            try await Task.sleep(for: .milliseconds(60))
            #expect(!fixture.browser.chatOpen)
            // Hold the next model write under test control. Its generation
            // is real, but no 599 ms scheduling race is needed to prove that
            // the older hide callback no longer owns this cached page.
            _ = fixture.browser.chatMovement.request(open: true, current: false, moving: true)
            try await Task.sleep(for: .milliseconds(650))
            _ = try fixture.panel()
            #expect(fixture.browser.panelExtension == fixture.id)
            fixture.browser.moveChat(open: false)
            try await fixture.settle()
            try fixture.geometry(open: false)
        }
    }
}
