import Foundation
import Testing
import YabCoreClient
@testable import Fast

@MainActor struct ChromiumRemoteReadTests {
    private func receipt() -> [String: JSONValue] {
        var policy: [String: JSONValue] = ["immutable": .bool(true), "fullTree": .bool(true), "httpGetOnly": .bool(true),
            "noRequestBody": .bool(true), "noURLCredentials": .bool(true), "noPopups": .bool(true), "noDownloads": .bool(true),
            "noDialogs": .bool(true), "noAuthPrompts": .bool(true), "noClientCertificates": .bool(true), "noPermissions": .bool(true),
            "noCapture": .bool(true), "noFileChooser": .bool(true), "autoplayLocked": .bool(true),
            "workerIsolated": .bool(true), "extensionIsolated": .bool(true)]
        policy["version"] = .number(1); policy["mode"] = .string("http-read")
        policy["cookies"] = .string("captured-profile")
        return ["tab": .string("owned-native-browser"), "profile": .string("captured-public-profile"), "private": .bool(false),
                "owner": .string("request-owner"), "session": .string("native-session"), "token": .string("opaque-policy-token"),
                "policy": .object(policy), "state": .object(["url": .string("https://owned.test/read"), "title": .string("Owned"),
                    "loading": .bool(false), "canGoBack": .bool(false), "canGoForward": .bool(false), "document": .string("original-native-document")])]
    }

    private func parse(_ value: [String: JSONValue]) -> ChromiumRemoteRead.Receipt? {
        ChromiumRemoteRead.Receipt(.object(value), profile: "captured-public-profile", owner: "request-owner", session: "native-session")
    }

    @Test func autoplayLockCannotStandInForTheFullNativePolicy() throws {
        var value = receipt()
        #expect(parse(value)?.state.document == "original-native-document")
        value["policy"] = .object(["version": .number(1), "mode": .string("http-read"),
                                    "cookies": .string("captured-profile"), "autoplayLocked": .bool(true)])
        #expect(parse(value) == nil)
        // The source boundary remains unavailable until worker and extension
        // isolation are implemented. An otherwise complete receipt cannot
        // substitute missing/false/string-valued guarantees for those fields.
        for key in ["workerIsolated", "extensionIsolated", "fullTree", "noPermissions", "noDownloads", "noRequestBody"] {
            for weakened in [JSONValue.null, .bool(false), .string("true"), .number(1)] {
                var value = receipt(); var policy = try #require(value["policy"]?.object)
                policy[key] = weakened; value["policy"] = .object(policy)
                #expect(parse(value) == nil)
            }
        }
    }

    @Test func policyCannotChangeCookieContextOrIntroducePrivateAndForeignOwners() throws {
        for (key, replacement) in [("profile", JSONValue.string("other-profile")), ("owner", .string("other-request")),
                                    ("session", .string("other-session")), ("private", .bool(true)),
                                    ("token", .string("")), ("tab", .string(String(repeating: "x", count: 257)))] {
            var value = receipt(); value[key] = replacement
            #expect(parse(value) == nil)
        }
        for (key, replacement) in [("cookies", JSONValue.string("credentialless")), ("mode", .string("ordinary")), ("version", .number(2))] {
            var value = receipt(); var policy = try #require(value["policy"]?.object)
            policy[key] = replacement; value["policy"] = .object(policy)
            #expect(parse(value) == nil)
        }
        let identity = try #require(parse(receipt())?.identity)
        for key in ["tab", "token", "profile", "owner", "session"] {
            var changed = receipt(); changed[key] = .string("different-original-identity")
            #expect(!identity.matches(.object(changed)))
        }
    }

    @Test func nativeStateRejectsNonHTTPAndEmbeddedCredentialsWithoutInventingDocumentIdentity() throws {
        for address in ["file:///tmp/secret", "chrome-extension://owner/options.html", "https://name:secret@owned.test/", "javascript:alert(1)"] {
            var value = receipt(); var state = try #require(value["state"]?.object)
            state["url"] = .string(address); value["state"] = .object(state)
            #expect(parse(value) == nil)
        }
        var value = receipt(); var state = try #require(value["state"]?.object)
        state["url"] = .string("about:blank"); state["document"] = .null; value["state"] = .object(state)
        let blank = try #require(parse(value))
        #expect(blank.state.document == nil)
        #expect(ChromiumRemoteRead.State.httpURL(blank.state.url) == nil)
        state["document"] = .string(""); value["state"] = .object(state)
        #expect(parse(value) == nil)
    }
}
