import AppKit
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct FloatPlacementTests {
    @Test func placementCanBeFoundInTabsSettings() throws {
        let row = try #require(SettingsItem.all.first { $0.id == "float-snap" })
        #expect(row.page == .tabs)
        for query in ["pip", "snap", "edges", "free", "прилипание"] {
            #expect(row.score(query) != nil)
        }
        let setting = try #require(NativeSetting.all.first { $0.id == "float-snap" })
        #expect(setting.schema["type"] as? String == "boolean")
    }

    private func window(_ page: NSView) async throws -> NSWindow {
        for _ in 0..<100 {
            if Floater.owns(page.window), let window = page.window { return window }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(page.window)
    }

    private func menu(_ panel: NSWindow) throws -> NSMenu {
        let hand = try #require(panel.contentView?.subviews.compactMap { $0 as? FloatHand }.first)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        return try #require(hand.menu(for: event))
    }

    @Test func menuChoicePersistsAndReopensAtTheFreePosition() async throws {
        _ = NSApplication.shared
        let saved = Store.settings.object(forKey: "float.snapToEdges")
        let savedFrame = Store.settings.object(forKey: "float.frame")
        let first = Floater(), reopened = Floater()
        defer {
            first.drop()
            reopened.drop()
            if let saved { Store.settings.set(saved, forKey: "float.snapToEdges") }
            else { Store.settings.removeObject(forKey: "float.snapToEdges") }
            if let savedFrame { Store.settings.set(savedFrame, forKey: "float.frame") }
            else { Store.settings.removeObject(forKey: "float.frame") }
        }
        Store.settings.removeObject(forKey: "float.snapToEdges")
        Store.settings.removeObject(forKey: "float.frame")
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        first.lift(page, shape: CGSize(width: 440, height: 247))
        let panel = try await window(page)
        let choices = try menu(panel)
        #expect(choices.items.filter { !$0.isSeparatorItem }.map(\.title)
                == ["Keep on Top", "Snap to Edges", "Back to Tab", "Close"])
        let snap = try #require(choices.item(withTitle: "Snap to Edges"))
        #expect(snap.state == .on)
        #expect(first.snapsToEdges)
        let action = try #require(snap.action)
        #expect(NSApp.sendAction(action, to: snap.target, from: snap))
        #expect(!first.snapsToEdges)
        #expect(Store.settings.object(forKey: "float.snapToEdges") as? Bool == false)
        let setting = try #require(NativeSetting.all.first { $0.id == "float-snap" })
        #expect(setting.saved == .bool(false))
        #expect(try menu(panel).item(withTitle: "Snap to Edges")?.state == .off)
        #expect(first.keepsOnTop)

        let area = try #require(panel.screen).visibleFrame
        let spot = NSPoint(x: (area.midX - panel.frame.width / 2).rounded(),
                           y: (area.midY - panel.frame.height / 2).rounded())
        panel.setFrameOrigin(spot)
        first.letGo()
        try await Task.sleep(for: .milliseconds(100))
        #expect(panel.frame.origin == spot)
        first.drop()

        let nextPage = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        reopened.lift(nextPage, shape: CGSize(width: 440, height: 247))
        let nextPanel = try await window(nextPage)
        #expect(nextPanel.frame.origin == spot)
        #expect(!reopened.snapsToEdges)
        let nextSnap = try #require(try menu(nextPanel).item(withTitle: "Snap to Edges"))
        #expect(nextSnap.state == .off)
        let nextAction = try #require(nextSnap.action)
        #expect(NSApp.sendAction(nextAction, to: nextSnap.target, from: nextSnap))
        let corner = FloatPark.nearest(nextPanel.frame, in: area)
        for _ in 0..<100 {
            if nextPanel.frame.origin == corner { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reopened.snapsToEdges)
        #expect(nextPanel.frame.origin == corner)
        #expect(try menu(nextPanel).item(withTitle: "Snap to Edges")?.state == .on)
    }
}
