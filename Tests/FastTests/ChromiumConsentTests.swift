import Testing
import YabCoreClient
@testable import Fast

struct ChromiumConsentTests {
    private func fields() -> [String: JSONValue] {
        let manifest = "{\"manifest_version\":3,\"name\":\"Fixture\",\"version\":\"1\"}"
        return ["request": .string("unique-token"), "profile": .string("profile-a"),
                "operation": .string("install"), "extensionId": .string(String(repeating: "a", count: 32)),
                "displayName": .string("Fixture"), "manifest": .string(manifest),
                "manifestSHA256": .string(ChromiumConsentRequest.digest(manifest)),
                "warnings": .array([.object(["text": .string("Read your browsing history"), "details": .string("Chrome's exact detail")])])]
    }

    @Test func verifiedManifestAndNativeWarningDetailsSurviveParsing() throws {
        let ask = try #require(ChromiumConsentRequest.parse(fields()))
        #expect(ask.warnings.first?.text == "Read your browsing history")
        #expect(ask.warnings.first?.details == "Chrome's exact detail")
        #expect(ask.profile == "profile-a")
    }

    @Test func anUnverifiedOrChangedManifestCannotReachTheReview() {
        var p = fields()
        p["manifest"] = .string("{}")
        #expect(ChromiumConsentRequest.parse(p) == nil)
        p = fields(); p["manifestSHA256"] = nil
        #expect(ChromiumConsentRequest.parse(p) == nil)
        p = fields(); p["warnings"] = nil
        #expect(ChromiumConsentRequest.parse(p) == nil)
        p = fields(); p["operation"] = .string("unknown")
        #expect(ChromiumConsentRequest.parse(p) == nil)
    }

    @MainActor @Test func anAnswerKeepsAllThreeNativeIdentities() throws {
        let ask = try #require(ChromiumConsentRequest.parse(fields()))
        let reply = ChromiumConsent.reply(ask, accept: false)
        #expect(reply["request"] == .string("unique-token"))
        #expect(reply["extension"] == fields()["extensionId"])
        #expect(reply["profile"] == .string("profile-a"))
        #expect(reply["accept"] == .bool(false))
    }

    @Test func uninstallNeedsItsIdentityButNoManifest() {
        var p = fields()
        p["operation"] = .string("uninstall")
        p["manifest"] = nil; p["manifestSHA256"] = nil; p["warnings"] = nil
        #expect(ChromiumConsentRequest.parse(p)?.operation == "uninstall")
        p["extensionId"] = .string("wrong")
        #expect(ChromiumConsentRequest.parse(p) == nil)
    }
}
