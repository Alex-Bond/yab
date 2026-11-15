import CryptoKit
import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// Files a mail carries out (docs/mail.md, Files, Going out): the message as
// it goes, multipart/mixed with the words and each file, read back part by
// part by the reading half's own parser (MailMime, MailFile) with the same
// names and bytes; base64 76 to a line, CRLF; a message too big for a call of
// its own goes as an upload, and more than Gmail takes doesn't go; a draft's
// files kept across the store opened again, and gone with Disconnect; a
// forward carries the files of the mail it forwards, a reply only when asked.

struct MailAttachSendTests {
    let me = MailPerson(name: "Me", address: "me@example.com")
    let anna = MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")

    // MARK: - the message

    @Test func aMessageWithTwoFilesReadsBackWithItsPartsNamesAndBytes() throws {
        let deck = Self.noise(300_000)
        let notes = Data("Chiffres de septembre\nRevenue up 12%\n".utf8)
        let draft = MailDraft(to: [anna], subject: "Q3 numbers", body: "Both files attached.", messageID: "<q3@example.com>")
        let raw = MailCompose.raw(draft, from: me, files: [
            .init(name: "Q3 numbers.pdf", mime: "application/pdf", data: deck),
            .init(name: "Résumé de septembre, final.txt", mime: "text/plain", data: notes),
        ])
        // Nothing but ASCII in the message itself: the names as RFC 2231 has them.
        let ascii = raw.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii)
        let read = try #require(MIMEReading(raw))
        #expect(read.head["content-type"]?.hasPrefix("multipart/mixed; boundary=") == true)
        #expect(read.head["message-id"] == "<q3@example.com>")
        try #require(read.parts.count == 3)
        #expect(read.parts[0].head["content-type"] == "text/plain; charset=utf-8")
        #expect(String(decoding: read.parts[0].data, as: UTF8.self) == "Both files attached.")
        let files = Array(read.parts.dropFirst())
        #expect(files.map { $0.filename } == ["Q3 numbers.pdf", "Résumé de septembre, final.txt"])
        #expect(files.map { $0.name } == ["Q3 numbers.pdf", "Résumé de septembre, final.txt"])
        #expect(files.map { $0.type } == ["application/pdf", "text/plain"])
        #expect(files.allSatisfy { $0.head["content-disposition"]?.hasPrefix("attachment;") == true })
        #expect(files.map { Self.sha($0.data) } == [Self.sha(deck), Self.sha(notes)])
        // With no files, one plain part, as before.
        let plain = MailCompose.raw(draft, from: me)
        #expect(MailComposeTests.head(plain).contains("Content-Type: text/plain; charset=utf-8"))
        #expect(MailComposeTests.words(plain) == "Both files attached.")
    }

    @Test func base64IsAtMost76ToALineEveryLineEndingInCRLF() throws {
        let long = String(repeating: "Procès-verbal de réunion et contrat ", count: 4) + ".pdf"
        let raw = MailCompose.raw(MailDraft(to: [anna], subject: "Files", body: "Two.\nLines."), from: me, files: [
            .init(name: "big.bin", mime: "application/octet-stream", data: Self.noise(1_000_003)),
            .init(name: long, mime: "application/pdf", data: Self.noise(5_000)),
        ])
        // A line ends in CR LF, never in one of them alone.
        let unbroken = raw.replacingOccurrences(of: "\r\n", with: "")
        #expect(!unbroken.contains("\n") && !unbroken.contains("\r"))
        #expect(raw.hasSuffix("--\r\n"))
        let read = try #require(MIMEReading(raw))
        for part in read.parts {
            #expect(part.lines.allSatisfy { $0.count <= 76 }, "a line of base64 longer than 76")
            #expect(part.lines.dropLast().allSatisfy { $0.count == 76 })
            // The head too, a long name in pieces: no line past 78.
            #expect(part.headLines.allSatisfy { $0.count <= 78 }, "\(part.headLines.filter { $0.count > 78 })")
        }
        #expect(read.parts.last?.filename == long)
    }

    @Test func aBigMessageGoesAsAnUploadAndMoreThanGmailTakesIsRefused() {
        // Google's cap on a call that isn't an upload is 5 MB, and as JSON
        // the message is a third bigger.
        #expect(!MailCompose.uploads(1_000_000))
        #expect(!MailCompose.uploads(3_900_000))
        #expect(MailCompose.uploads(3_950_000))
        #expect(MailCompose.uploads(5 << 20))
        #expect(MailCompose.uploads(26_000_000))
        let file = { (size: Int) in MailDraftFile(id: "f\(size)", name: "big.bin", mime: "application/octet-stream", size: size) }
        #expect(MailAttach.tooBig([]) == nil)
        #expect(MailAttach.tooBig([file(24_000_000), file(1_000_000)]) == nil)
        #expect(MailAttach.tooBig([file(13_000_000), file(13_000_000)]) == "Too big to send: 26 MB of files, Gmail takes 25 MB")
    }

    @Test func aNameIsQuotedWhenPlainAndRFC2231OtherwiseInPiecesWhenLong() {
        #expect(MailCompose.parameter("filename", "Q3 numbers.pdf") == ";\r\n filename=\"Q3 numbers.pdf\"")
        #expect(MailCompose.parameter("filename", "say \"hi\".txt") == ";\r\n filename=\"say \\\"hi\\\".txt\"")
        #expect(MailCompose.parameter("filename", "Résumé.pdf") == ";\r\n filename*=UTF-8''R%C3%A9sum%C3%A9.pdf")
        let long = MailCompose.parameter("filename", String(repeating: "é", count: 30) + ".txt")
        #expect(long.hasPrefix(";\r\n filename*0*=UTF-8''%C3%A9"))
        #expect(long.contains(";\r\n filename*1*=%C3%A9"))
        // Read as the reading half reads a part's headers (MailMime).
        let read = MailMime.parameters("attachment" + long)
        #expect(read.value == "attachment")
        #expect(MailMime.filename("", disposition: read.params, type: [:]) == String(repeating: "é", count: 30) + ".txt")
        #expect(MailMime.filename("", disposition: MailMime.parameters("attachment" + MailCompose.parameter("filename", "say \"hi\".txt")).params,
                                  type: [:]) == "say \"hi\".txt")
    }

    /// A reply going out leaves its thread's place: kept under an id of
    /// its own with its files' copies, so a reply begun in the same thread
    /// inside the undo window is a new one, never the one going out; taken
    /// back, it is found in its place again.
    @Test func aReplyGoingOutLeavesItsPlace() throws {
        let file = Self.storeFile()
        defer { Self.clean(file) }
        let store = MailStore(file: file)
        var draft = MailDraft(id: "reply:t1", thread: "t1", body: "Here are the photos.")
        draft.files = MailAttach.take([try Self.file("Venue.png", Self.png)], draft: draft.id, store: store)
        store.save(draft)
        let copy = try #require(MailAttach.place(draft.files[0], draft: "reply:t1", store: store))
        #expect(MailDesk.place(of: "reply:t1", thread: "t1") == "reply:t1")
        #expect(MailDesk.place(of: "reply:t1:ab12cd34", thread: "t1") == "reply:t1")
        #expect(MailDesk.place(of: "forward:t1", thread: "t1") == "forward:t1")
        #expect(MailDesk.place(of: "reply:t10", thread: "t1") == nil && MailDesk.place(of: "new-1", thread: "") == nil)
        // Going out: under its own id, its copy moved with it, the place free.
        store.rename(draft: "reply:t1", to: "reply:t1:ab12cd34")
        let seq = MailOps.act(.send, thread: "reply:t1:ab12cd34", after: 5, in: store)
        #expect(store.draft("reply:t1") == nil && store.draft(place: "reply:t1") == nil)
        let going = try #require(store.draft("reply:t1:ab12cd34"))
        #expect(going.body == "Here are the photos." && going.files.map(\.name) == ["Venue.png"])
        let moved = try #require(MailAttach.place(going.files[0], draft: going.id, store: store))
        #expect(FileManager.default.fileExists(atPath: moved.path) && !FileManager.default.fileExists(atPath: copy.path))
        // A new reply in the thread meanwhile: its own.
        store.save(MailDraft(id: "reply:t1", thread: "t1", body: "Another word."))
        #expect(store.draft(place: "reply:t1")?.body == "Another word.")
        // Taken back (⌘Z) while that one holds the place: found there once it goes.
        #expect(MailOps.undo(seq, in: store))
        store.dropDraft("reply:t1")
        #expect(store.draft(place: "reply:t1")?.id == "reply:t1:ab12cd34")
        // Back in its place, its copy with it.
        store.rename(draft: "reply:t1:ab12cd34", to: "reply:t1")
        #expect(store.draft("reply:t1")?.files.map(\.name) == ["Venue.png"])
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @MainActor @Test func attachingIsAKeyOfTheKeymaps() {
        #expect(Shortcut.byAction[.mailAttach]?.key == Hotkey("u", [.shift, .command]))
        #expect(Shortcut.context(.mailAttach) == .mail)
        // It works while words are written: never a bare key.
        #expect(!Keymap.valid(Hotkey("u", []), for: .mailAttach))
    }

    // MARK: - kept with the draft

    @Test func aDraftsFilesOutliveTheStoreOpenedAgain() throws {
        let file = Self.storeFile()
        defer { Self.clean(file) }
        let store = MailStore(file: file)
        var draft = MailDraft(id: "new:1", to: [anna], subject: "")
        let a = try Self.file("Contract v2.pdf", Self.noise(40_000)), b = try Self.file("Données.xlsx", Self.noise(9_000))
        draft.files = MailAttach.take([a, b, a.deletingLastPathComponent()], draft: draft.id, store: store)
        // A folder is no file: left out.
        #expect(draft.files.map(\.name) == ["Contract v2.pdf", "Données.xlsx"])
        #expect(draft.files.map(\.size) == [40_000, 9_000])
        #expect(draft.files.map(\.mime) == ["application/pdf", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"])
        // And one of the mail it answers, by that mail's id and part.
        draft.files.append(MailDraftFile(id: "o1", name: "Deck v3.pdf", mime: "application/pdf", size: 1_200, message: "a1", part: "1"))
        store.save(draft)

        let again = MailStore(file: file)
        #expect(again.draft("new:1")?.files == draft.files)
        // In Kept with no words and no subject: it has files of its own.
        #expect(again.drafts().map(\.id) == ["new:1"])
        for one in draft.files where !one.original {
            let place = try #require(MailAttach.place(one, draft: draft.id, store: again))
            let kept = try Data(contentsOf: place), given = try Data(contentsOf: one.name == "Contract v2.pdf" ? a : b)
            #expect(Self.sha(kept) == Self.sha(given))
        }
        // The one chosen elsewhere can go: the copy is the draft's.
        try FileManager.default.removeItem(at: a)
        let copy = try #require(MailAttach.place(draft.files[0], draft: draft.id, store: again))
        #expect(FileManager.default.fileExists(atPath: copy.path))

        // Taken off: its copy gone, and so in the store.
        MailAttach.remove(draft.files[0], draft: draft.id, store: again)
        let gone = draft.files.removeFirst()
        again.save(draft)
        #expect(MailStore(file: file).draft("new:1")?.files.map(\.name) == ["Données.xlsx", "Deck v3.pdf"])
        let goneCopy = try #require(MailAttach.place(gone, draft: draft.id, store: again))
        #expect(!FileManager.default.fileExists(atPath: goneCopy.path))

        // A pasted picture: a PNG of its own name, then another beside it.
        let picture = try #require(MailAttach.take(picture: Self.png, draft: draft.id, beside: draft.files, store: again))
        #expect(picture.name == "Pasted image.png" && picture.mime == "image/png")
        let second = try #require(MailAttach.take(picture: Self.png, draft: draft.id, beside: draft.files + [picture], store: again))
        #expect(second.name == "Pasted image 2.png")

        // Sent: the draft, its rows and its copies gone.
        again.dropDraft("new:1")
        MailAttach.drop(draft: "new:1", store: again)
        #expect(MailStore(file: file).draft("new:1") == nil)
        let folder = try #require(MailAttach.folder(for: again, draft: "new:1"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func disconnectTakesADraftsFilesAwayAndAStartSweepsWhatNoDraftHas() throws {
        let file = Self.storeFile()
        defer { Self.clean(file) }
        let store = MailStore(file: file)
        let a = try Self.file("Lease.pdf", Self.noise(2_000))
        var kept = MailDraft(id: "reply:t1", thread: "t1", to: [anna], body: "Signed.")
        kept.files = MailAttach.take([a], draft: kept.id, store: store)
        store.save(kept)
        // Copied, never kept in the store (Yab quit between): swept when the account starts.
        _ = MailAttach.take([a], draft: "new:9", store: store)
        let root = try #require(MailAttach.folder(for: store))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["reply-t1", "new-9"])
        MailAttach.sweep(store)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["reply-t1"])
        // Disconnect: every draft's files gone with the store.
        MailAttach.forget(store: file)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // A store kept in memory keeps no files.
        #expect(MailAttach.take([a], draft: "new:1", store: MailStore(file: MailStore.memory)).isEmpty)
    }

    // MARK: - helpers

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Bytes nobody would guess, fast.
    static func noise(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }

    /// A picture's bytes: one pixel, as a PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    static func storeFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mail-attach-\(UUID().uuidString).sqlite")
    }

    static func clean(_ store: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: store.path + suffix) }
        try? FileManager.default.removeItem(at: MailStore.beside(store))
    }

    /// A file of these bytes, in a folder of its own.
    static func file(_ name: String, _ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

/// Files through the engine, against a Gmail kept in memory: a reply with a
/// file in one multipart/mixed, the file whole; a big one by upload, a new
/// mail's alone and a reply's with its thread; one Gmail took but didn't
/// answer never sent twice; more than Gmail takes never sent. With
/// MailSyncTests, one at a time (FakeGmail.current).
extension MailSyncAppTests {
    @Test func filesGoWholeABigMailByUploadAndOneTooBigNever() async throws {
        let (store, gmail, fake) = world()
        defer { MailAttachSendTests.clean(store.file) }
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        let send = { (draft: MailDraft) async throws in
            var draft = draft
            if draft.messageID.isEmpty { draft.messageID = MailCompose.messageID(from: store.me) }
            store.save(draft)
            MailOps.act(.send, thread: draft.id, in: store)
            try await MailOps.flush(store, gmail: gmail)
        }

        // A reply with a small file: one call as JSON, one multipart/mixed, the file whole.
        let deck = MailAttachSendTests.noise(200_000)
        var reply = try #require(MailCompose.reply(to: store.messages(thread: "ta"), me: store.me))
        reply.id = "reply:ta"
        reply.body = "Deck attached."
        reply.files = MailAttach.take([try MailAttachSendTests.file("Deck v3.pdf", deck)], draft: reply.id, store: store)
        try await send(reply)
        #expect(fake.doors == ["raw"])
        #expect(fake.messages["s1"]?.thread == "ta")
        let one = try #require(fake.sent.first)
        let first = try #require(MIMEReading(one))
        #expect(first.head["content-type"]?.hasPrefix("multipart/mixed;") == true)
        #expect(first.parts.map { $0.filename } == [nil, "Deck v3.pdf"])
        #expect(first.parts.last.map { MailAttachSendTests.sha($0.data) } == MailAttachSendTests.sha(deck))
        // Gone: the draft and the copy of its file.
        #expect(store.draft("reply:ta") == nil)
        let copies = try #require(MailAttach.folder(for: store, draft: "reply:ta"))
        #expect(!FileManager.default.fileExists(atPath: copies.path))

        // A new mail of 6 MB: an upload, the message alone.
        let big = MailAttachSendTests.noise(6_000_000)
        var fresh = MailDraft(id: "new:1", to: [MailPerson(name: "Tim Okafor", address: "tim@okafor.co")], subject: "Footage", body: "The raw cut.")
        fresh.files = MailAttach.take([try MailAttachSendTests.file("cut.mov", big)], draft: fresh.id, store: store)
        try await send(fresh)
        #expect(fake.doors.last == "media")
        #expect(fake.calls.contains("POST upload/messages/send"))
        let two = try #require(fake.sent.last)
        let second = try #require(MIMEReading(two))
        #expect(second.parts.last?.filename == "cut.mov" && second.parts.last?.type == "video/quicktime")
        #expect(second.parts.last.map { MailAttachSendTests.sha($0.data) } == MailAttachSendTests.sha(big))

        // A reply of 6 MB: an upload with its thread beside it, and Gmail took
        // it but didn't answer: asked again later, it is found in Sent, never twice.
        var again = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: store.me))
        again.id = "reply:tb"
        again.body = "Statement attached."
        again.files = MailAttach.take([try MailAttachSendTests.file("statement.pdf", big)], draft: again.id, store: store)
        fake.dropAnswers = 1
        try await send(again)
        #expect(fake.doors.last == "multipart")
        #expect(fake.messages["s3"]?.thread == "tb")
        #expect(store.draft("reply:tb") != nil)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(600) })
        #expect(fake.sent.count == 3)
        #expect(store.draft("reply:tb") == nil)

        // 26 MB: never goes; the draft stays to be sent with less.
        var huge = MailDraft(id: "new:2", to: [MailPerson(name: "", address: "tim@okafor.co")], subject: "Everything", body: "All of it.")
        huge.files = MailAttach.take([try MailAttachSendTests.file("all.zip", Data(count: 26_000_000))], draft: huge.id, store: store)
        try await send(huge)
        #expect(fake.sent.count == 3)
        #expect(store.pendingOps == 0)
        #expect(store.draft("new:2")?.files.map(\.name) == ["all.zip"])
    }
}

/// A mail with files read back as the reading half reads any mail from
/// Gmail; a forward carrying the files of the mail it forwards, a reply
/// not unless asked. With MailSyncTests, one at a time (FakeGmail.current).
extension MailSyncAppTests {
    @Test func aMailWithTwoFilesReadsBackFromGmailWithItsNamesAndBytes() async throws {
        let (store, gmail, fake) = world()
        defer { MailAttachSendTests.clean(store.file) }
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        let deck = MailAttachSendTests.noise(120_000), notes = Data("Chiffres de septembre: revenus +12%\n".utf8)
        var draft = MailDraft(id: "new:1", to: [MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")], subject: "Q3",
                              body: "Both attached.", messageID: MailCompose.messageID(from: store.me))
        draft.files = MailAttach.take([try MailAttachSendTests.file("Q3 deck, final.pdf", deck),
                                       try MailAttachSendTests.file("Résumé de septembre, final.txt", notes)], draft: draft.id, store: store)
        store.save(draft)
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.sent.count == 1)

        // As any mail comes: Gmail's parts read by MailGmail.message (MailFile,
        // MailMime), the bytes fetched by their attachment ids (MailFiles).
        let back = try #require(try await gmail.message("s1", full: true))
        #expect(back.text == "Both attached.")
        let files = try #require(back.files)
        #expect(files.map(\.name) == ["Q3 deck, final.pdf", "Résumé de septembre, final.txt"])
        #expect(files.map(\.mime) == ["application/pdf", "text/plain"])
        #expect(files.map(\.size) == [deck.count, notes.count])
        #expect(files.allSatisfy { !$0.inline && !$0.attachmentID.isEmpty })
        store.put([back])
        let kept = try #require(MailFiles.of(store, gmail))
        for (file, given) in zip(files, [deck, notes]) {
            let data = try await kept.data(message: "s1", part: file.part)
            #expect(MailAttachSendTests.sha(data) == MailAttachSendTests.sha(given))
        }
    }

    @Test func aForwardCarriesTheFilesOfTheMailItForwardsAndAReplyOnlyWhenAsked() async throws {
        let (store, gmail, fake) = world()
        defer { MailAttachSendTests.clean(store.file) }
        seed(fake)
        let deck = MailAttachSendTests.noise(150_000)
        fake.add(.init(id: "f1", thread: "tf", from: "Anna Lindqvist <anna@fold.studio>", subject: "Deck v3", body: "Deck attached, chart inside.",
                       at: now.addingTimeInterval(-600), labels: ["INBOX", "UNREAD"],
                       files: [.init(name: "Deck v3.pdf", mime: "application/pdf", data: deck),
                               .init(name: "chart.png", mime: "image/png", data: MailAttachSendTests.png, contentID: "<chart@fold.studio>", inline: true)],
                       html: "<p>Deck attached.</p><img src=\"cid:chart@fold.studio\">"), record: false)
        try await MailSync(store: store, gmail: gmail).sync()
        let thread = store.messages(thread: "tf")
        try #require(thread.last?.files != nil)

        // F: its file as a chip to take off, the picture its words draw left out.
        var forward = try #require(MailCompose.forward(thread))
        #expect(forward.files.map(\.name) == ["Deck v3.pdf"])
        #expect(forward.files.allSatisfy { $0.original && $0.message == "f1" })
        // R: none by itself; ⌘K's Include Original Attachments has them.
        #expect(try #require(MailCompose.reply(to: thread, me: store.me)).files.isEmpty)
        #expect(MailAttach.originals(of: try #require(thread.last)).map(\.name) == ["Deck v3.pdf"])

        // Sent: the file fetched from Gmail into the message whole.
        forward.id = "forward:tf"
        forward.to = [MailPerson(name: "Tim Okafor", address: "tim@okafor.co")]
        forward.body = "FYI, the deck."
        forward.messageID = MailCompose.messageID(from: store.me)
        store.save(forward)
        #expect(store.draft("forward:tf")?.files == forward.files)
        MailOps.act(.send, thread: forward.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        let raw = try #require(fake.sent.last)
        let read = try #require(MIMEReading(raw))
        #expect(read.parts.map(\.filename) == [nil, "Deck v3.pdf"])
        #expect(read.parts.last.map { MailAttachSendTests.sha($0.data) } == MailAttachSendTests.sha(deck))
        #expect(fake.messages["s1"]?.thread == "tf")
        #expect(store.draft("forward:tf") == nil)
    }
}
