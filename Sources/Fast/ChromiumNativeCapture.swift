import Foundation
import YabCoreClient

/// Authoritative browser-subtree capture/PiP inventory. This is never
/// populated from MediaSession's site-reported flags or renderer JavaScript.
struct ChromiumNativeCapture: Equatable {
    let profile: String
    let token: String
    let document: String
    let camera: Bool
    let microphone: Bool
    /// This page shows something (getDisplayMedia).
    let screen: Bool
    /// Something shows this page.
    let mirrored: Bool
    let videoPiP: Bool
    let documentPiP: Bool
    let actions: Set<String>
    let idle: Bool

    init?(_ p: [String: JSONValue], profile expected: String) {
        guard p["version"] == .number(1), p["scope"] == .string("browser"), p["known"] == .bool(true),
              p["profile"]?.string == expected,
              let token = p["token"]?.string, !token.isEmpty, token.count <= 256,
              let document = p["primaryDocument"]?.string, !document.isEmpty, document.count <= 256,
              let frame = p["primaryFrameId"]?.string, !frame.isEmpty,
              let browser = p["browserId"]?.number, browser.isFinite, browser > 0,
              case .array(let actions)? = p["actions"], actions.count <= 16 else { return nil }
        var flags: [String: Bool] = [:]
        for key in ["camera", "microphone", "screen", "tabCapture", "window", "display", "allScreens", "mirrored", "videoPiP", "documentPiP"] {
            guard case .bool(let value)? = p[key] else { return nil }
            flags[key] = value
        }
        profile = expected; self.token = token; self.document = document
        camera = flags["camera"]!; microphone = flags["microphone"]!
        screen = ["screen", "tabCapture", "window", "display", "allScreens"].contains { flags[$0] == true }
        mirrored = flags["mirrored"]!
        videoPiP = flags["videoPiP"]!; documentPiP = flags["documentPiP"]!
        idle = !flags.values.contains(true)
        self.actions = Set(actions.compactMap(\.string)).intersection(["stopUserMedia", "stopScreen"])
    }

    func stopParameters(kind: String) -> [String: JSONValue]? {
        let action = kind == "userMedia" ? "stopUserMedia" : kind == "screen" ? "stopScreen" : ""
        guard actions.contains(action) else { return nil }
        return ["profile": .string(profile), "token": .string(token), "kind": .string(kind)]
    }

    var lifecycleParameters: [String: JSONValue] {
        ["captureToken": .string(token), "captureDocument": .string(document)]
    }
}

extension ChromiumPage {
    /// Only the existing BOTH-none action. The native registration stop is
    /// combined camera+microphone, never independent mute/resume or screen.
    func stopNativeUserMedia() {
        questionRequests.cancel(kind: "capture")
        stopNativeCapture(kind: "userMedia")
    }
    func receiveNativeCapture(_ params: [String: JSONValue]) {
        guard params["version"] == .number(1), params["scope"] == .string("browser"), params["profile"]?.string == profile else { return }
        media.nativeCaptureRevision &+= 1
        media.nativeCaptureKnown = true
        media.nativeCapture = ChromiumNativeCapture(params, profile: profile)
        // Unknown/malformed state cannot clear a previously active indicator.
        // Automatic sleep remains vetoed until current-document Forms proof
        // and the native atomic lifecycle guard are integrated and verified.
        if let capture = media.nativeCapture { applyNativeCapture(capture) }
    }

    /// What the page's next getDisplayMedia shows, chosen in Yab's box. A
    /// tab of this engine, a window or a screen; false where this SDK can't
    /// take it or the source has gone (Share falls back on ShareFeed).
    func grantDisplaySource(_ source: [String: JSONValue], origin: PageOrigin, audio: Bool) async -> Bool {
        var params = source
        let scheme = origin.scheme, host = origin.host
        let standard = (scheme == "https" && origin.port == 443) || (scheme == "http" && origin.port == 80) || origin.port <= 0
        params["origin"] = .string(scheme + "://" + host + (standard ? "" : ":\(origin.port)"))
        params["audio"] = .bool(audio)
        return (try? await navigationRequest("media.capture.grant", params))?["granted"] == .bool(true)
    }

    /// Chrome's "Share this tab instead": the running capture moves to
    /// `page`, and the track the far end gets carries on.
    func switchDisplaySource(to page: ChromiumPage, audio: Bool) {
        guard let remote = page.remoteID else { return }
        command("media.capture.switch", ["source": .string("tab"), "sourceTab": .string(remote), "audio": .bool(audio)])
    }

    /// The share can be stopped natively: it ends every track of it.
    var stopsNativeCapture: Bool { media.nativeCapture?.stopParameters(kind: "screen") != nil }

    func stopNativeCapture(kind: String) {
        guard let capture = media.nativeCapture, let params = capture.stopParameters(kind: kind),
              let remote = remoteID, let core = ChromiumProcess.shared.connectedClient else { return }
        let generation = ChromiumProcess.shared.connectionGeneration
        Task { @MainActor [weak self] in
            guard let self, self.remoteID == remote,
                  ChromiumProcess.shared.isCurrent(core, generation: generation),
                  self.media.nativeCapture?.token == capture.token,
                  self.media.nativeCapture?.document == capture.document else { return }
            // dispatched is not stopped. Only a fresh authoritative event
            // changes the indicator. Native code revalidates document/token.
            var original = params; original["tab"] = .string(remote)
            _ = try? await core.request("media.capture.stop", params: original)
        }
    }
}
