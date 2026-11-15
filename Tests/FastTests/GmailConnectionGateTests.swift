import AppKit
import AuthenticationServices
import Foundation
import ObjectiveC
import Testing
@testable import Fast
@testable import MailCore

/// Actual canonical Connect, stopped at the native start boundary. No original
/// AS start is forwarded; standalone filtered golden only, with no Google requests or tokens.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YAB_GOOGLE_CLIENT_ID"] == "gmail-gate-fixture.apps.googleusercontent.com" && ProcessInfo.processInfo.environment["YAB_GOOGLE_CLIENT_SECRET"] == ""))
struct GmailConnectionGateTests {
    private static let gmail = "existing@mail.fixture.test"
    private static let imap = "imap@mail.fixture.test"
    private static let notice = "New Gmail accounts connect with an app password. Open Settings > Mail > Add Account and choose Google Account."

    @MainActor private final class Starts { var count = 0; var answer = false }

    @MainActor private final class Fixture {
        let center: MailCenter
        let browser: Browser
        let starts: Starts
        private let method: Method
        private let original: IMP
        private let replacement: IMP
        private let saved: [(String, Any?)]

        init() throws {
            try #require(Store.testing && Store.world != nil)
            try #require(MailKeychain.service != "Fast Mail")
            try #require(MailClient.configured?.id == "gmail-gate-fixture.apps.googleusercontent.com")
            try #require(MailClient.configured?.secret.isEmpty == true)
            let method = try #require(class_getInstanceMethod(ASWebAuthenticationSession.self,
                                                             #selector(ASWebAuthenticationSession.start)))
            self.method = method
            original = method_getImplementation(method)
            let keys = ["mail.accounts", "mail.provider.\(GmailConnectionGateTests.gmail)", "mail.provider.\(GmailConnectionGateTests.imap)", MailRevoke.key]
            saved = keys.map { ($0, Store.settings.object(forKey: $0)) }
            Store.settings.set([GmailConnectionGateTests.gmail, GmailConnectionGateTests.imap], forKey: "mail.accounts")
            Store.settings.set(MailProviderKind.gmail.rawValue, forKey: "mail.provider.\(GmailConnectionGateTests.gmail)")
            Store.settings.set(MailProviderKind.imap.rawValue, forKey: "mail.provider.\(GmailConnectionGateTests.imap)")
            Store.settings.set([], forKey: MailRevoke.key)
            _ = NSApplication.shared
            center = MailCenter.shared
            browser = Browser(windowID: UUID())
            let counts = Starts()
            starts = counts
            let block: @convention(block) (AnyObject) -> Bool = { _ in
                MainActor.assumeIsolated { counts.count += 1; return counts.answer }
            }
            replacement = imp_implementationWithBlock(block)
            method_setImplementation(method, replacement)
        }

        func requireReady() throws {
            try #require(center.accounts == [GmailConnectionGateTests.gmail, GmailConnectionGateTests.imap])
            try #require(center.engines.isEmpty && !center.connecting)
            try #require(unsafeBitCast(method_getImplementation(method), to: UInt.self)
                         == unsafeBitCast(replacement, to: UInt.self))
        }

        func expectNotice(_ results: [Result<String, Error>]) {
            #expect(results.count == 1)
            if let first = results.first, case .failure(let error) = first {
                #expect(error as? MailTrouble == .offline(GmailConnectionGateTests.notice))
            } else { Issue.record("A blocked connection must fail, never succeed or remain pending") }
            #expect(browser.toaster.shown && browser.toaster.words == String(GmailConnectionGateTests.notice.dropLast()))
        }

        func expectBlocked(hint: String? = nil, expected: String? = nil) {
            var results: [Result<String, Error>] = []
            // Existing API shape on both trees; never inspect candidate's Bool.
            center.connect(in: browser, hint: hint, expectedAccount: expected) { results.append($0) }
            #expect(starts.count == 0)
            expectNotice(results)
            #expect(!center.connecting && center.engines.isEmpty)
            #expect(center.accounts == [GmailConnectionGateTests.gmail, GmailConnectionGateTests.imap])
        }

        func close() {
            center.cancelConnect(in: browser)
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
            for tab in browser.everyTab { tab.close() }
            for (key, value) in saved {
                if let value { Store.settings.set(value, forKey: key) }
                else { Store.settings.removeObject(forKey: key) }
            }
        }
    }

    private func isolated(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.requireReady()
        try body(fixture)
    }

    @Test func newGmailIsBlockedBeforeOAuthFactory() throws {
        try isolated { $0.expectBlocked() }
    }

    @Test func hintOfExistingAccountDoesNotAuthorizeNewGmail() throws {
        try isolated { $0.expectBlocked(hint: GmailConnectionGateTests.gmail) }
    }

    @Test func differentExpectedAccountIsBlocked() throws {
        try isolated { $0.expectBlocked(hint: GmailConnectionGateTests.gmail, expected: "new@mail.fixture.test") }
    }

    @Test func nonGmailAccountCannotAuthorizeGoogleOAuth() throws {
        try isolated { $0.expectBlocked(hint: GmailConnectionGateTests.imap, expected: GmailConnectionGateTests.imap) }
    }

    @Test func exactExistingGmailAccountCanReauthenticate() throws {
        try isolated { fixture in
            var results: [Result<String, Error>] = []
            fixture.center.connect(in: fixture.browser, hint: "different@mail.fixture.test",
                                   expectedAccount: " \nEXISTING@MAIL.FIXTURE.TEST \n") { results.append($0) }
            #expect(fixture.starts.count == 1)
            #expect(results.count == 1)
            if let first = results.first, case .failure(let error) = first {
                #expect(error as? MailTrouble == .offline("The Mac's sign-in sheet didn't open"))
            } else { Issue.record("The inert native start must return the existing failure path") }
            #expect(!fixture.center.connecting && fixture.center.engines.isEmpty)
        }
    }

    @Test func blockedNewRequestPreservesExistingReauthentication() throws {
        try isolated { fixture in
            fixture.starts.answer = true // Inert pending session; original start is never called.
            let existing = UUID()
            var old: [Result<String, Error>] = []
            fixture.center.connect(in: fixture.browser, expectedAccount: GmailConnectionGateTests.gmail, attempt: existing) { old.append($0) }
            try #require(fixture.center.connecting && fixture.starts.count == 1 && old.isEmpty)
            let shown = fixture.center.signInShown
            var blocked: [Result<String, Error>] = []
            fixture.center.connect(in: fixture.browser, hint: GmailConnectionGateTests.gmail) { blocked.append($0) }
            #expect(fixture.starts.count == 1)
            #expect(old.isEmpty)
            fixture.expectNotice(blocked)
            #expect(fixture.center.connecting && fixture.center.signInShown == shown)
            #expect(fixture.center.engines.isEmpty)
        }
    }

    @Test func explicitCancelAndStaleAttemptDoNotAffectReplacement() throws {
        try isolated { fixture in
            fixture.starts.answer = true
            let oldAttempt = UUID(), replacementAttempt = UUID()
            var old: [Result<String, Error>] = []
            fixture.center.connect(in: fixture.browser, expectedAccount: GmailConnectionGateTests.gmail, attempt: oldAttempt) { old.append($0) }
            try #require(fixture.center.connecting && fixture.starts.count == 1)
            fixture.center.cancelConnect(in: fixture.browser, attempt: oldAttempt)
            #expect(!fixture.center.connecting && old.count == 1)
            var replacement: [Result<String, Error>] = []
            fixture.center.connect(in: fixture.browser, expectedAccount: GmailConnectionGateTests.gmail,
                                   attempt: replacementAttempt) { replacement.append($0) }
            try #require(fixture.center.connecting && fixture.starts.count == 2)
            fixture.center.cancelConnect(in: fixture.browser, attempt: oldAttempt)
            #expect(fixture.center.connecting && replacement.isEmpty && old.count == 1)
            fixture.center.cancelConnect(in: fixture.browser, attempt: replacementAttempt)
            fixture.center.cancelConnect(in: fixture.browser, attempt: replacementAttempt)
            #expect(!fixture.center.connecting && replacement.count == 1 && fixture.starts.count == 2)
            for result in old + replacement {
                if case .success = result { Issue.record("Cancellation must never report success") }
            }
            #expect(fixture.center.engines.isEmpty)
        }
    }
}
