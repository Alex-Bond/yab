import Foundation
import ImageIO
import SyncKit
import UIKit
import XCTest
@testable import YabPhone

/// Photos and files with words for a Mac's chat: their parts go before the
/// send, they go once the send is answered, the limits hold, a Mac that
/// doesn't take them gets none, and a photo goes at most 2048 on its long side.
@MainActor
final class ChatAttachmentsTests: XCTestCase {
    private var folder: URL!
    private let chat = "a:attach"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-attach-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func until(_ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func joined(attachments: Bool = true) async throws -> (PhoneSync, TestMac) {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal, id: "mac")
        mac.client.start()
        let live = await until { mac.client.state == .live }
        XCTAssertTrue(live)
        try mac.write(OpenOnMac.capability, "mac", ["device": "mac", "open": 1,
                                                  SyncSendFile.capability: attachments ? .number(Double(SyncSendFile.version)) : .null])
        try mac.write(SyncCollection.chat, chat, ["device": "mac", "kind": "agent", "title": "Menu", "state": "done"])
        let phone = try PhoneSync(seal: seal, options: .init(base: URL(string: "https://sync.test")!, folder: folder,
                                                              device: .init(id: "phone", name: "Test iPhone", model: "iPhone"),
                                                              transport: server))
        phone.start()
        let ready = await until { phone.chat(chat) != nil && phone.macs.contains { $0.id == "mac" } && phone.canAttach(on: "mac") == attachments }
        XCTAssertTrue(ready)
        return (phone, mac)
    }

    private func bytes(_ count: Int, _ seed: UInt8 = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    private func parts(_ phone: PhoneSync) -> [Record] { phone.journal.living(SyncCollection.sendPart) }

    func testPartsAreWrittenBeforeTheSendAndDescribeTheFile() async throws {
        let (phone, mac) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let photo = bytes(100_000), pdf = bytes(1_000, 3)
        let send = try phone.say("which fits?", in: chat, files: [SendUpload(name: "IMG_1.jpg", type: "image/jpeg", data: photo),
                                                                SendUpload(name: "menu.pdf", type: "application/pdf", data: pdf)])
        XCTAssertEqual(send.files.count, 2)
        XCTAssertEqual(send.files[0].parts, ["\(send.id)/0/0", "\(send.id)/0/1", "\(send.id)/0/2"])
        XCTAssertEqual(send.files[0].size, photo.count)
        XCTAssertEqual(send.files[0].digest, SyncSendFile.hex(photo))
        XCTAssertEqual(send.files[1].parts, ["\(send.id)/1/0"])
        XCTAssertEqual(SyncSendFile.read(phone.journal.record(.init(collection: SyncCollection.send, id: send.id))?["files"], send: send.id),
                       send.files, "what the Mac reads is what was written")
        let written = parts(phone)
        XCTAssertEqual(written.count, 4)
        let sendStamp = try XCTUnwrap(phone.journal.record(.init(collection: SyncCollection.send, id: send.id))?.latest)
        for part in written {
            XCTAssertEqual(part["send"]?.string, send.id)
            XCTAssertLessThan(try XCTUnwrap(part.latest), sendStamp, "every part is written before its send")
        }
        // The parts put together are the file.
        let record = { (id: String) in phone.journal.record(.init(collection: SyncCollection.sendPart, id: id)) }
        XCTAssertEqual(send.files[0].assemble(record), photo)
        XCTAssertEqual(send.files[1].assemble(record), pdf)
    }

    func testPartsGoOnceTheSendIsTaken() async throws {
        let (phone, mac) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let send = try phone.say("look", in: chat, files: [SendUpload(name: "a.jpg", type: "image/jpeg", data: bytes(60_000))])
        XCTAssertEqual(parts(phone).count, 2)
        // Waiting, the parts stay.
        phone.sweepSendParts()
        XCTAssertEqual(parts(phone).count, 2)
        let arrived = await until { mac.journal.living(SyncCollection.sendPart).count == 2 && mac.journal.record(.init(collection: SyncCollection.send, id: send.id)) != nil }
        XCTAssertTrue(arrived)
        try mac.write(SyncCollection.send, send.id, ["state": "taken", "took": .number(Date().timeIntervalSince1970)])
        let gone = await until { self.parts(phone).isEmpty }
        XCTAssertTrue(gone, "a taken send's parts are removed")
        let goneThere = await until { mac.journal.living(SyncCollection.sendPart).isEmpty }
        XCTAssertTrue(goneThere, "and the removal reaches the Mac")
    }

    func testPartsGoOnceTheSendFailsOrExpires() async throws {
        let (phone, mac) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let failed = try phone.say("one", in: chat, files: [SendUpload(name: "a.txt", type: "text/plain", data: bytes(10))])
        let expired = try phone.say("two", in: chat, files: [SendUpload(name: "b.txt", type: "text/plain", data: bytes(10, 9))])
        let kept = try phone.say("three", in: chat, files: [SendUpload(name: "c.txt", type: "text/plain", data: bytes(10, 5))])
        XCTAssertEqual(parts(phone).count, 3)
        try mac.write(SyncCollection.send, failed.id, ["state": "failed", "reason": "No room"])
        try mac.write(SyncCollection.send, expired.id, ["state": "expired"])
        let swept = await until { self.parts(phone).map { $0["send"]?.string } == [kept.id] }
        XCTAssertTrue(swept, "only the waiting send keeps its parts")
    }

    func testLimitsRefuseAndWriteNothing() async throws {
        XCTAssertEqual(SendUpload.check(Array(repeating: 1, count: SyncSendFile.mostCount)), nil)
        XCTAssertEqual(SendUpload.check(Array(repeating: 1, count: SyncSendFile.mostCount + 1)), .tooMany)
        XCTAssertEqual(SendUpload.check([SyncSendFile.most + 1]), .tooBig)
        XCTAssertEqual(SendUpload.check([SyncSendFile.most, SyncSendFile.most]), nil)
        XCTAssertEqual(SendUpload.check([SyncSendFile.most, SyncSendFile.most, 1]), .tooMuch)
        let (phone, mac) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let many = (0...SyncSendFile.mostCount).map { SendUpload(name: "\($0).txt", type: "text/plain", data: bytes(4)) }
        XCTAssertThrowsError(try phone.say("all", in: chat, files: many)) { XCTAssertEqual($0 as? SendUpload.Failure, .tooMany) }
        XCTAssertThrowsError(try phone.say("big", in: chat, files: [SendUpload(name: "big.bin", type: "application/octet-stream",
                                                                               data: Data(count: SyncSendFile.most + 1))])) {
            XCTAssertEqual($0 as? SendUpload.Failure, .tooBig)
        }
        XCTAssertTrue(parts(phone).isEmpty)
        XCTAssertTrue(phone.sends().isEmpty)
    }

    func testAMacThatDoesntTakeFilesGetsNone() async throws {
        let (phone, mac) = try await joined(attachments: false)
        defer { phone.stop(); mac.client.stop() }
        XCTAssertFalse(phone.canAttach(chat: chat))
        XCTAssertThrowsError(try phone.say("look", in: chat, files: [SendUpload(name: "a.jpg", type: "image/jpeg", data: bytes(10))])) {
            XCTAssertEqual($0 as? SendUpload.Failure, .unsupported)
        }
        XCTAssertTrue(parts(phone).isEmpty)
        XCTAssertTrue(phone.sends().isEmpty)
        // Words alone still go.
        XCTAssertNoThrow(try phone.say("words", in: chat))
    }

    func testThePickedModelGoesOnlyToAMacThatTakesIt() async throws {
        let (phone, mac) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let unpicked = try phone.say("first", in: chat, model: "opus", effort: "high")
        XCTAssertNil(phone.journal.record(.init(collection: SyncCollection.send, id: unpicked.id))?["model"], "an older Mac gets no model")
        XCTAssertTrue(phone.models(on: "mac").isEmpty)
        let opus = SyncMacModel(cli: "claude", model: "opus", name: "Claude Opus", about: "For long, hard tasks.", efforts: ["low", "high"])
        try mac.write(OpenOnMac.capability, "mac", ModelPick.fields([opus]))
        let offered = await until { phone.models(on: "mac") == [opus] }
        XCTAssertTrue(offered)
        let picked = try phone.say("second", in: chat, model: "opus", effort: "high")
        let record = try XCTUnwrap(phone.journal.record(.init(collection: SyncCollection.send, id: picked.id)))
        XCTAssertEqual(record["model"]?.string, "opus")
        XCTAssertEqual(record["effort"]?.string, "high")
    }

    func testANewChatOfFilesAloneStillSaysItsAgent() async throws {
        let (phone, mac) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let send = try phone.startChat("", on: "mac", clientChat: "local", question: "", agent: .claude,
                                       files: [SendUpload(name: "a.jpg", type: "image/jpeg", data: bytes(10))])
        let record = try XCTUnwrap(phone.journal.record(.init(collection: SyncCollection.send, id: send.id)))
        XCTAssertEqual(record["agentText"]?.string, "")
        XCTAssertNil(ChatCommand.refusal(record), "the Mac takes it")
    }

    func testAPhotoGoesAsAJPEGAtMost2048OnItsLongSide() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let item = try XCTUnwrap(AttachmentPrep.photo(try XCTUnwrap(big.pngData()), name: "IMG_0001.HEIC"))
        XCTAssertEqual(item.upload.name, "IMG_0001.jpg")
        XCTAssertEqual(item.upload.type, "image/jpeg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(item.upload.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 1536)
        XCTAssertNotNil(item.thumbnail)
        // A small photo isn't made larger.
        let small = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { _ in }
        let made = try XCTUnwrap(AttachmentPrep.photo(try XCTUnwrap(small.pngData()), name: "small.png"))
        let smallProps = CGImageSourceCreateWithData(made.upload.data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        XCTAssertEqual(smallProps?[kCGImagePropertyPixelWidth] as? Int, 300)
    }

    func testYourBubbleKeepsWhatTheSendSaidOfItsFiles() throws {
        let head = try XCTUnwrap(SyncChat(Record(collection: SyncCollection.chat, id: chat,
                                                 fields: ["device": "mac", "kind": "agent", "updated": .number(1), "state": "done"])))
        let file = SyncSendFile(name: "menu.pdf", type: "application/pdf", size: 1_000, digest: "abc", parts: ["s/0/0"])
        let send = try XCTUnwrap(SyncSend(Record(collection: SyncCollection.send, id: "s",
                                                 fields: ["device": "mac", "chat": .string(chat), "at": .number(2), "files": .array([file.value])])))
        let mapped = SyncMapping.chat(head, items: [], sends: [send], macAsleep: false, old: nil)
        let mine = try XCTUnwrap(mapped.messages.first { $0.role == .you })
        XCTAssertEqual(mine.text, "", "files alone are a message of their own")
        XCTAssertEqual(mine.files, [Message.File(name: "menu.pdf", type: "application/pdf", size: 1_000, digest: "abc")])
    }
}
