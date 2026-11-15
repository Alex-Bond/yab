import AppKit
import SwiftUI
import Testing
@testable import Fast

// A page's right-click menu in the app's own drawing (PageView.dress): the
// mark ⌘K wears for each of WebKit's rows, each picture once, and a row
// without one kept in the titles' column.
@MainActor
struct PageMenuMarksTests {
    static func menu(_ rows: [(String, String?)]) -> NSMenu {
        let menu = NSMenu()
        for (title, id) in rows {
            if title == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let id { item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + id) }
            menu.addItem(item)
        }
        return menu
    }

    static func item(_ menu: NSMenu, _ title: String) -> NSMenuItem { menu.items.first { $0.title == title }! }

    @Test func aLinkOnAPictureWearsEachMarkOnce() {
        let menu = Self.menu([
            ("Open Link", "OpenLink"), ("Open Link in New Window", "OpenLinkInNewWindow"),
            ("Download Linked File", "DownloadLinkedFile"), ("Copy Link", "CopyLink"), ("-", nil),
            ("Open Image in New Window", "OpenImageInNewWindow"), ("Download Image", "DownloadImage"),
            ("Copy Image", "CopyImage"), ("Copy Subject", "CopySubject"), ("Look Up", "RevealImage"), ("-", nil),
            ("Share…", "ShareMenu"),
        ])
        PageView.dress(menu)
        #expect(Self.item(menu, "Open Link").image === MenuMark.image("yab.arrowout"))
        #expect(Self.item(menu, "Open Link in New Tab").image === MenuMark.image("yab.tab.plus"))
        #expect(Self.item(menu, "Download Linked File").image === MenuMark.image("yab.download"))
        #expect(Self.item(menu, "Copy Link").image === MenuMark.image("link"))
        // The picture's rows wear their own marks, not the link's again.
        #expect(Self.item(menu, "Open Image in New Tab").image === MenuMark.image("plus.rectangle.on.rectangle"))
        #expect(Self.item(menu, "Download Image").image === MenuMark.image("arrow.down.circle"))
        #expect(Self.item(menu, "Copy Image").image === MenuMark.image("yab.copyframe.image"))
        // Lifted off its background as a sticker; looked up as Visual Intelligence does.
        #expect(Self.item(menu, "Copy Subject").image === MenuMark.image("sticker"))
        #expect(Self.item(menu, "Look Up").image === MenuMark.image("visual.intelligence"))
        #expect(Self.item(menu, "Share…").image === MenuMark.image("yab.share"))
    }

    @Test func aLinksNewTabRowComesFirst() {
        let menu = Self.menu([
            ("Open Link", "OpenLink"), ("Open Link in New Window", "OpenLinkInNewWindow"), ("Copy Link", "CopyLink"),
        ])
        PageView.dress(menu)
        #expect(menu.items.map(\.title) == ["Open Link in New Tab", "Open Link", "Copy Link"])
        #expect(Self.item(menu, "Open Link in New Tab").image === MenuMark.image("yab.tab.plus"))
        #expect(Self.item(menu, "Open Link").image === MenuMark.image("yab.arrowout"))
    }

    @Test func copyTextWearsTheCopySheet() {
        let menu = Self.menu([("Copy Image", "CopyImage")])
        let text = NSMenuItem(title: "Copy Text", action: nil, keyEquivalent: "")
        text.identifier = NSUserInterfaceItemIdentifier("YabCopyText")
        menu.addItem(text)
        let ask = NSMenuItem(title: "Ask About Image", action: nil, keyEquivalent: "")
        ask.identifier = NSUserInterfaceItemIdentifier("YabAskAboutImage")
        menu.addItem(ask)
        PageView.dress(menu)
        #expect(text.image === MenuMark.image("yab.copyframe.text"))
        #expect(ask.image === MenuMark.image("yab.chat.spark"))
    }

    @Test func aPictureAloneOpensInANewTabWithItsMark() {
        let menu = Self.menu([("Open Image in New Window", "OpenImageInNewWindow"), ("Download Image", "DownloadImage")])
        PageView.dress(menu)
        #expect(Self.item(menu, "Open Image in New Tab").image === MenuMark.image("plus.rectangle.on.rectangle"))
        #expect(Self.item(menu, "Download Image").image === MenuMark.image("arrow.down.circle"))
    }

    @Test func aRowItDoesNotKnowKeepsWebKitsSymbolAndServicesTheColumn() {
        let menu = Self.menu([("Reload", "Reload"), ("Enter Full Screen", "ToggleFullScreen"), ("Services", nil)])
        let symbol = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        Self.item(menu, "Enter Full Screen").image = symbol
        PageView.dress(menu)
        #expect(Self.item(menu, "Reload").image === MenuMark.image("yab.reload"))
        #expect(Self.item(menu, "Enter Full Screen").image === symbol)
        #expect(Self.item(menu, "Services").image === MenuMark.image(nil))
    }

    @Test func aMenuWithNoPictureGetsNoColumn() {
        let menu = Self.menu([("Something New", "SomethingNew"), ("Services", nil)])
        PageView.dress(menu)
        #expect(menu.items.allSatisfy { $0.image == nil })
    }

    @Test func commandsWearTheirPanelsMarksAndBothSelectionTranslationsStayMarked() {
        let menu = Self.menu([("Translate “Hola”", "Translate"), ("Search with Google", "SearchWeb"), ("-", nil)])
        let run = NSSelectorFromString("runSelectionCommand:")
        for (title, id) in [("Improve Writing", "improve"), ("Translate", "translate")] as [(String, String)] {
            let item = NSMenuItem(title: title, action: run, keyEquivalent: "")
            item.representedObject = id
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "More Commands…", action: run, keyEquivalent: ""))
        PageView.dress(menu)
        #expect(Self.item(menu, "Translate “Hola”").image === MenuMark.image("yab.translate"))
        #expect(Self.item(menu, "Search with Google").image === MenuMark.image("magnifyingglass"))
        #expect(Self.item(menu, "Improve Writing").image === MenuMark.image(SelectionLayer.symbol("improve")))
        #expect(Self.item(menu, "Translate").image === MenuMark.image("yab.translate"))
        #expect(Self.item(menu, "More Commands…").image === MenuMark.image(nil))
    }
}

// The tab's menu, SwiftUI's: a line made with a mark hands AppKit that very
// picture, one with none the blank, and each asks to be shown, which the
// 27 SDK would otherwise decide against (MenuMark).
@MainActor
struct TabMenuMarksTests {
    struct Row: SwiftUI.View {
        var body: some SwiftUI.View {
            SwiftUI.Text("A tab").frame(width: 200, height: 40).contextMenu {
                SwiftUI.Button("Pin", mark: "pin") {}
                SwiftUI.Menu("Move to Space", mark: "square.2.layers.3d") { SwiftUI.Button("Home") {} }
                SwiftUI.Button("Close Other Tabs", mark: nil) {}
            }
        }
    }

    @Test func linesWearTheirMarksAndAskToBeShown() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        let host = NSHostingView(rootView: Row())
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let at = host.convert(NSPoint(x: 100, y: 20), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        var view: NSView? = host.hitTest(window.contentView!.convert(at, from: nil))
        var menu: NSMenu?
        while let here = view, menu == nil { menu = here.menu(for: event); view = here.superview }
        let lines = try #require(menu).items
        #expect(lines.map(\.title) == ["Pin", "Move to Space", "Close Other Tabs"])
        #expect(lines[0].image === MenuMark.image("pin"))
        #expect(lines[1].image === MenuMark.image("square.2.layers.3d"))
        #expect(lines[2].image === MenuMark.image(nil))
        #if compiler(>=6.4) // Xcode 26's SDK has no preferredImageVisibility
        if #available(macOS 27, *) {
            #expect(lines.allSatisfy { $0.preferredImageVisibility == .visible })
        }
        #endif
    }
}
