import AppKit
import Foundation
import Testing
@testable import Fast

/// Feedback #702 (register 1160): with two windows, each space's own color
/// came back as one color after quitting and opening Yab again. The
/// window's color keys are one set every window writes; at launch the
/// first window kept them into its own space, which then wore the look of
/// whichever window wore one last.
@MainActor
@Suite(.serialized)
struct SpaceLookRelaunchTests {
    static let work = UUID(uuidString: "3C6F0D2A-8E41-4B9C-A1F7-5D0E2B9C7A11")!
    static let red = "D9463B"
    static let blue = "2F6FD8"

    private static let keys = ["spaces", "space.current", "backdrop", "backdrop.swatch", "backdrop.color",
                               "backdrop.transparency", "backdrop.grain.amount", "backdrop.colors"]

    private func paint(_ hex: String, grain: Double) -> SpacePaint {
        SpacePaint(swatch: .custom, color: NSColor(hex: hex)!, grain: grain)
    }

    /// The settings as a quit left them: the second window, on Work, wore
    /// its blue last.
    private func quitWithTwoWindows(second window: UUID) {
        let personal = Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false, paint: paint(Self.red, grain: 0.1))
        let work = Space(id: Self.work, name: "Work", icon: "💼", ownSignIns: false, paint: paint(Self.blue, grain: 0.4))
        Spaces.write([personal, work])
        let settings = Store.settings
        settings.set(true, forKey: "spaces")
        settings.set(Space.firstID.uuidString, forKey: "space.current")
        settings.set(Self.work.uuidString, forKey: "window.\(window.uuidString).space")
        settings.set("color", forKey: "backdrop")
        settings.set(Swatch.custom.rawValue, forKey: "backdrop.swatch")
        settings.set(Self.blue, forKey: "backdrop.color")
        settings.set(0.4, forKey: "backdrop.grain.amount")
    }

    @Test func eachWindowComesBackInItsOwnSpacesLook() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previousSpaces = Spaces.read()
        let settings = Store.settings
        let previous = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, settings.object(forKey: $0)) })
        let second = UUID()
        defer {
            Spaces.write(previousSpaces)
            for (key, value) in previous { settings.set(value, forKey: key) }
            settings.removeObject(forKey: "window.\(second.uuidString).space")
        }
        quitWithTwoWindows(second: second)

        let first = Browser()
        #expect(first.spaceID == Space.firstID)
        // Personal keeps its red, and the window wears it, not Work's blue.
        let kept = try #require(Spaces.read().first { $0.id == Space.firstID }?.paint)
        #expect(kept.color == Self.red)
        #expect(kept.grain == 0.1)
        #expect(first.prefs.backdropColor.hex == Self.red)
        #expect(first.prefs.grain == 0.1)

        // The first window just wrote red; the second, on Work, wears blue.
        let other = Browser(windowID: second)
        #expect(other.spaceID == Self.work)
        #expect(other.prefs.backdropColor.hex == Self.blue)
        #expect(other.prefs.grain == 0.4)
        #expect(Spaces.read().first { $0.id == Self.work }?.paint?.color == Self.blue)

        // Quitting keeps each window's look with its own space.
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        let after = Spaces.read()
        #expect(after.first { $0.id == Space.firstID }?.paint?.color == Self.red)
        #expect(after.first { $0.id == Self.work }?.paint?.color == Self.blue)
    }

    @Test func aSpaceWithNoLookYetKeepsTheWindows() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previousSpaces = Spaces.read()
        let settings = Store.settings
        let previous = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, settings.object(forKey: $0)) })
        defer {
            Spaces.write(previousSpaces)
            for (key, value) in previous { settings.set(value, forKey: key) }
        }
        let personal = Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false)
        let work = Space(id: Self.work, name: "Work", icon: "💼", ownSignIns: false, paint: paint(Self.blue, grain: 0.4))
        Spaces.write([personal, work])
        settings.set(true, forKey: "spaces")
        settings.set(Space.firstID.uuidString, forKey: "space.current")
        settings.set(Swatch.custom.rawValue, forKey: "backdrop.swatch")
        settings.set(Self.red, forKey: "backdrop.color")

        _ = Browser()
        #expect(Spaces.read().first { $0.id == Space.firstID }?.paint?.color == Self.red)
    }
}
