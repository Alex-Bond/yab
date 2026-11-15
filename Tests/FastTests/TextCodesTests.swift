import Foundation
import Testing
@testable import Fast

// Codes in texts as messages_code gives them (AgentFiles.codes), from a
// test world's phone: newest first, only the last minutes, the code found
// in each text.
@Suite(.serialized)
struct TextCodesTests {
    @Test func newestFirstAndOnlyRecent() throws {
        AgentFiles.fakeTexts.withLock {
            $0 = [(text: "Chase: your one-time code is 559013. Don't share it.", at: Date().addingTimeInterval(-60), from: "+1 555 200 0100"),
                  (text: "Cinder: 482-913 is your sign-in code.", at: Date(), from: "+1 555 010 0147"),
                  (text: "Old: 111111", at: Date().addingTimeInterval(-3600), from: "x")]
        }
        defer { AgentFiles.fakeTexts.withLock { $0 = nil } }
        let lines = try AgentFiles.codes(minutes: 10).get()
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("482-913 · from +1 555 010 0147, just now"))
        #expect(lines[1].hasPrefix("559013 · from +1 555 200 0100, 1 min ago"))
    }

    @Test func aTextWithNoCodeIsLeftOut() throws {
        AgentFiles.fakeTexts.withLock { $0 = [(text: "See you at 5!", at: Date(), from: "Anna")] }
        defer { AgentFiles.fakeTexts.withLock { $0 = nil } }
        #expect(try AgentFiles.codes(minutes: 10).get().isEmpty)
    }
}
