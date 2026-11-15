import XCTest

/// Chat Info on a long chat (chat.long: 300 messages, 30 sites): opening and
/// closing it, and Rename's commit. The first repeat reads the chat's tabs,
/// the next ones open with what was kept.
extension PerfTests {
    func testChatInfoLong() throws { try measure("chatInfoLong") }
    func testChatInfoRename() throws { try measure("chatInfoRename") }
}
