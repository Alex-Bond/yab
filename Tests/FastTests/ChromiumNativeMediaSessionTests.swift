import AppKit
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumNativeMediaSessionTests {
    private func snapshot() -> [String: JSONValue] {
        ["version": .number(1), "available": .bool(true), "profile": .string("fixture-profile"),
         "browserId": .number(7), "token": .string("native-session-token"), "document": .string("native-document"),
         "frameId": .string("native-frame"), "session": .string("native-session"), "playback": .string("playing"),
         "hideMetadata": .bool(false), "title": .string("Native track"), "artist": .string("Artist"),
         "actions": .array(["play", "pause", "seek", "next", "toggleMicrophone", "toggleCamera", "hangUp"].map(JSONValue.string)),
         "position": .object(["position": .number(9), "duration": .number(120), "rate": .number(1)]),
         "reportedMicrophone": .string("muted"), "reportedCamera": .string("on"), "reportedPiP": .bool(true)]
    }

    @Test func nativeActionsCarryExactOwnerAndToken() throws {
        let value = try #require(ChromiumNativeMediaSession(snapshot(), profile: "fixture-profile"))
        #expect(value.parameters(action: "toggle") == ["profile": .string("fixture-profile"), "token": .string("native-session-token"), "action": .string("pause")])
        #expect(value.parameters(action: "seekto", seconds: 42)?["seconds"] == .number(42))
        #expect(value.parameters(action: "toggleMicrophone")?["action"] == .string("toggleMicrophone"))
        #expect(value.parameters(action: "toggleCamera") != nil)
        #expect(value.parameters(action: "hangUp") != nil)
        #expect(value.parameters(action: "previous") == nil)
        #expect(value.parameters(action: "seekto", seconds: -.infinity) == nil)
        #expect(value.parameters(action: "seekto", seconds: 121) == nil)
        #expect(value.parameters(action: "pause", seconds: 1) == nil)
    }

    @Test func foreignIncompleteAndRetiredSnapshotsAreRefused() {
        #expect(ChromiumNativeMediaSession(snapshot(), profile: "foreign-profile") == nil)
        for key in ["token", "document", "frameId", "session", "browserId", "hideMetadata"] {
            var value = snapshot(); value.removeValue(forKey: key)
            #expect(ChromiumNativeMediaSession(value, profile: "fixture-profile") == nil)
        }
        var value = snapshot(); value["available"] = .bool(false)
        #expect(ChromiumNativeMediaSession(value, profile: "fixture-profile") == nil)
    }

    @Test func nativeMetadataPrivacyAndReportedCaptureStaySeparate() throws {
        var value = snapshot(); value["hideMetadata"] = .bool(true)
        let session = try #require(ChromiumNativeMediaSession(value, profile: "fixture-profile"))
        #expect(session.title.isEmpty && session.artist.isEmpty && session.album.isEmpty)
        #expect(session.reportedMicrophone == "muted")
        #expect(session.reportedCamera == "on")
        #expect(session.reportedPiP)
        value["position"] = .object(["position": .number(121), "duration": .number(120)])
        #expect(ChromiumNativeMediaSession(value, profile: "fixture-profile")?.position == nil)
    }

    @Test func reportsCannotClaimCaptureAndRevocationDoesNotUseDOMFallback() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab, profile: "fixture-profile")
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        var renderer = ChromiumMediaReport()
        renderer.session = .init(title: "Old renderer metadata", artist: "", album: "")
        page.receiveNativeAudible(renderer)
        page.receiveNativeMediaSession(snapshot())
        #expect(page.media.nativeSession?.token == "native-session-token")
        #expect(page.captureStatus == PageCaptureStatus(camera: .none, microphone: .none, screen: .none))
        #expect(page.sleepActivityUnavailable)
        #expect(page.media.report.session?.title == "Native track")
        #expect(page.remoteID == nil)
        var revoked = snapshot(); revoked["available"] = .bool(false)
        page.receiveNativeMediaSession(revoked)
        #expect(page.media.nativeSession == nil)
        #expect(page.media.report.session == nil)
        #expect(page.media.report.hideMetadata)
        #expect(page.media.rawReport.session?.title == "Old renderer metadata")
        #expect(page.routeNativeMediaAction("play"))
        #expect(page.remoteID == nil)
    }

    @Test func nativeArtworkUsesLargestDeclaredSize() throws {
        var value = snapshot()
        value["artwork"] = .array([96, 1280, 512].map { side in
            .object(["src": .string("https://fixture.test/\(side).png"),
                     "sizes": .array([.object(["width": .number(Double(side)), "height": .number(Double(side))])])])
        })
        let session = try #require(ChromiumNativeMediaSession(value, profile: "fixture-profile"))
        #expect(session.artwork.first?.lastPathComponent == "1280.png")
    }

    /// Row 3105: a google.com search's muted previews and a page's idle
    /// MediaSession showed Paused and Play, and took macOS Now Playing.
    @Test func onlyAHeardDocumentHasSomethingToPlay() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab, profile: "fixture-profile")
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        var muted = ChromiumMediaReport()
        muted.playing = true
        muted.media = .init(time: 2, duration: 10, paused: false, muted: true, video: true)
        page.receiveNativeAudible(muted)
        #expect(!page.media.report.heard)
        var idle = snapshot(); idle["playback"] = .string("paused")
        page.receiveNativeMediaSession(idle)
        #expect(page.media.report.session != nil && !page.media.report.heard)
        var loud = muted; loud.audible = true; loud.media?.muted = false
        page.receiveNativeAudible(loud)
        #expect(page.media.report.heard)
        // Paused afterwards: still something to play again.
        var paused = loud; paused.audible = false; paused.playing = false; paused.media?.paused = true
        page.receiveNativeAudible(paused)
        #expect(page.media.report.heard)
        // Another document of the tab starts unheard.
        var next = snapshot(); next["document"] = .string("next-document"); next["playback"] = .string("paused")
        page.receiveNativeMediaSession(next)
        #expect(!page.media.report.heard)
        // So does one with no media and no session left.
        page.receiveNativeAudible(loud)
        #expect(page.media.report.heard)
        var revoked = snapshot(); revoked["available"] = .bool(false)
        page.receiveNativeMediaSession(revoked)
        page.receiveNativeAudible(ChromiumMediaReport())
        #expect(!page.media.report.heard)
    }

    @Test func nativeArtworkIsBoundedAndNeverFallsBackAcrossPrivacy() throws {
        var value = snapshot()
        let unsafe = ["file:///private/secret.png", "https://user:password@fixture.test/art.png"]
        let safe = (0..<12).map { "https://fixture.test/art-\($0).png" }
        value["artwork"] = .array((unsafe + safe).map { .object(["src": .string($0)]) })
        let session = try #require(ChromiumNativeMediaSession(value, profile: "fixture-profile"))
        #expect(session.artwork.map(\.absoluteString) == Array(safe.prefix(6)))
        value["hideMetadata"] = .bool(true)
        #expect(try #require(ChromiumNativeMediaSession(value, profile: "fixture-profile")).artwork.isEmpty)
        value["hideMetadata"] = .bool(false)
        value["artwork"] = .array([.object(["src": .string("data:image/png;base64," + String(repeating: "A", count: 8192))])])
        #expect(try #require(ChromiumNativeMediaSession(value, profile: "fixture-profile")).artwork.isEmpty)
    }

    @Test func nativeOSCommandsRequireOriginalSupportedActionsAndValidSeek() throws {
        var value = snapshot()
        value["actions"] = .array([.string("pause"), .string("seek")])
        #expect(try #require(ChromiumNativeMediaSession(value, profile: "fixture-profile")).remoteCommands == ["pause", "toggle", "seekto"])
        value["playback"] = .string("paused")
        value.removeValue(forKey: "position")
        #expect(try #require(ChromiumNativeMediaSession(value, profile: "fixture-profile")).remoteCommands == ["pause"])
    }

    @Test func webKitPlaybackCannotBeStolenByAnUnchangedOrPausedCEFSession() {
        var ownership = ChromiumPlaybackOwnership<Int>()
        let initialPlay = ownership.receive(1, playing: true, metadataAllowed: true)
        #expect(initialPlay)
        ownership.cede() // Original WebKit native playback starts.
        let unchanged = ownership.receive(1, playing: true, metadataAllowed: true)
        #expect(!unchanged)
        let anotherPaused = ownership.receive(2, playing: false, metadataAllowed: true)
        #expect(!anotherPaused)
        let sourcePaused = ownership.receive(1, playing: false, metadataAllowed: true)
        #expect(!sourcePaused)
        let newPlay = ownership.receive(1, playing: true, metadataAllowed: true)
        #expect(newPlay)
        let privateMetadata = ownership.receive(1, playing: true, metadataAllowed: false)
        #expect(!privateMetadata)
        let metadataOnly = ownership.receive(1, playing: true, metadataAllowed: true)
        #expect(!metadataOnly)
        let newSession = ownership.receive(1, playing: true, metadataAllowed: true, sessionChanged: true)
        #expect(newSession)
        ownership.end(1)
        let afterEnd = ownership.receive(1, playing: true, metadataAllowed: true)
        #expect(afterEnd)
    }

}
