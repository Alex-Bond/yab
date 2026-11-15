import AppKit
import Testing
@testable import Fast

@Suite(.serialized, .enabled("needs a farm test screen") { await TestScreen.available })
@MainActor
struct WindowFrameAutosaveTests {
    private func window(on screen: NSScreen) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test(arguments: [false, true]) func repeatedSaveRestoreKeepsTheWholeFrame(fillingScreen: Bool) throws {
        let screen = try #require(TestScreen.screen)
        let source = window(on: screen)
        let name = "window-frame-test-\(UUID().uuidString)"
        defer {
            source.close()
            NSWindow.removeFrame(usingName: name)
        }
        let room = try #require(source.screen).visibleFrame
        #expect(source.screen === screen)
        let saved = fillingScreen ? room : NSRect(x: room.minX + 40, y: room.minY + 40,
                                                  width: min(1000, room.width - 80), height: min(700, room.height - 80))
        source.setFrame(saved, display: false)
        #expect(source.frame == saved)
        source.saveFrame(usingName: name)
        for _ in 0..<4 {
            let restored = window(on: screen)
            WindowFrameAutosave.keep(restored, name: name, restoring: true)
            #expect(restored.frame == saved)
            #expect(restored.frameRect(forContentRect: restored.contentRect(forFrameRect: restored.frame)) == saved)
            restored.saveFrame(usingName: name)
            restored.setFrameAutosaveName("")
            restored.close()
        }
    }

    @Test func aNewWindowKeepsItsPlacementInsteadOfRestoring() throws {
        let screen = try #require(TestScreen.screen)
        let source = window(on: screen), fresh = window(on: screen)
        let name = "window-frame-test-\(UUID().uuidString)"
        defer {
            fresh.setFrameAutosaveName("")
            fresh.close()
            source.close()
            NSWindow.removeFrame(usingName: name)
        }
        let room = try #require(fresh.screen).visibleFrame
        #expect(source.screen === screen)
        #expect(fresh.screen === screen)
        source.setFrame(room, display: false)
        source.saveFrame(usingName: name)
        let placed = NSRect(x: room.minX + 20, y: room.minY + 20,
                            width: min(300, room.width - 40), height: min(200, room.height - 40))
        fresh.setFrame(placed, display: false)
        #expect(fresh.frame == placed)
        WindowFrameAutosave.keep(fresh, name: name, restoring: false)
        #expect(fresh.frame == placed)
        #expect(fresh.frameAutosaveName == name)

        // A second dress must not replay an older saved rectangle after
        // the user has moved or resized the window.
        let resized = NSRect(x: room.minX + 40, y: room.minY + 40,
                             width: min(500, room.width - 80), height: min(300, room.height - 80))
        fresh.setFrame(resized, display: false)
        #expect(fresh.frame == resized)
        source.saveFrame(usingName: name)
        WindowFrameAutosave.keep(fresh, name: name, restoring: true)
        #expect(fresh.frame == resized)
    }
}

/// Not gated on a test screen: any screen shows that a huge saved frame is clamped.
@Suite(.serialized)
@MainActor
struct WindowFrameHealingTests {
    @Test func aGiantSavedFrameComesBackOnTheScreenAndIsHealed() throws {
        let screen = try #require(NSScreen.screens.first)
        _ = NSApplication.shared
        let restored = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false, screen: screen)
        restored.isReleasedWhenClosed = false
        let name = "window-frame-test-\(UUID().uuidString)"
        defer {
            restored.setFrameAutosaveName("")
            restored.close()
            NSWindow.removeFrame(usingName: name)
        }
        let room = screen.visibleFrame
        // The frame the 0.43.1 layout loop saved: 22,065 pt wide, mostly off screen.
        let giant = NSRect(x: room.maxX - 22065, y: room.minY + 40, width: 22065, height: min(800, room.height - 80))
        UserDefaults.standard.set("\(giant.minX) \(giant.minY) \(giant.width) \(giant.height) \(screen.frame.minX) \(screen.frame.minY) \(screen.frame.width) \(screen.frame.height)",
                                  forKey: "NSWindow Frame \(name)")
        WindowFrameAutosave.keep(restored, name: name, restoring: true)
        #expect(restored.frame.width <= room.width)
        #expect(room.insetBy(dx: -1, dy: -1).contains(restored.frame))
        let healed = try #require(WindowFrameAutosave.savedFrame(name))
        #expect(healed.width <= room.width)
    }
}
