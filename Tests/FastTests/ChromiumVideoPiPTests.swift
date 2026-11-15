import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor
struct ChromiumVideoPiPTests {
    private func original() -> [String: JSONValue] {
        ["version": .number(1), "kind": .string("video"), "active": .bool(true), "profile": .string("source"),
         "browserId": .number(17), "token": .string("original-player"), "document": .string("child-document"),
         "frameId": .string("original-child-frame"), "nativeSurface": .string("original-overlay"),
         "surfaceReady": .bool(true), "contextId": .number(170), "pixelWidth": .number(1280), "pixelHeight": .number(720),
         "scale": .number(2), "videoX": .number(10), "videoY": .number(20), "videoWidth": .number(600), "videoHeight": .number(300),
         "naturalWidth": .number(1920), "naturalHeight": .number(1080), "controlsKnown": .bool(true),
         "paused": .bool(false), "muted": .bool(true), "position": .number(30), "duration": .number(120), "rate": .number(1.5),
         "canSeek": .bool(true), "canRate": .bool(true), "captionsAvailable": .bool(true), "captionsEnabled": .bool(false)]
    }
    @Test func originalChildPlayerAndNativeCropSurviveTheWire() throws {
        let state = try #require(ChromiumVideoPiPState(original(), profile: "source"))
        #expect(state.token == "original-player" && state.document == "child-document" && state.frame == "original-child-frame")
        #expect(state.browserID == 17 && state.surfaceIdentity == "original-overlay")
        #expect(state.canvas == CGSize(width: 640, height: 360))
        #expect(state.crop == CGRect(x: 10, y: 20, width: 600, height: 300))
        #expect(state.natural == CGSize(width: 1920, height: 1080))
        let head = try #require(state.playhead)
        #expect(head.through == 0.25 && head.time == 30 && head.length == 120 && head.playing && head.muted && head.rate == 1.5)
    }
    @Test func foreignProfileOrMissingOriginalNativeIdentityCannotShowAPicture() {
        #expect(ChromiumVideoPiPState(original(), profile: "another-sign-in") == nil)
        for key in ["token", "document", "frameId", "nativeSurface", "contextId", "browserId"] {
            var value = original(); value.removeValue(forKey: key)
            #expect(ChromiumVideoPiPState(value, profile: "source") == nil, "missing original \(key)")
        }
        for key in ["active", "surfaceReady"] {
            var value = original(); value[key] = .bool(false)
            #expect(ChromiumVideoPiPState(value, profile: "source") == nil)
        }
    }
    @Test func invalidContextAndOutOfWidgetCropCannotBecomeAWholePageFallback() {
        for (key, bad) in [("contextId", Double.nan), ("contextId", -1), ("contextId", 1.5),
                           ("contextId", Double(UInt32.max) + 1), ("scale", 0), ("pixelWidth", Double.infinity),
                           ("videoX", -1), ("videoWidth", 800), ("videoY", 100), ("naturalHeight", 0)] {
            var value = original(); value[key] = .number(bad)
            #expect(ChromiumVideoPiPState(value, profile: "source") == nil, "invalid \(key)=\(bad)")
        }
    }
    @Test func unknownControlsCannotInventPlaybackAndMissingDurationCannotInventSeekRange() throws {
        var value = original(); value["controlsKnown"] = .bool(false)
        value.removeValue(forKey: "paused"); value.removeValue(forKey: "position")
        #expect(try #require(ChromiumVideoPiPState(value, profile: "source")).playhead == nil)
        value = original(); value.removeValue(forKey: "duration")
        let state = try #require(ChromiumVideoPiPState(value, profile: "source"))
        #expect(state.duration == nil && state.playhead?.length == 0)
        value["controlsKnown"] = .string("true")
        #expect(ChromiumVideoPiPState(value, profile: "source") == nil)
    }
}
