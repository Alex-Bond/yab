import AppKit
import Testing
@testable import Fast

// Change Icon's picker (IconPicker.swift): every emoji under Arc's eight
// parts, every icon drawn, and how a picked icon is kept and shown.
@MainActor
struct IconPickerTests {
    @Test func emojiUnderTheEightParts() throws {
        let parts = EmojiParts.all
        #expect(parts.map(\.title) == ["Smileys & People", "Animals & Nature", "Food & Drink", "Activity",
                                       "Travel & Places", "Objects", "Symbols", "Flags"])
        #expect(parts.allSatisfy { !$0.emoji.isEmpty && IconMarks.art($0.mark) != nil })
        #expect(parts.first?.emoji.first?.glyph == "😀")
        let glyphs = parts.flatMap(\.emoji).map(\.glyph)
        #expect(glyphs.count > 1800)
        #expect(Set(glyphs).count == glyphs.count)
        #expect(parts.last?.emoji.contains { $0.glyph == "🇯🇵" && $0.name.lowercased().contains("japan") } == true)
        // No skin tones: one hand, not six.
        #expect(!glyphs.contains("👋🏽"))
    }

    @Test func everyIconIsDrawnAndKept() throws {
        #expect(IconMarks.all.count == 90)
        #expect(Set(IconMarks.all.map(\.name)).count == IconMarks.all.count)
        for icon in IconMarks.all {
            let art = try #require(IconMarks.art(icon.name), "\(icon.name)")
            #expect(art.isTemplate)
        }
        #expect(IconMarks.art("restore") != nil)
        let kept = try #require(CustomMarks.image("icon:rocket"))
        #expect(kept.isTemplate)
        #expect(CustomMarks.image("icon:nothing-like-it") == nil)
    }

    @Test func aMarkOfANewerYabIsTheSitesIcon() {
        #expect(CustomMarks.image("sticker:42") == nil)
        #expect(CustomMarks.image("🚀") != nil)
    }

    @Test func foldersOfferAndDrawTheSameIconsAsSpaces() throws {
        let spaces = IconPicker.spaceIcons(matching: "", forFolder: false)
        let folders = IconPicker.spaceIcons(matching: "", forFolder: true)
        #expect(spaces == SpaceDraft.symbolsOffered)
        #expect(folders == spaces.map { "space:" + $0 })
        for (symbol, mark) in zip(spaces, folders) {
            let image = try #require(CustomMarks.image(mark), "\(mark)")
            #expect(image === SpaceIconArt.art(symbol))
            #expect(image.isTemplate)
        }
        #expect(CustomMarks.image("space:unknown-symbol") == nil)
    }

    @Test func folderIconSearchUsesTheSpacesDrawnNames() {
        #expect(IconPicker.spaceIcons(matching: "pizza", forFolder: true) == ["space:cup.and.saucer.fill"])
        #expect(IconPicker.spaceIcons(matching: "ghost", forFolder: true) == ["space:theatermasks.fill"])
        #expect(IconPicker.spaceIcons(matching: "планета", forFolder: true) == ["space:globe.americas.fill"])
        #expect(IconPicker.spaceIcons(matching: "no-such-icon", forFolder: true).isEmpty)
    }

    @Test func theTrayUsesTheSharedSpacePickerAndKeepsItsStoredMark() {
        let draft = SpaceDraft(prefs: Preferences(), tab: nil)
        draft.pick(icon: "star.fill")
        let step = TrayStep(draft: draft, step: .emoji, width: 304, wheel: 220)
        let picker = step.iconPicker
        #expect(picker.mark == "star.fill")
        #expect(picker.space == draft.emoji)
        #expect(picker.folder == nil)
        #expect(!picker.emojiOnly)
        #expect(picker.icons(matching: "") == SpaceDraft.symbolsOffered)
        #expect(picker.icons(matching: "pizza") == ["cup.and.saucer.fill"])
        #expect(draft.icon == "star.fill")
        picker.pick(nil)
        #expect(draft.icon == "star.fill")
        picker.pick("cup.and.saucer.fill")
        #expect(draft.icon == "cup.and.saucer.fill")
        picker.pick("🚀")
        #expect(draft.icon == "🚀")
        picker.close()
        #expect(draft.icon == "🚀")
    }

    @Test func keptTabsFoldersAndSpacesSearchOneCatalog() {
        let tab = IconPicker(mark: "icon:rocket", pick: { _ in }, close: {})
        let folder = IconPicker(mark: nil, folder: Nest(name: "Work"), pick: { _ in }, close: {})
        let space = IconPicker(mark: "star.fill", space: [], pick: { _ in }, close: {})
        for query in ["", "pizza", "ghost", "saturn", "планета", "no-such-icon"] {
            #expect(tab.icons(matching: query) == folder.icons(matching: query))
            #expect(tab.icons(matching: query) == space.icons(matching: query).map { "space:" + $0 })
        }
        #expect(tab.icons(matching: "").count == 56)
        #expect(tab.icons(matching: "pizza") == ["space:cup.and.saucer.fill"])
        #expect(tab.mark == "icon:rocket")
    }

}
