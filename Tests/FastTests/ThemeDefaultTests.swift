import AppKit
import Testing
@testable import Fast

/// Register 1284: Yab stayed light on a dark Mac. Theme was Light unless
/// someone picked another, so a Mac in Dark, or in Auto turning dark at
/// night, kept a light browser. Unpicked, the Theme is System and the app
/// is told no appearance of its own; a Light or Dark picked stays.
@MainActor
@Suite(.serialized)
struct ThemeDefaultTests {
    private func keeping(_ body: () throws -> Void) rethrows {
        let old = Store.settings.object(forKey: "look"), app = NSApplication.shared.appearance
        defer {
            Store.settings.set(old, forKey: "look")
            NSApplication.shared.appearance = app
        }
        try body()
    }

    @Test func unpickedThemeFollowsTheMac() {
        keeping {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            Store.settings.removeObject(forKey: "look")
            let prefs = Preferences()
            #expect(prefs.look == .system)
            // Nothing forced on the app: it is the Mac's, and turns with it.
            #expect(NSApplication.shared.appearance == nil)
            // Read only: an unpicked Theme stays unpicked.
            #expect(Store.settings.object(forKey: "look") == nil)
        }
    }

    @Test func aPickedThemeIsKept() {
        keeping {
            for look in Look.allCases {
                Store.settings.set(look.rawValue, forKey: "look")
                let prefs = Preferences()
                #expect(prefs.look == look)
                #expect(NSApplication.shared.appearance?.name == look.appearance?.name)
            }
        }
    }

    @Test func anUnknownStoredThemeFollowsTheMac() {
        keeping {
            Store.settings.set("sepia", forKey: "look")
            #expect(Preferences().look == .system)
        }
    }
}
