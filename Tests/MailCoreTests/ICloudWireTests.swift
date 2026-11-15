import Foundation
import Testing
@testable import MailCore

// #441: iCloud's real servers, reached the way Add Account reaches them,
// with a made-up name and password nobody has, so they can only refuse:
// TLS, STARTTLS on 587 and the refusal read as a password's. It reaches
// Apple, so only when asked: YAB_MAIL_WIRE=1. evals/mail/icloud_wire.py
// prints the same exchange line by line.
@Suite struct ICloudWireTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_MAIL_WIRE"] == "1"))
    func iCloudsRealServersRefuseAMadeUpPasswordAsAPassword() async throws {
        let provider = try #require(MailKnownProviders.by(domain: "icloud.com"))
        let address = "yab-wire-\(UUID().uuidString.prefix(8).lowercased())@icloud.com"
        let probe = await MailProbe.run(address, setup: provider.setup(for: address), password: "abcd-efgh-ijkl-mnop")
        #expect(probe.imap?.tls == "ok" && probe.imap?.auth == "rejected" && probe.imap?.hint == "appPasswordRequired", "\(probe.json)")
        #expect(probe.smtp?.tls == "ok" && probe.smtp?.auth == "rejected", "\(probe.json)")
    }
}
