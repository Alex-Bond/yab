import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// The engine against a Gmail in memory where the app's side comes in too
// (compose, rich text, sending, files): MailSyncTests' world, served at a
// host of its own so the two suites run beside each other.

@Suite(.serialized)
struct MailSyncAppTests {
    let now = Date()

    func world() -> (MailStore, MailGmail, FakeGmail) {
        MailWorld.make(host: "sync-app-\(UUID().uuidString.prefix(8)).test")
    }

    func seed(_ fake: FakeGmail) { MailWorld.seed(fake, now: now) }
}
