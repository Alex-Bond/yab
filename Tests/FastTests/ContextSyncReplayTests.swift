import Foundation
import AppKit
import Testing
import SyncKit
@testable import Fast

struct ContextSyncReplayTests {
    @Test func addressPayloadCannotBorrowAnotherJournalKey() throws {
        let address = StreetAddress(id: "payload-B", street: "12 Fixture Street", city: "Testville")
        let data = try JSONEncoder().encode(address)
        #expect(SyncWallet.contextAddress(data, id: "record-A") == nil)
        #expect(SyncWallet.contextAddress(data, id: address.id) == address)
    }

    @Test func unavailableExactVersionCanBeExplicitlyKeptCleared() throws {
        try isolated { privacy, _, _, root in
            #expect(privacy.clear(privacy.preview(), choices: [:]).complete)
            let stamp = Stamp(wall: Clock.wallNow() + 10_000, device: "offline-fixture")
            let remote = record(SyncShapes.memory, "people/offline.md", fields: ["text": .string("Synthetic offline text")], stamp: stamp)
            let image = ContextSyncReplay.image(remote)
            #expect(!privacy.mayTakeSync("memory/" + remote.id, epoch: privacy.epoch, stamp: stamp, image: image))
            let replay = ContextSyncReplay(privacy: privacy, journal: nil, root: root)
            let item = try #require(replay.items().first)
            #expect(item.image == image && !item.canUse)
            #expect(!replay.resolve(item, use: true))
            #expect(replay.resolve(item, use: false))
            #expect(privacy.syncReview.isEmpty)
        }
    }

    private func isolated(_ body: (ContextPrivacy, ContextPrivacyTests.Fixture, SyncKit.Journal, URL) throws -> Void) throws {
        let domain = "context-replay-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let fixture = ContextPrivacyTests.Fixture()
        let privacy = ContextPrivacy(root: root, settings: settings, storage: MemoryContextJournal(), stores: fixture.stores)
        let journal = try SyncKit.Journal(path: nil, device: "local-fixture")
        privacy.attachSync(journal)
        try body(privacy, fixture, journal, root)
    }

    private func record(_ collection: String, _ id: String, fields: [String: Value], stamp: Stamp) -> SyncKit.Record {
        SyncKit.Record(collection: collection, id: id, fields: fields, stamps: fields.mapValues { _ in stamp })
    }

    @Test func exactReviewedProfileVersionIsAppliedImmediatelyAndCannotReplayAfterAnotherClear() throws {
        try isolated { privacy, fixture, journal, root in
            let grant = privacy.begin()
            #expect(privacy.profilePatch(["name": "Old learned value"], source: "fixture", grant: grant) != nil)
            #expect(privacy.clear(privacy.preview(), choices: [:]).complete)
            var incoming = Profile(); incoming.name = "Reviewed remote value"
            let stamp = Stamp(wall: Clock.wallNow() + 10_000, count: 4, device: "remote-fixture")
            let remote = try record(SyncShapes.file, "profile.json", fields: ["json": Value(encoding: incoming)], stamp: stamp)
            _ = try journal.receive([(record: remote, version: 1)])
            #expect(privacy.mergeSyncedProfile(incoming, epoch: privacy.epoch, stamp: stamp))
            #expect(fixture.profile.name.isEmpty)
            let replay = ContextSyncReplay(privacy: privacy, journal: journal, root: root)
            let item = try #require(replay.items().first { $0.id == "profile:name" })
            #expect(item.text == incoming.name && item.stamp == stamp && item.canUse)
            #expect(replay.resolve(item, use: true))
            #expect(fixture.profile.name == incoming.name && privacy.syncReview.isEmpty)
            let next = privacy.preview()
            #expect(next.legacy.contains { $0.id == "profile:name" })
            #expect(privacy.clear(next, choices: ["profile:name": .remove]).complete)
            #expect(fixture.profile.name.isEmpty)
            #expect(!privacy.mayTakeSync("profile:name", epoch: privacy.epoch, stamp: stamp, image: ContextSyncReplay.image(remote)), "A prior Use decision cannot revive data after the next clear")
        }
    }

    @Test func failedStoreAndChangedLocalOrRemoteVersionsRemainUnresolved() throws {
        try isolated { privacy, fixture, journal, root in
            let grant = privacy.begin()
            #expect(privacy.profilePatch(["name": "Learned"], source: "fixture", grant: grant) != nil)
            #expect(privacy.clear(privacy.preview(), choices: [:]).complete)
            var incoming = Profile(); incoming.name = "Remote"
            let stamp = Stamp(wall: Clock.wallNow() + 10_000, device: "remote-fixture")
            let remote = try record(SyncShapes.file, "profile.json", fields: ["json": Value(encoding: incoming)], stamp: stamp)
            _ = try journal.receive([(record: remote, version: 1)])
            _ = privacy.mergeSyncedProfile(incoming, epoch: privacy.epoch, stamp: stamp)
            let replay = ContextSyncReplay(privacy: privacy, journal: journal, root: root)
            let item = try #require(replay.items().first)
            fixture.saveWorks = false
            #expect(!replay.resolve(item, use: true))
            #expect(fixture.profile.name.isEmpty && privacy.syncReview[item.id] == stamp)
            fixture.saveWorks = true; fixture.profile.name = "Later manual edit"
            #expect(!replay.resolve(item, use: true))
            #expect(fixture.profile.name == "Later manual edit")
            let refreshed = try #require(replay.items().first)
            var changed = incoming; changed.name = "A different remote version"
            let newer = Stamp(wall: stamp.wall, count: 1, device: stamp.device)
            _ = try journal.receive([(record: try record(SyncShapes.file, "profile.json", fields: ["json": Value(encoding: changed)], stamp: newer), version: 2)])
            #expect(!replay.resolve(refreshed, use: true))
            #expect(privacy.syncReview[item.id] == newer)
            #expect(!replay.resolve(refreshed, use: false), "A stale choice cannot resolve the newer version")
            #expect(replay.resolve(try #require(replay.items().first), use: false))
            #expect(!privacy.mayTakeSync(item.id, epoch: privacy.epoch, stamp: newer))
        }
    }

    @Test func memoryReplayWritesTheReviewedRecordAndProtectsLaterEditorChanges() throws {
        try isolated { privacy, _, journal, root in
            #expect(privacy.clear(privacy.preview(), choices: [:]).complete)
            let stamp = Stamp(wall: Clock.wallNow() + 10_000, device: "remote-fixture")
            let remote = record(SyncShapes.memory, "people/fixture.md", fields: ["text": .string("# Synthetic person\nReviewed text")], stamp: stamp)
            _ = try journal.receive([(record: remote, version: 1)])
            #expect(!privacy.mayTakeSync("memory/" + remote.id, epoch: privacy.epoch, stamp: stamp))
            let replay = ContextSyncReplay(privacy: privacy, journal: journal, root: root)
            let item = try #require(replay.items().first)
            #expect(replay.resolve(item, use: true))
            let file = root.appendingPathComponent("memory/people/fixture.md")
            #expect(try String(contentsOf: file, encoding: .utf8) == remote["text"]?.string)
            let second = record(SyncShapes.memory, remote.id, fields: ["text": .string("Changed remote text")], stamp: Stamp(wall: stamp.wall, count: 2, device: stamp.device))
            _ = try journal.receive([(record: second, version: 2)])
            #expect(!privacy.mayTakeSync("memory/" + remote.id, epoch: privacy.epoch, stamp: second.latest))
            let stale = try #require(replay.items().first)
            try "Later manual text".write(to: file, atomically: true, encoding: .utf8)
            #expect(!replay.resolve(stale, use: true))
            #expect(try String(contentsOf: file, encoding: .utf8) == "Later manual text")
        }
    }

    @Test func addressReplayUsesOnlyInjectedAddressPayloadAndPreservesOtherFields() throws {
        try isolated { privacy, fixture, journal, root in
            let grant = privacy.begin()
            let old = StreetAddress(id: "fixture-address", street: "12 Fixture Street", city: "Testville")
            fixture.addresses = [old]
            var learned = old; learned.phone = "555-0100"
            #expect(privacy.saveAddress(learned, origin: .learned(grant)))
            let preview = privacy.preview()
            #expect(privacy.clear(preview, choices: Dictionary(uniqueKeysWithValues: preview.legacy.map { ($0.id, .keep) })).complete)
            var incoming = old; incoming.phone = "555-0199"; incoming.street = "Unreviewed remote street"
            let stamp = Stamp(wall: Clock.wallNow() + 10_000, device: "remote-fixture")
            let remote = record(SyncWallet.address, old.id, fields: ["secret": .string("synthetic sealed-address placeholder")], stamp: stamp)
            _ = try journal.receive([(record: remote, version: 1)])
            #expect(!privacy.mayTakeSync("address/" + old.id + ":phone", epoch: privacy.epoch, stamp: stamp))
            var decoded = 0
            let replay = ContextSyncReplay(privacy: privacy, journal: journal, root: root, decodeAddress: { _ in decoded += 1; return incoming })
            let item = try #require(replay.items().first)
            #expect(decoded == 1 && item.text == incoming.phone)
            #expect(replay.resolve(item, use: true))
            #expect(fixture.addresses.first?.phone == incoming.phone && fixture.addresses.first?.street == old.street)
        }
    }

    @Test func sameLatestStampDoesNotAuthorizeAChangedCRDTPayload() throws {
        try isolated { privacy, fixture, journal, root in
            let original = StreetAddress(id: "fixture", street: "12 Fixture Street", city: "Testville")
            fixture.addresses = [original]
            #expect(privacy.saveAddress(StreetAddress(id: original.id, street: original.street, city: original.city, phone: "555-0100"), origin: .learned(privacy.begin())))
            let plan = privacy.preview()
            #expect(privacy.clear(plan, choices: Dictionary(uniqueKeysWithValues: plan.legacy.map { ($0.id, .keep) })).complete)
            let low = Stamp(wall: Clock.wallNow() + 10_000, count: 1, device: "remote-fixture")
            let high = Stamp(wall: low.wall, count: 100, device: low.device)
            var remote = SyncKit.Record(collection: SyncWallet.address, id: original.id,
                fields: ["secret": .string("first"), "facts": .string("metadata")], stamps: ["secret": low, "facts": high])
            _ = try journal.receive([(record: remote, version: 1)])
            let id = "address/" + original.id + ":phone"
            #expect(!privacy.mayTakeSync(id, epoch: privacy.epoch, stamp: high, image: ContextSyncReplay.image(remote)))
            let replay = ContextSyncReplay(privacy: privacy, journal: journal, root: root, decodeAddress: { record in
                var incoming = original; incoming.phone = record["secret"]?.string ?? ""; return incoming
            })
            let stale = try #require(replay.items().first)
            remote.fields["secret"] = .string("second"); remote.stamps["secret"] = Stamp(wall: low.wall, count: 70, device: low.device)
            let changed = try journal.receive([(record: remote, version: 2)])
            let merged = try #require(changed.first)
            #expect(merged.latest == stale.stamp)
            #expect(!replay.resolve(stale, use: true))
            let fresh = try #require(replay.items().first)
            #expect(fresh.image != stale.image && fresh.text == "second")
            #expect(replay.resolve(fresh, use: true))
            remote.fields["secret"] = .string("third"); remote.stamps["secret"] = Stamp(wall: low.wall, count: 90, device: low.device)
            let next = try #require(try journal.receive([(record: remote, version: 3)]).first)
            #expect(next.latest == fresh.stamp)
            #expect(!privacy.mayTakeSync(id, epoch: privacy.epoch, stamp: next.latest, image: ContextSyncReplay.image(next)))
        }
    }

    @Test func missingPreviewCannotOverwriteANewUnreadableFile() throws {
        try isolated { privacy, _, journal, root in
            #expect(privacy.clear(privacy.preview(), choices: [:]).complete)
            let stamp = Stamp(wall: Clock.wallNow() + 10_000, device: "remote-fixture")
            let remote = record(SyncShapes.memory, "people/fixture.md", fields: ["text": .string("Remote text")], stamp: stamp)
            _ = try journal.receive([(record: remote, version: 1)])
            _ = privacy.mayTakeSync("memory/" + remote.id, epoch: privacy.epoch, stamp: stamp, image: ContextSyncReplay.image(remote))
            let replay = ContextSyncReplay(privacy: privacy, journal: journal, root: root)
            let item = try #require(replay.items().first)
            let file = root.appendingPathComponent("memory/people/fixture.md")
            // A directory is an existing local image that Data cannot read
            // as the reviewed file, independent of the test runner's uid.
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            #expect(!replay.resolve(item, use: true))
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
    }

    @Test func failedLocalValidationNeverPersistsAnAdmissionEvenIfStorageCannotWrite() throws {
        final class Storage: ContextJournalStorage {
            var data: Data?
            var writes = 0
            var fail = false
            func read() -> Data? { data }
            func write(_ data: Data) -> Bool { writes += 1; guard !fail else { return false }; self.data = data; return true }
        }
        let domain = "replay-durability-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let fixture = ContextPrivacyTests.Fixture(), storage = Storage()
        let root = URL(fileURLWithPath: "/fixture/" + domain)
        let privacy = ContextPrivacy(root: root, settings: settings, storage: storage, stores: fixture.stores)
        #expect(privacy.profilePatch(["name": "Learned"], source: "fixture", grant: privacy.begin()) != nil)
        #expect(privacy.clear(privacy.preview(), choices: [:]).complete)
        var incoming = Profile(); incoming.name = "Remote"
        let stamp = Stamp(wall: Clock.wallNow() + 10_000, device: "remote-fixture")
        let journal = try SyncKit.Journal(path: nil, device: "local-fixture")
        let remote = try record(SyncShapes.file, "profile.json", fields: ["json": Value(encoding: incoming)], stamp: stamp)
        _ = try journal.receive([(record: remote, version: 1)])
        _ = privacy.mergeSyncedProfile(incoming, epoch: privacy.epoch, stamp: stamp, image: ContextSyncReplay.image(remote))
        let replay = ContextSyncReplay(privacy: privacy, journal: journal, root: root)
        let item = try #require(replay.items().first)
        fixture.profile.name = "Later manual value"
        let writes = storage.writes; storage.fail = true
        #expect(!replay.resolve(item, use: true))
        #expect(storage.writes == writes, "A failed local-image check needs no dangerous acceptance/rollback transaction")
        let restart = ContextPrivacy(root: root, settings: settings, storage: storage, stores: fixture.stores)
        #expect(!restart.mayTakeSync(item.id, epoch: restart.epoch, stamp: stamp, image: item.image))
        #expect(fixture.profile.name == "Later manual value")
    }
}

@MainActor
struct MemoryReviewConsentTests {
    @Test func modelRequiresAnExplicitAvailableChoiceAndRefreshesAChangedValue() {
        let domain = "memory-review-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let fixture = ContextPrivacyTests.Fixture(); fixture.profile.name = "Historical value"
        let root = URL(fileURLWithPath: "/fixture/" + domain)
        let privacy = ContextPrivacy(root: root, settings: settings, storage: MemoryContextJournal(), stores: fixture.stores)
        let replay = ContextSyncReplay(privacy: privacy, journal: nil, root: root)
        let review = MemoryClearReview(privacy: privacy, sync: replay)
        #expect(review.legacyChoices.isEmpty && !review.enablement.allowed)
        review.legacyChoices["profile:name"] = .restore
        #expect(!review.enablement.allowed)
        review.legacyChoices["profile:name"] = .keep
        #expect(review.enablement.allowed)
        fixture.profile.name = "Later value"
        #expect(!review.perform())
        #expect(review.plan.legacy.first?.value.value == "Later value")
        #expect(review.legacyChoices.isEmpty && !review.enablement.allowed && !fixture.erased)
    }

    @Test func unresolvedConfirmationRejectsSemanticAndKeyboardAdmission() {
        let enabled = Question.Enablement()
        var question = Question(title: "Fixture review", yes: "Forget", danger: true)
        question.enablement = enabled
        #expect(!question.canAnswer(true) && question.canAnswer(false))
        enabled.allowed = true
        #expect(question.canAnswer(true))
        enabled.allowed = false
        #expect(!question.canAnswer(true))
    }

    @Test func realQuestionContinuationWaitsUntilReviewEnablesYes() async throws {
        _ = NSApplication.shared
        let questions = Questions(), enabled = Question.Enablement()
        var question = Question(title: "Fixture review", yes: "Forget", danger: true, place: .plain)
        question.enablement = enabled
        let task = Task { guard !Task.isCancelled else { return false }; return await questions.ask(question) }
        defer { questions.answer(false); task.cancel() }
        for _ in 0..<1_000 {
            if questions.current?.id == question.id { break }
            await Task.yield()
        }
        try #require(questions.current?.id == question.id)
        questions.answer(true)
        #expect(questions.current?.id == question.id, "The actual semantic/keyboard answer path must keep the owed continuation pending")
        enabled.allowed = true
        questions.answer(true)
        #expect(await task.value)
        #expect(questions.current == nil)
    }
}
