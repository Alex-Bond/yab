import Foundation
import Testing
@testable import Fast

// Reading mode's themes (ReaderAppearance.swift): six as drawn, edits kept
// per theme and only where they differ, Reset, the size steps, and the
// five colors from before the themes carried over.
struct ReaderStyleTests {
    private func store() -> UserDefaults {
        let name = "reader-style-tests-" + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func sixThemesInTheCardsOrder() {
        #expect(ReaderThemeSpec.ordered.map(\.name) == ["Original", "Quiet", "Paper", "Bold", "Calm", "Focus"])
        #expect(ReaderThemeID.allCases.allSatisfy { ReaderThemeSpec.all[$0] != nil })
        // Every theme's ink reads on its ground, light and dark.
        for spec in ReaderThemeSpec.ordered {
            #expect(ReaderColors.contrast(spec.light.background, spec.light.text) >= 4.5, "\(spec.name) light")
            #expect(ReaderColors.contrast(spec.dark.background, spec.dark.text) >= 4.5, "\(spec.name) dark")
            #expect(!spec.light.dark && spec.dark.dark, "\(spec.name)")
        }
        #expect(ReaderThemeID.original.spec.look.font == .site)
        #expect(ReaderThemeID.bold.spec.weight == 700)
    }

    @Test func editsAreKeptPerThemeAndOnlyWhatDiffers() {
        var prefs = ReaderPrefs()
        prefs.theme = .calm
        #expect(!prefs.edited(.calm))
        prefs.change { $0.line = 1.95; $0.font = .georgia }
        #expect(prefs.edited(.calm))
        #expect(!prefs.edited(.paper))
        #expect(prefs.look.line == 1.95)
        #expect(prefs.look.font == .georgia)
        #expect(prefs.edits[.calm]?.size == nil)
        // Another theme has its own.
        prefs.theme = .paper
        #expect(prefs.look.font == .charter)
        prefs.change { $0.bold = true }
        prefs.theme = .calm
        #expect(prefs.look.font == .georgia)
        #expect(!prefs.look.bold)
        // Set back to the theme's own, it is no edit.
        prefs.change { $0.font = .iowan }
        prefs.restore(\.line)
        #expect(!prefs.edited(.calm))
        #expect(prefs.edited(.paper))
        prefs.theme = .paper
        prefs.reset()
        #expect(prefs.edits.isEmpty)
    }

    @Test func sizeStepsStopAtTheEnds() {
        var prefs = ReaderPrefs()
        prefs.theme = .calm
        #expect(prefs.look.points == 20)
        let moved = prefs.step(1)
        #expect(moved)
        #expect(prefs.look.points == 22)
        for _ in 0..<20 { prefs.step(1) }
        #expect(prefs.look.points == 28)
        let stuck = prefs.step(1)
        #expect(!stuck)
        for _ in 0..<20 { prefs.step(-1) }
        #expect(prefs.look.points == 14)
        let floor = prefs.step(-1)
        #expect(!floor)
    }

    @Test func payloadFollowsTheThemeAndTheLight() {
        var prefs = ReaderPrefs()
        prefs.theme = .focus
        prefs.mode = .dark
        let sent = prefs.payload
        #expect(sent.mode == "dark")
        #expect(sent.night.bg == "#17160f")
        #expect(sent.day.bg == "#fffdf6")
        #expect(sent.font.contains("Athelas"))
        #expect(sent.weight == 500)
        #expect(sent.size == 20)
        #expect(sent.width == 41.8)
        prefs.wide = true
        prefs.change { $0.bold = true; $0.letter = 3; $0.word = 10 }
        #expect(prefs.payload.weight == 700)
        #expect(prefs.payload.letter == 0.03)
        #expect(prefs.payload.word == 0.1)
        #expect(prefs.payload.width == 52.8)
        prefs.theme = .original
        #expect(prefs.payload.font == "")
        #expect(prefs.isDark(system: false))
        prefs.mode = .auto
        #expect(prefs.isDark(system: true) && !prefs.isDark(system: false))
    }

    @Test func keptAndReadBack() {
        let store = store()
        var prefs = ReaderPrefs.load(from: store)
        #expect(prefs == ReaderPrefs())
        prefs.theme = .quiet
        prefs.mode = .light
        prefs.wide = true
        prefs.change { $0.margins = 10; $0.justify = true }
        prefs.save(to: store)
        let back = ReaderPrefs.load(from: store)
        #expect(back == prefs)
        #expect(back.look.margins == 10)
        // Nonsense in the store is ignored, not trusted.
        store.set("{\"bogus\":{\"size\":3},\"calm\":{}}", forKey: ReaderPrefs.Key.edits)
        store.set("nope", forKey: ReaderPrefs.Key.mode)
        let odd = ReaderPrefs.load(from: store)
        #expect(odd.edits.isEmpty)
        #expect(odd.mode == .auto)
    }

    @Test func theFiveColorsFromBeforeCarryOver() {
        func moved(_ old: String?, _ background: String? = nil, _ text: String? = nil) -> ReaderPrefs {
            let store = store()
            if let old { store.set(old, forKey: ReaderPrefs.Key.old) }
            if let background { store.set(background, forKey: ReaderPrefs.Key.oldBackground) }
            if let text { store.set(text, forKey: ReaderPrefs.Key.oldText) }
            let prefs = ReaderPrefs.load(from: store)
            // Moved once: the new keys are written, and read back the same.
            #expect(store.string(forKey: ReaderPrefs.Key.theme) == prefs.theme.rawValue)
            #expect(ReaderPrefs.load(from: store) == prefs)
            return prefs
        }
        #expect(moved(nil).theme == .original && moved(nil).mode == .auto)
        #expect(moved("system").theme == .original && moved("system").mode == .auto)
        #expect(moved("light").mode == .light)
        #expect(moved("dark").mode == .dark && moved("dark").theme == .original)
        let sepia = moved("sepia")
        #expect(sepia.theme == .calm && sepia.mode == .light && sepia.edits.isEmpty)
        let custom = moved("custom", "2b3445", "e0e6f0")
        #expect(custom.theme == .original)
        #expect(custom.edited(.original))
        #expect(custom.look.colors == ReaderColors("#2b3445", "#e0e6f0"))
        #expect(custom.payload.day.bg == "#2b3445" && custom.payload.night.bg == "#2b3445")
        #expect(custom.payload.day.dark)
        // Reset is the way back to Original's own colors.
        var reset = custom
        reset.reset()
        #expect(reset.payload.day.bg == "#ffffff")
    }
}
