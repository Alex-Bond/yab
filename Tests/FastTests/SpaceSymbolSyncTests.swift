import Foundation
import Testing
@testable import SyncKit
@testable import Fast

// Feedback #354: a space's icon picked from the Icon tab (an SF Symbol,
// kept by name) turned back into the emoji an iPhone shows for it. The
// iPhone draws emoji only and wrote what it showed back over the symbol;
// the Mac took it.
struct SpaceSymbolSyncTests {
    /// What the iPhone writes for a space the Mac sent as star.fill, shown
    /// there as ⭐️: the symbol, until another emoji is picked there.
    @Test func anIPhoneWritesTheMacsSymbolBackAsIt() {
        #expect(SpaceSymbols.emoji("star.fill") == "⭐️")
        #expect(SpaceSymbols.wire(shown: "⭐️", synced: "star.fill") == "star.fill")
        #expect(SpaceSymbols.wire(shown: "🔭", synced: "star.fill") == "🔭")
        #expect(SpaceSymbols.wire(shown: "🔭", synced: "💼") == "🔭")
        #expect(SpaceSymbols.wire(shown: "💼", synced: "💼") == "💼")
    }

    /// A Mac keeps its symbol when what came back is only its emoji twin,
    /// as an iPhone from before wrote it; anything else is taken.
    @Test func aMacKeepsItsSymbolOverItsOwnEmojiTwin() {
        #expect(SpaceSymbols.kept(incoming: "⭐️", had: "star.fill") == "star.fill")
        #expect(SpaceSymbols.kept(incoming: "🎨", had: "paintpalette.fill") == "paintpalette.fill")
        #expect(SpaceSymbols.kept(incoming: "🔭", had: "star.fill") == "🔭")
        #expect(SpaceSymbols.kept(incoming: "moon.fill", had: "star.fill") == "moon.fill")
        #expect(SpaceSymbols.kept(incoming: "⭐️", had: "💼") == "⭐️")
    }

    @Test func aDeliberateMatchingEmojiChoiceStillGoesThrough() {
        #expect(SpaceSymbols.kept(incoming: "⭐️", had: "star.fill", choice: "⭐️") == "⭐️")
        #expect(SpaceSymbols.kept(incoming: "🎨", had: "paintpalette.fill", choice: "🎨") == "🎨")
        #expect(SpaceSymbols.kept(incoming: "⭐️", had: "star.fill", choice: "star.fill") == "star.fill")
        #expect(SpaceSymbols.kept(incoming: "⭐️", had: "star.fill", choice: "🔭") == "star.fill")
    }

    @Test func aChoiceAndItsIconAreStampedTogetherEvenWhenOnlyTheChoiceChanged() throws {
        SyncCollection.register()
        let journal = try Journal(path: nil, device: "new-mac")
        let id = UUID().uuidString, key = Record.Key(collection: SyncCollection.space, id: id)
        let old = try journal.change(key, ["name": "Work", "icon": "⭐️"])
        // The icon already is the emoji an old device echoed. Picking that
        // same emoji here must still publish a newer, explicit choice.
        let picked = try journal.change(key, ["icon": "⭐️", "iconChoice": "⭐️"])
        #expect(picked["iconChoice"]?.string == "⭐️")
        #expect(picked.stamps["icon"] == picked.stamps["iconChoice"])
        let pickedStamp = try #require(picked.stamps["icon"]), oldStamp = try #require(old.stamps["icon"])
        #expect(pickedStamp > oldStamp)
        let renamed = try journal.change(key, ["name": "Work renamed"])
        #expect(renamed.stamps["icon"] == picked.stamps["icon"])
        #expect(renamed.stamps["iconChoice"] == picked.stamps["iconChoice"])
    }

    @Test func anOldEchoCannotInheritAnUnrelatedMatchingChoiceDuringMerge() {
        SyncCollection.register()
        let id = UUID().uuidString
        let earlier = Stamp(wall: 100, device: "new-mac")
        let later = Stamp(wall: 200, device: "old-mac")
        let picked = Record(collection: SyncCollection.space, id: id,
                            fields: ["icon": "⭐️", "iconChoice": "⭐️"],
                            stamps: ["icon": earlier, "iconChoice": earlier])
        let echo = Record(collection: SyncCollection.space, id: id,
                          fields: ["icon": "⭐️"], stamps: ["icon": later])
        let merged = picked.merged(with: echo)
        #expect(merged["iconChoice"] == nil)
        #expect(merged.stamps["icon"] == later)
        #expect(merged.stamps["iconChoice"] == nil)
    }

    @Test func anExplicitChoiceSurvivesSyncSpaceEncoding() throws {
        let id = UUID().uuidString
        let choiceID = UUID().uuidString
        let chosen = SyncSpace(id: id, name: "Symbol", icon: "star.fill", iconChoice: "star.fill", iconChoiceID: choiceID)
        let back = try #require(SyncSpace(Record(collection: SyncCollection.space, id: id, fields: chosen.fields)))
        #expect(back.icon == "star.fill" && back.iconChoice == "star.fill")
        #expect(back.iconChoiceID == choiceID)
        let original = SyncSpace(id: id, name: "Original emoji", icon: "🏠")
        #expect(original.fields["iconChoice"] == nil)
        #expect(original.fields["iconChoiceID"] == nil)
    }

    @Test func repeatedSameEmojiPicksRepairStaleIntentAndReachTheOtherJournal() throws {
        SyncCollection.register()
        let id = UUID(), key = Record.Key(collection: SyncCollection.space, id: id.uuidString)
        let sender = try Journal(path: nil, device: "new-mac"), receiver = try Journal(path: nil, device: "other-mac")
        let oldID = UUID().uuidString
        let echoed = SyncSpace(id: id.uuidString, name: "Work", icon: "⭐️", order: "M", iconChoice: "⭐️", iconChoiceID: oldID)
        let recent = Stamp(wall: 200, device: "old-mac"), stale = Stamp(wall: 100, device: "old-mac")
        var stamps = Dictionary(uniqueKeysWithValues: echoed.fields.keys.map { ($0, recent) })
        stamps["iconChoice"] = stale; stamps["iconChoiceID"] = stale
        let echo = Record(collection: SyncCollection.space, id: id.uuidString, fields: echoed.fields, stamps: stamps)
        _ = try sender.receive([(record: echo, version: 1)])
        _ = try receiver.receive([(record: echo, version: 1)])
        // This Mac kept the selected symbol over that stale echo. A real
        // manual pick of the same emoji must change a value, so both the
        // sender and the receiver notice the renewed intent.
        var local = Space(id: id, name: "Work", icon: "star.fill", ownSignIns: false)
        var previousID = oldID
        for version in [Int64(2), Int64(3)] {
            local.chooseIcon("⭐️")
            #expect(local.iconChoiceID != previousID)
            try sender.reconcile(SyncCollection.space, SyncShapes.spaces([local], orders: [id.uuidString: "M"]))
            let picked = try #require(sender.record(key))
            #expect(picked.stamps["icon"] == picked.stamps["iconChoice"])
            #expect(picked.stamps["icon"] == picked.stamps["iconChoiceID"])
            let changes = try receiver.receive([(record: picked, version: version)])
            #expect(changes.map(\.id) == [id.uuidString], "the new pick must reach adoption even though icon and choice text did not change")
            #expect(receiver.record(key)?["iconChoiceID"]?.string == local.iconChoiceID)
            previousID = try #require(local.iconChoiceID)
        }
    }
}
