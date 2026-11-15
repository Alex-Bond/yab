import Foundation
import YabCoreClient

/// Browser-owned MediaSession state. Site-reported capture flags are kept
/// separate from PageCaptureStatus and never authorize sleep or cleanup.
struct ChromiumNativeMediaSession: Equatable {
    let token: String
    let document: String
    let profile: String
    let playback: String
    let hideMetadata: Bool
    let title: String
    let artist: String
    let album: String
    let artwork: [URL]
    let actions: Set<String>
    let position: Double?
    let duration: Double?
    let reportedMicrophone: String
    let reportedCamera: String
    let reportedPiP: Bool
    let outputMuted: Bool

    init?(_ p: [String: JSONValue], profile expected: String) {
        guard p["version"] == .number(1), p["available"] == .bool(true),
              p["profile"]?.string == expected,
              let token = p["token"]?.string, !token.isEmpty, token.count <= 256,
              let document = p["document"]?.string, !document.isEmpty, document.count <= 256,
              let frame = p["frameId"]?.string, !frame.isEmpty,
              let session = p["session"]?.string, !session.isEmpty,
              let browser = p["browserId"]?.number, browser.isFinite, browser > 0,
              let playback = p["playback"]?.string, ["playing", "paused"].contains(playback),
              case .bool(let hidden)? = p["hideMetadata"],
              case .array(let rows)? = p["actions"], rows.count <= 64 else { return nil }
        self.token = token; self.document = document; profile = expected
        self.playback = playback; hideMetadata = hidden
        title = hidden ? "" : String((p["title"]?.string ?? "").prefix(1024))
        artist = hidden ? "" : String((p["artist"]?.string ?? "").prefix(1024))
        album = hidden ? "" : String((p["album"]?.string ?? "").prefix(1024))
        let images: [JSONValue]
        if case .array(let rows)? = p["artwork"] { images = Array(rows.prefix(8)) } else { images = [] }
        artwork = hidden ? [] : images.compactMap { row in
            guard let raw = row["src"].string, raw.count <= 8192, let url = URL(string: raw),
                  ["http", "https", "data"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        let supported: Set<String> = ["play", "pause", "seek", "seekForward", "seekBackward", "next", "previous", "toggleMicrophone", "toggleCamera", "hangUp"]
        actions = Set(rows.compactMap(\.string)).intersection(supported)
        let duration = p["position"]?["duration"].number
        let position = p["position"]?["position"].number
        if let duration, let position, duration.isFinite, position.isFinite,
           duration >= 0, position >= 0, position <= duration {
            self.position = position; self.duration = duration
        } else { self.position = nil; self.duration = nil }
        reportedMicrophone = ["unknown", "muted", "unmuted"].contains(p["reportedMicrophone"]?.string ?? "") ? p["reportedMicrophone"]!.string! : "unknown"
        reportedCamera = ["unknown", "on", "off"].contains(p["reportedCamera"]?.string ?? "") ? p["reportedCamera"]!.string! : "unknown"
        reportedPiP = p["reportedPiP"] == .bool(true)
        outputMuted = p["outputMuted"] == .bool(true)
    }

    var remoteCommands: Set<String> {
        var result = actions.intersection(["play", "pause", "next", "previous"])
        if actions.contains(playback == "playing" ? "pause" : "play") { result.insert("toggle") }
        if let position, parameters(action: "seekto", seconds: position) != nil { result.insert("seekto") }
        return result
    }

    func parameters(action: String, seconds: Double? = nil) -> [String: JSONValue]? {
        let mapped = action == "seekto" ? "seek" : action == "toggle" ? (playback == "playing" ? "pause" : "play") : action
        guard actions.contains(mapped) else { return nil }
        var p: [String: JSONValue] = ["profile": .string(profile), "token": .string(token), "action": .string(mapped)]
        if mapped == "seek" {
            guard let seconds, seconds.isFinite, seconds >= 0, let duration, seconds <= duration else { return nil }
            p["seconds"] = .number(seconds)
        } else if mapped == "seekForward" || mapped == "seekBackward" {
            guard let seconds, seconds.isFinite, seconds > 0, seconds <= 86400 else { return nil }
            p["seconds"] = .number(seconds)
        } else if seconds != nil { return nil }
        return p
    }
}

extension ChromiumPage {
    /// One refresh after authenticated adoption covers events emitted before
    /// the page was attached. Unsupported SDKs issue no native media request.
    func refreshNativeMediaState(core: YabCoreClient, remote: String, hooks: [String: JSONValue]) {
        func supported(_ name: String) -> Bool { hooks[name] == .bool(true) || hooks[name] == .number(1) }
        let sessionSupported = supported("nativeMediaSession"), captureSupported = supported("nativeCaptureActivity")
        refreshNativeVideoPiP(core: core, remote: remote, supported: supported("nativeVideoPiP"))
        if sessionSupported { media.nativeSessionKnown = true; receiveNativeAudible(media.rawReport) }
        if captureSupported { media.nativeCaptureKnown = true }
        let revision = navigationTab?.engineNavigationRevision
        let sessionRevision = media.nativeSessionRevision, captureRevision = media.nativeCaptureRevision
        Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool {
                self.remoteID == remote && ChromiumProcess.shared.isCurrent(core) &&
                    self.navigationTab?.engineNavigationRevision == revision
            }
            guard current() else { return }
            let parameters: [String: JSONValue] = ["tab": .string(remote), "profile": .string(self.profile)]
            if sessionSupported, let state = try? await core.request("media.session.state", params: parameters),
               current(), self.media.nativeSessionRevision == sessionRevision, let value = state.object {
                self.receiveNativeMediaSession(value)
            }
            if captureSupported, let state = try? await core.request("media.capture.state", params: parameters),
               current(), self.media.nativeCaptureRevision == captureRevision, let value = state.object {
                self.receiveNativeCapture(value)
            }
        }
    }

    func receiveNativeMediaSession(_ p: [String: JSONValue]) {
        guard p["version"] == .number(1), p["profile"]?.string == profile else { return }
        media.nativeSessionRevision &+= 1
        media.nativeSessionKnown = true
        media.nativeSession = ChromiumNativeMediaSession(p, profile: profile)
        if let tab = navigationTab, tab.builtPage === self {
            // Site declarations describe the call's own switches only. They
            // never establish camera/microphone capture or sleep eligibility.
            tab.pageMic = media.nativeSession.flatMap { session in
                session.reportedMicrophone == "muted" ? true : session.reportedMicrophone == "unmuted" ? false : nil
            }
            tab.pageCamera = media.nativeSession.flatMap { session in
                session.reportedCamera == "off" ? true : session.reportedCamera == "on" ? false : nil
            }
        }
        receiveNativeAudible(media.rawReport)
    }

    /// Absolute call switch commands require the site's native reported
    /// state. Capture activity cannot tell whether a site's switch is muted.
    /// A known native boundary never falls through to a DOM selector.
    func routeNativeCallSwitch(_ action: String, muted: Bool) -> Bool {
        guard media.nativeSessionKnown else { return false }
        guard let session = media.nativeSession else { return true }
        let current: Bool?
        switch action {
        case "toggleMicrophone":
            current = session.reportedMicrophone == "muted" ? true : session.reportedMicrophone == "unmuted" ? false : nil
        case "toggleCamera":
            current = session.reportedCamera == "off" ? true : session.reportedCamera == "on" ? false : nil
        default: return true
        }
        guard let current, current != muted else { return true }
        return routeNativeMediaAction(action)
    }

    /// True means the native boundary owns this action, even when the site
    /// does not support it. Refusal must not fall through to DOM playback.
    func routeNativeMediaAction(_ action: String, value: Double? = nil) -> Bool {
        guard let session = media.nativeSession else { return media.nativeSessionKnown }
        guard let params = session.parameters(action: action, seconds: value), let remote = remoteID else { return true }
        Task { @MainActor [weak self] in
            guard let self, self.remoteID == remote, self.media.nativeSession?.token == session.token else { return }
            // The helper rechecks the exact native document and supported
            // action at dispatch. A stale refusal is not a page-load failure.
            _ = try? await self.navigationRequest("media.session.action", params)
        }
        return true
    }
}
