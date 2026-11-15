import Foundation
import SyncKit
import Testing
@testable import Fast

/// Photos and files with words from the iPhone (SyncSendFile): the parts
/// they travel in, and what a Mac does with a send that has them.
struct SyncSendFileTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-send-files-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    /// A file's description and its part records, as an iPhone writes them.
    private func made(_ data: Data, name: String = "photo.jpg", send: String = "s1", index: Int = 0)
        -> (file: SyncSendFile, parts: [String: Record]) {
        let pieces = SyncSendFile.parts(of: data, send: send, index: index)
        var records: [String: Record] = [:]
        for piece in pieces { records[piece.id] = Record(collection: SyncCollection.sendPart, id: piece.id, fields: piece.fields) }
        let file = SyncSendFile(name: name, type: "image/jpeg", size: data.count, digest: SyncSendFile.hex(data), parts: pieces.map(\.id))
        return (file, records)
    }

    // MARK: SyncKit

    @Test func partsPutTogetherAgain() throws {
        let data = bytes(SyncSendFile.partSize * 2 + 1234)
        let (file, parts) = made(data)
        #expect(file.parts == ["s1/0/0", "s1/0/1", "s1/0/2"])
        #expect(file.assembled { parts[$0] } == .data(data))
        #expect(file.assemble { parts[$0] } == data)
        // Read back from the send's field as a Mac reads it.
        let read = try #require(SyncSendFile.read(.array([file.value]), send: "s1"))
        #expect(read == [file])
    }

    @Test func anEmptyFileIsOnePartOfNothing() {
        let (file, parts) = made(Data())
        #expect(file.parts.count == 1)
        #expect(file.assembled { parts[$0] } == .data(Data()))
        #expect(SyncSendFile.read(.array([file.value]), send: "s1") == [file])
    }

    @Test func aMissingPartWaitsAndAWrongFileFails() {
        let data = bytes(SyncSendFile.partSize + 10)
        let (file, parts) = made(data)
        var some = parts
        some["s1/0/1"] = nil
        #expect(file.assembled { some[$0] } == .missing)
        #expect(!file.arrived { some[$0] })
        // Removed counts as not there.
        var removed = parts
        removed["s1/0/1"]?.deleted = Stamp(wall: 1, device: "phone")
        #expect(file.assembled { removed[$0] } == .missing)
        // The wrong digest, the wrong size, a part that isn't base64.
        var wrong = file
        wrong.digest = String(repeating: "0", count: 64)
        #expect(wrong.assembled { parts[$0] } == .wrong)
        var short = file
        short.size -= 1
        #expect(short.assembled { parts[$0] } == .wrong)
        var garbled = parts
        garbled["s1/0/0"] = Record(collection: SyncCollection.sendPart, id: "s1/0/0", fields: ["data": "not base64!"])
        #expect(file.assembled { garbled[$0] } == .wrong)
        #expect(file.assemble { garbled[$0] } == nil)
    }

    @Test func filesAMacWontRead() {
        let (file, _) = made(bytes(100))
        #expect(SyncSendFile.read(nil, send: "s1") == [])
        // Parts of another send, or not as many as the size needs.
        #expect(SyncSendFile.read(.array([file.value]), send: "other") == nil)
        var extra = file
        extra.parts.append("s1/0/1")
        #expect(SyncSendFile.read(.array([extra.value]), send: "s1") == nil)
        // Too many, too big, not a list.
        #expect(SyncSendFile.read(.array(Array(repeating: file.value, count: SyncSendFile.mostCount + 1)), send: "s1") == nil)
        var big = file.value.object!
        big["size"] = .number(Double(SyncSendFile.most + 1))
        #expect(SyncSendFile.read(.array([.object(big)]), send: "s1") == nil)
        #expect(SyncSendFile.read(.string("x"), send: "s1") == nil)
        // A name with folders is only its last part.
        var named = file.value.object!
        named["name"] = "../../etc/passwd"
        #expect(SyncSendFile(.object(named))?.name == "passwd")
    }

    // MARK: The Mac

    @Test @MainActor func theMacSaysItTakesFiles() {
        let record = Record(collection: OpenOnMac.capability, id: "mac", fields: SyncChats.capability(device: "mac"))
        #expect(SyncSendFile.supports(record, device: "mac"))
        var older = SyncChats.capability(device: "mac")
        older[SyncSendFile.capability] = nil
        #expect(!SyncSendFile.supports(Record(collection: OpenOnMac.capability, id: "mac", fields: older), device: "mac"))
    }

    @Test func filesWithoutWordsAreStillASend() throws {
        let (photo, _) = made(bytes(10), send: "s1")
        let fields = SyncSend.fields(device: "mac", chat: "a:one", text: nil, choice: nil, kind: nil, project: nil,
                                     at: now.timeIntervalSince1970, files: [photo])
        let record = Record(collection: SyncChats.send, id: "s1", fields: fields)
        let words = try #require(SyncChats.waiting([record], device: "mac").first)
        #expect(words.text.isEmpty && words.files == [photo] && !words.invalidFiles)
        #expect(ChatCommand.refusal(record) == nil)
        #expect(SyncSend(record)?.files == [photo])

        // A new chat with its agent chosen and only a photo.
        let (other, _) = made(bytes(10), send: "s2")
        let chosen = SyncSend.fields(device: "mac", chat: nil, text: nil, choice: nil, kind: .agent, project: nil,
                                     at: now.timeIntervalSince1970, agent: .codex, files: [other])
        let new = Record(collection: SyncChats.send, id: "s2", fields: chosen)
        let started = try #require(SyncChats.waiting([new], device: "mac").first)
        #expect(!started.invalidAgent && started.cli == "codex" && started.files == [other])
        #expect(ChatCommand.refusal(new) == nil)

        // Files named in a way an iPhone never writes fail, not vanish.
        var bad = fields
        bad["files"] = .array([.string("nope")])
        let broken = try #require(SyncChats.waiting([Record(collection: SyncChats.send, id: "s3", fields: bad)], device: "mac").first)
        #expect(broken.invalidFiles)
        // Still nothing without words or files.
        #expect(SyncChats.waiting([Record(collection: SyncChats.send, id: "e", fields: ["device": "mac", "chat": "a:one"])],
                                  device: "mac").isEmpty)
    }

    @Test func aSendWaitsForItsPartsThenItsFilesAreSaved() throws {
        let room = try folder(); defer { try? FileManager.default.removeItem(at: room) }
        let journal = try Journal(path: room.appendingPathComponent("journal.sqlite").path, device: "mac")
        let first = bytes(SyncSendFile.partSize + 5), second = bytes(300)
        let a = made(first, name: "IMG_1.jpg", send: "s1", index: 0)
        let b = made(second, name: "IMG_1.jpg", send: "s1", index: 1)
        let send = try journal.change(.init(collection: SyncChats.send, id: "s1"),
                                      SyncSend.fields(device: "mac", chat: "a:one", text: "Look", choice: nil, kind: nil,
                                                      project: nil, at: now.timeIntervalSince1970, files: [a.file, b.file]))
        let part: (String) -> Record? = { journal.record(.init(collection: SyncChats.part, id: $0)) }
        // Only one file's parts so far: it waits.
        for record in a.parts.values { try journal.change(record.key, record.fields) }
        #expect(SyncChats.awaitingParts(send, device: "mac", now: now, part: part))
        // Past its 12 hours it is taken, to be marked expired.
        #expect(!SyncChats.awaitingParts(send, device: "mac", now: now.addingTimeInterval(ChatCommand.lifetime + 1), part: part))
        for record in b.parts.values { try journal.change(record.key, record.fields) }
        #expect(!SyncChats.awaitingParts(send, device: "mac", now: now, part: part))

        // Taken once: put together, checked and saved in the send's folder.
        let inbox = room.appendingPathComponent("inbox")
        var saved: [URL] = []
        let consumed = try ChatCommand.consume(send, in: journal, account: "account", device: "mac", at: now) { request in
            let words = try #require(SyncChats.waiting([request], device: "mac").first)
            let gathered = SyncChats.gather(words, into: inbox, part: part)
            #expect(gathered.reason == nil)
            saved = gathered.files
            return .taken()
        }
        #expect(consumed)
        #expect(journal.record(send.key)?["state"]?.string == "taken")
        #expect(saved.map(\.lastPathComponent) == ["IMG_1.jpg", "IMG_1 2.jpg"])
        #expect(saved.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "s1" })
        #expect(try Data(contentsOf: saved[0]) == first)
        #expect(try Data(contentsOf: saved[1]) == second)
        // The Mac wrote no part and removed none.
        #expect(journal.all(SyncChats.part).count == a.parts.count + b.parts.count)
        #expect(journal.all(SyncChats.part).allSatisfy { $0.alive() })
    }

    @Test func aFileThatIsntWhatWasSentFailsTheSend() throws {
        let room = try folder(); defer { try? FileManager.default.removeItem(at: room) }
        var (photo, parts) = made(bytes(50))
        photo.digest = String(repeating: "a", count: 64)
        let words = SyncChats.Words(id: "s1", chat: "a:one", text: "", kind: "agent", project: nil, choice: nil, at: now, files: [photo])
        let gathered = SyncChats.gather(words, into: room, part: { parts[$0] })
        #expect(gathered.reason == SyncChats.filesBroken && gathered.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: room.appendingPathComponent("s1").path))
        parts = [:]
        #expect(SyncChats.gather(words, into: room, part: { parts[$0] }).reason == SyncChats.filesBroken)
        var unread = words
        unread.invalidFiles = true
        #expect(SyncChats.gather(unread, into: room, part: { _ in nil }).reason == SyncChats.filesUnreadable)
    }

    @Test @MainActor func filesForAChatThisMacDoesntHaveFail() throws {
        let room = try folder(); defer { try? FileManager.default.removeItem(at: room) }
        let url = room.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: url)
        let (photo, _) = made(Data([1, 2, 3]))
        let words = SyncChats.Words(id: "s1", chat: "a:missing-\(UUID().uuidString)", text: "", kind: "agent", project: nil,
                                    choice: nil, at: now, files: [photo])
        #expect(SyncCenter().say(words, files: [url]).reason == "That chat isn't on this Mac any more.")
        // Files named but not handed over aren't said without them.
        #expect(SyncCenter().say(words).reason == SyncChats.filesBroken)
        var unread = words
        unread.invalidFiles = true
        #expect(SyncCenter().say(unread).reason == SyncChats.filesUnreadable)
    }
}
