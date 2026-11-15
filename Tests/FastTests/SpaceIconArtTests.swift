import AppKit
import Testing
import SyncKit
@testable import Fast

@MainActor
struct SpaceIconArtTests {
    @Test func everySavedSpaceSymbolHasADrawingAtSidebarSize() throws {
        let symbols = SpaceSymbols.all.map(\.symbol)
        #expect(symbols.count == 56)
        #expect(SpaceDraft.symbolsOffered == symbols)
        #expect(Set(SpaceIconArt.catalog.keys) == Set(symbols))
        for symbol in symbols {
            let image = try #require(SpaceIconArt.art(symbol), "\(symbol)")
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 24, height: 24))
            let small = NSImage(size: NSSize(width: 14, height: 14))
            small.lockFocus()
            image.draw(in: NSRect(x: 0, y: 0, width: 14, height: 14))
            small.unlockFocus()
            let data = try #require(small.tiffRepresentation)
            let pixels = try #require(NSBitmapImageRep(data: data))
            let visible = (0..<pixels.pixelsHigh).contains { y in
                (0..<pixels.pixelsWide).contains { x in
                    (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
                }
            }
            #expect(visible, "\(symbol) must draw ink at 14 points")
        }
    }

    @Test func selectedCentralVariantsAndUnselectedArcGlyphsStayDistinct() {
        #expect(SpaceIconArt.catalog.values.filter { $0.source.hasPrefix("central:") }.count == 31)
        #expect(SpaceIconArt.catalog.values.filter { $0.source.hasPrefix("ionicons:") }.count == 25)
        // These were deliberate choices, not the first proposed variants.
        #expect(SpaceIconArt.catalog["heart.fill"]?.source == "central:IconHeart2")
        #expect(SpaceIconArt.catalog["asterisk"]?.source == "central:IconFormFlower")
        #expect(SpaceIconArt.catalog["theatermasks.fill"]?.source == "central:IconGhost")
        #expect(SpaceIconArt.catalog["flag.fill"]?.source == "ionicons:flag")
        #expect(SpaceIconArt.catalog["music.note"]?.source == "ionicons:musical-notes")
        #expect(SpaceIconArt.catalog["cup.and.saucer.fill"]?.source == "ionicons:pizza")
    }

    @Test func menuSizingDoesNotResizeTheCachedSidebarDrawing() throws {
        let cached = try #require(SpaceIconArt.art("star.fill"))
        let menu = Spaces.picture(emoji: "star.fill", side: 20)
        #expect(menu.isTemplate)
        #expect(menu.size == NSSize(width: 14, height: 14))
        #expect(cached.size == NSSize(width: 24, height: 24))
        #expect(SpaceIconArt.art("not-a-space-symbol") == nil)
    }

    @Test func searchFindsTheDrawnIconAndKeepsTheOldSymbolKey() {
        #expect(SpaceDraft.symbols(matching: "saturn") == ["globe.americas.fill"])
        #expect(SpaceDraft.symbols(matching: "pizza") == ["cup.and.saucer.fill"])
        #expect(SpaceDraft.symbols(matching: "ghost") == ["theatermasks.fill"])
        #expect(SpaceDraft.symbols(matching: "music") == ["music.note"])
    }

    @Test func trayCatalogMatchesFolderArtWithoutRewritingLegacyIcons() throws {
        let draft = SpaceDraft(prefs: Preferences(), tab: nil)
        for legacy in ["star.fill", "cup.and.saucer.fill", "paperplane.fill", "🧪"] {
            draft.pick(icon: legacy)
            let picker = TrayStep(draft: draft, step: .emoji, width: 304, wheel: 220).iconPicker
            #expect(picker.mark == legacy)
            #expect(picker.space != nil)
            #expect(draft.icon == legacy)
            #expect(Spaces.picture(emoji: legacy, side: 20).size.width > 0)
        }
        let symbols = IconPicker.spaceIcons(matching: "", forFolder: false)
        let folders = IconPicker.spaceIcons(matching: "", forFolder: true)
        #expect(symbols == SpaceDraft.symbolsOffered)
        for (symbol, folder) in zip(symbols, folders) {
            #expect(CustomMarks.image(folder) === SpaceIconArt.art(symbol))
        }
        #expect(SpaceIconArt.art("paperplane.fill") == nil)
        #expect(NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil) != nil)
    }

    @Test func keptTabCatalogDrawsTheApprovedArtAndKeepsExistingMarks() throws {
        for legacy in ["icon:rocket", "space:star.fill", "🧪"] {
            var chosen = legacy
            let picker = IconPicker(mark: chosen, pick: { chosen = $0 ?? "" }, close: {})
            #expect(picker.mark == legacy)
            #expect(chosen == legacy)
            #expect(CustomMarks.image(legacy) != nil)
            for mark in picker.icons(matching: "") {
                let art = try #require(CustomMarks.image(mark))
                #expect(art === SpaceIconArt.art(String(mark.dropFirst(6))))
            }
            picker.pick("space:cup.and.saucer.fill")
            #expect(chosen == "space:cup.and.saucer.fill")
        }
    }

}
