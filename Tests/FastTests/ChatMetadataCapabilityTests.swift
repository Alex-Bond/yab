import Testing
import SyncKit
@testable import Fast

struct ChatMetadataCapabilityTests {
    @Test func supportIsIndependentOfOpenAndBoundToAnAliveOwnerRecord() throws {
        Kind.register(Kind(OpenOnMac.capability))
        let mac = try Journal(path: nil, device: "mac")
        let key = Record.Key(collection: OpenOnMac.capability, id: "mac")
        let open = try mac.change(key, ["device": "mac", "open": 1])
        #expect(OpenOnMac.supports(open, device: "mac"))
        #expect(!ChatMetadata.supports(open, device: "mac"))
        let chats = try mac.change(key, ["chatMetadata": .number(Double(ChatMetadata.version))])
        #expect(ChatMetadata.supports(chats, device: "mac"))
        #expect(OpenOnMac.supports(chats, device: "mac"))
        #expect(!ChatMetadata.supports(chats, device: "another-mac"))
        try mac.remove(key)
        #expect(!ChatMetadata.supports(mac.record(key), device: "mac"))
    }

    /// What the Mac writes is what the iPhone checks before it offers each
    /// command (PhoneSync.canOpen, canStartAgent,
    /// canSetChat): written through a journal, as flushChats does.
    @Test func theMacsOwnRecordOffersEveryCommandItTakes() throws {
        SyncShapes.register()
        let mac = try Journal(path: nil, device: "mac")
        let record = try mac.change(.init(collection: OpenOnMac.capability, id: "mac"), SyncChats.capability(device: "mac"))
        #expect(OpenOnMac.supports(record, device: "mac"))
        #expect(ChatAgent.supports(record, device: "mac"))
        #expect(record["questionGeneration"] == nil)
        #expect(ChatMetadata.supports(record, device: "mac"))
        // Only the Mac that wrote it.
        #expect(!OpenOnMac.supports(record, device: "other"))
        // Written again unchanged, nothing new goes up.
        try mac.sent(mac.pending().map { ($0.record, Int64(1)) })
        try mac.change(record.key, SyncChats.capability(device: "mac"))
        #expect(mac.pendingCount == 0)
    }

    /// Tasks are offered only by a Mac that runs them, with this run's epoch:
    /// what PhoneSync.readOnlyTaskEpoch reads before it sends one.
    @Test func tasksAreOfferedOnlyWithThisRunsEpoch() throws {
        SyncShapes.register()
        let mac = try Journal(path: nil, device: "mac")
        let key = Record.Key(collection: OpenOnMac.capability, id: "mac")
        let without = try mac.change(key, SyncChats.capability(device: "mac"))
        #expect(!TaskRecords.supports(without, mac: "mac"))
        #expect(TaskRecords.readOnlyEpoch(without, mac: "mac") == nil)
        let with = try mac.change(key, SyncChats.capability(device: "mac", taskEpoch: SyncCenter.taskEpoch))
        #expect(TaskRecords.supports(with, mac: "mac"))
        #expect(TaskRecords.readOnlyEpoch(with, mac: "mac") == SyncCenter.taskEpoch)
        #expect(OpenOnMac.supports(with, device: "mac") && ChatAgent.supports(with, device: "mac"))
        // Turned off again (sync off here), the phone stops offering it.
        let off = try mac.change(key, SyncChats.capability(device: "mac"))
        #expect(!TaskRecords.supports(off, mac: "mac"))
    }

    @Test func unknownVersionsMismatchedOwnersAndOtherCollectionsStayLocalOnly() {
        func head(_ value: Value, device: String = "mac", collection: String = OpenOnMac.capability) -> Record {
            Record(collection: collection, id: "mac", fields: ["device": .string(device), "chatMetadata": value])
        }
        for value in [Value.null, .bool(true), .number(0), .number(2), .string("1")] {
            #expect(!ChatMetadata.supports(head(value), device: "mac"))
        }
        #expect(!ChatMetadata.supports(head(1, device: "another-mac"), device: "mac"))
        #expect(!ChatMetadata.supports(head(1, collection: "chat"), device: "mac"))
        #expect(!ChatMetadata.supports(nil, device: "mac"))
    }
}
