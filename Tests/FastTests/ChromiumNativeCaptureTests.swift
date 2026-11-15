import Testing
import YabCoreClient
@testable import Fast

struct ChromiumNativeCaptureTests {
    private func snapshot() -> [String: JSONValue] {
        var p: [String: JSONValue] = ["version": .number(1), "scope": .string("browser"), "known": .bool(true),
            "profile": .string("fixture-profile"), "browserId": .number(3), "token": .string("capture-token"),
            "primaryDocument": .string("native-document"), "primaryFrameId": .string("native-frame"),
            "actions": .array([.string("stopUserMedia"), .string("stopScreen")])]
        for key in ["camera", "microphone", "screen", "tabCapture", "window", "display", "allScreens", "mirrored", "videoPiP", "documentPiP"] { p[key] = .bool(false) }
        return p
    }

    @Test func everyAuthoritativeActivityPreventsIdle() throws {
        #expect(try #require(ChromiumNativeCapture(snapshot(), profile: "fixture-profile")).idle)
        for key in ["camera", "microphone", "screen", "tabCapture", "window", "display", "allScreens", "mirrored", "videoPiP", "documentPiP"] {
            var p = snapshot(); p[key] = .bool(true)
            #expect(try #require(ChromiumNativeCapture(p, profile: "fixture-profile")).idle == false)
            p[key] = .string("false")
            #expect(ChromiumNativeCapture(p, profile: "fixture-profile") == nil)
        }
    }

    /// An event's `tab` names the page, so it can never be the capture flag.
    @Test func anEventsOwnTabIdLeavesItsCaptureRead() throws {
        var p = snapshot()
        p["camera"] = .bool(true); p["microphone"] = .bool(true)
        p["tab"] = .string("tab-3")
        let capture = try #require(ChromiumNativeCapture(p, profile: "fixture-profile"))
        #expect(capture.camera && capture.microphone && !capture.screen)
    }

    @Test func missingAndForeignProofCannotAuthorizeIdle() {
        #expect(ChromiumNativeCapture(snapshot(), profile: "foreign") == nil)
        for key in ["known", "primaryDocument", "primaryFrameId", "token", "camera", "documentPiP", "browserId"] {
            var p = snapshot(); p.removeValue(forKey: key)
            #expect(ChromiumNativeCapture(p, profile: "fixture-profile") == nil)
        }
        var p = snapshot(); p["known"] = .bool(false)
        #expect(ChromiumNativeCapture(p, profile: "fixture-profile") == nil)
    }

    @Test func stopAndLifecycleKeepExactNativeIdentity() throws {
        let capture = try #require(ChromiumNativeCapture(snapshot(), profile: "fixture-profile"))
        #expect(capture.lifecycleParameters == ["captureToken": .string("capture-token"), "captureDocument": .string("native-document")])
        #expect(capture.stopParameters(kind: "screen") == ["profile": .string("fixture-profile"), "token": .string("capture-token"), "kind": .string("screen")])
        #expect(capture.stopParameters(kind: "userMedia") == ["profile": .string("fixture-profile"), "token": .string("capture-token"), "kind": .string("userMedia")])
        #expect(capture.stopParameters(kind: "cameraMute") == nil)
        #expect(capture.stopParameters(kind: "microphone") == nil)
        #expect(capture.stopParameters(kind: "camera") == nil)
        #expect(capture.stopParameters(kind: "resumeUserMedia") == nil)
        var unsupported = snapshot(); unsupported["actions"] = .array([.string("stopScreen")])
        #expect(try #require(ChromiumNativeCapture(unsupported, profile: "fixture-profile")).stopParameters(kind: "userMedia") == nil)
    }
}
