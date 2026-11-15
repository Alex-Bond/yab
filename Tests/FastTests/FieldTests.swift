import Testing
@testable import Fast

// What the field works out by itself: a sum from the words, what a copy is,
// which of its own places the words name, and emoji by their names.
struct FieldTests {
    @Test func sumsAreWorkedOut() {
        #expect(Sum.answer("2400*12")?.shown == "28,800")
        #expect(Sum.answer("(2+3)*4")?.shown == "20")
        #expect(Sum.answer("2^10")?.shown == "1,024")
        #expect(Sum.answer("10/4")?.shown == "2.5")
        #expect(Sum.answer("50%*80")?.shown == "40")
        #expect(Sum.answer("3x4")?.shown == "12")
        #expect(Sum.answer("1,200 + 34")?.shown == "1,234")
        #expect(Sum.answer("-5+2")?.shown == "-3")
        #expect(Sum.answer("1/3")?.shown == "0.3333333333")
    }

    @Test func notEverythingWithDigitsIsASum() {
        for words in ["2024", "10.0.0.1", "1/0", "a+b", "localhost:3000", "2+", "(2+3", "12", "+", "3 - ", "v2-alpha"] {
            #expect(Sum.answer(words) == nil, "\(words)")
        }
    }

    @Test func aCopyIsReadForWhatItIs() {
        #expect(Clips.isLink("https://linear.app/fast/issue/FAST-212"))
        #expect(Clips.isLink("http://localhost:3000/x"))
        #expect(!Clips.isLink("linear.app"))
        #expect(!Clips.isLink("see https://a.com"))
        #expect(!Clips.isLink("ftp://a.com"))
        #expect(Clips.hex("#2F6BFF") != nil)
        #expect(Clips.hex("2f6bff") != nil)
        #expect(Clips.hex("#abc") != nil)
        #expect(Clips.hex("abc") == nil)
        #expect(Clips.hex("#12345") == nil)
        #expect(Clips.hex("decade") == nil)
    }

    @Test func placesAreNamedByTheirStart() {
        #expect(FieldPlace.named("clip") == .clipboard)
        #expect(FieldPlace.named("copied") == .clipboard)
        #expect(FieldPlace.named("emo") == .emoji)
        #expect(FieldPlace.named("cl") == nil)
        #expect(FieldPlace.named("clips and more") == nil)
    }

    @MainActor @Test func emojiAreFoundByName() {
        #expect(Emoji.find("fire").first?.glyph == "🔥")
        #expect(Emoji.find("rocket").first?.glyph == "🚀")
        #expect(Emoji.find("red heart").contains { $0.glyph == "❤️" } || Emoji.find("heart").contains { $0.glyph == "❤️" })
        #expect(Emoji.find("qqqzz").isEmpty)
        #expect(Emoji.all.count > 1000)
        #expect(Emoji.find("coder").contains { $0.glyph == "🧑‍💻" })
        #expect(Emoji.all.first { $0.glyph == "❤️" }?.name == "red heart")
    }

    @MainActor @Test func spaceIconSearchFindsEveryEmoji() {
        #expect(Emoji.search("boat").contains { $0.glyph == "⛵" })
        #expect(Emoji.search("heart").contains { $0.glyph == "❤️" })
        #expect(Emoji.search("").isEmpty)
        #expect(Emoji.search("qqqzz").isEmpty)
        // The offered ones a little ahead of their like.
        let hearts = Emoji.search("heart").prefix(30).map(\.glyph)
        let blue = Emoji.search("heart", first: ["💙"]).prefix(30).map(\.glyph)
        #expect(blue.firstIndex(of: "💙") ?? 99 <= hearts.firstIndex(of: "💙") ?? 99)
        // An emoji typed into the search is picked; words and digits are not.
        #expect(Emoji.typed(in: "⛵") == "⛵")
        #expect(Emoji.typed(in: "my ❤️") == "❤️")
        #expect(Emoji.typed(in: "boat 1 #") == nil)
        // The Icon tab finds its symbols by name and by their emoji's words.
        #expect(SpaceDraft.symbols(matching: "music") == ["music.note"])
        #expect(SpaceDraft.symbols(matching: "fire").contains("flame.fill"))
        #expect(SpaceDraft.symbols(matching: "").count == SpaceDraft.symbolsOffered.count)
    }

    @Test func emojiByGlyphIsTheFirstOfItsSpellings() {
        let linear = { (glyph: String) in
            Emoji.all.first { $0.glyph == glyph || $0.glyph == glyph + "\u{FE0F}" || $0.glyph + "\u{FE0F}" == glyph }
        }
        for one in Emoji.all {
            let bare = Emoji.bare(one.glyph)
            for glyph in [one.glyph, bare, bare + "\u{FE0F}"] {
                #expect(Emoji.one(for: glyph) == linear(glyph))
            }
        }
        #expect(Emoji.one(for: "qqqzz") == nil)
    }

    @MainActor @Test func emojiGridKeepsItsOrderAndUpdatesItsPinnedAndRecentOnes() {
        let pinned = Store.settings.stringArray(forKey: "emoji.pinned")
        let recent = Store.settings.stringArray(forKey: "emoji.recent")
        defer {
            Store.settings.set(pinned, forKey: "emoji.pinned")
            Store.settings.set(recent, forKey: "emoji.recent")
        }
        Store.settings.set([String](), forKey: "emoji.pinned")
        Store.settings.set([String](), forKey: "emoji.recent")
        let grid = Emoji.grid("")
        #expect(grid.flat == grid.sections.flatMap(\.list))
        for (title, _) in Emoji.blocks {
            #expect(grid.sections.first { $0.title == title }?.list == Emoji.all.filter { $0.section == title })
        }
        #expect(Emoji.grid("  ").flat == grid.flat)
        Emoji.pin("🚀")
        #expect(Emoji.grid("").sections.first?.title == "Pinned")
        #expect(Emoji.grid("").sections.first?.list.map(\.glyph) == ["🚀"])
        Emoji.used("⛵")
        #expect(Emoji.grid("").sections.first { $0.title == "Frequently Used" }?.list.first?.glyph == "⛵")
        Emoji.pin("🚀")
        #expect(!Emoji.grid("").sections.contains { $0.title == "Pinned" })
        #expect(Emoji.grid("rocket").flat == Emoji.find("rocket"))
        #expect(Emoji.grid("qqqzz").flat.isEmpty)
    }

    @Test func emojiCodePointsAreWrittenAsUnicodeWritesThem() {
        #expect(Emoji.unicode("🔥") == "U+1F525")
        #expect(Emoji.unicode("❤️") == "U+2764 U+FE0F")
        #expect(Emoji.unicode("🧑‍💻") == "U+1F9D1 U+200D U+1F4BB")
    }

    @MainActor @Test func emojiAreFoundByMeaning() {
        Emoji.warmNow()
        let top = { (words: String) in Emoji.find(words).prefix(24).map(\.glyph) }
        #expect(top("exhausted").contains("😴"))
        #expect(top("joyful").contains("😊") || top("joyful").contains("😀"))
        #expect(top("vehicle").contains("🚗"))
        #expect(top("programmer").contains("🧑‍💻"))
        #expect(Emoji.find("fire").first?.glyph == "🔥")
        #expect(Emoji.find("qqqzz").isEmpty)
    }
}
