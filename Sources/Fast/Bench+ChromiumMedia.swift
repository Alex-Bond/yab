import AppKit
import YabCoreClient

extension Bench {
    /// Test-only reads of a Chromium tab's media state, as the column, the
    /// band and sleep see it, beside YabCore's own (ChromiumPage+Media.swift).
    func chromiumMediaProbe(_ request: [String: Any], tab: Tab, page: ChromiumPage,
                            browser: Browser, answer: @escaping ([String: Any]) -> Void) -> Bool {
        guard Store.testing else { return false }
        switch request["op"] as? String {
        case "frame-observe":
            // Read a live child document through the engine's owned frame
            // handle (including OOPIFs), without granting user activation.
            guard let wanted = request["frame"] as? String, let body = request["body"] as? String else {
                answer(["error": "frame and body required"]); return true
            }
            page.childFrames { frames in
                guard let frame = frames.first(where: { (try? page.scripts.token($0, tab: page.remoteID)) == wanted }) else {
                    answer(["error": "observed frame is no longer live in this page"]); return
                }
                page.call(body, in: .page, frame: frame, gesture: false) { result in
                    switch result {
                    case .success(let value): answer(["value": Bench.plain(value)])
                    case .failure(let error): answer(["error": String(describing: error)])
                    }
                }
            }
            return true
        case "fullscreen-observe":
            // A transition observation must not age behind media.read and
            // capture-state roundtrips in the broad media diagnostic below.
            // Keep the native owner, compositor geometry and PiP on one turn.
            answer(["fullscreenState": page.fullscreenState, "surface": page.surfaceState,
                    "pip": page.videoPiP != nil, "now": CACurrentMediaTime()])
            return true
        case "native-pip-state":
            guard let native = page.videoPiP else {
                answer(["active": false, "known": page.nativeVideoPiPKnown]); return true
            }
            let state = native.state
            answer(["active": true, "current": native.current, "token": state.token, "document": state.document,
                    "frame": state.frame, "context": state.context, "controlsKnown": state.controlsKnown,
                    "browserID": state.browserID, "nativeSurface": state.surfaceIdentity,
                    "canSeek": state.canSeek, "canRate": state.canRate,
                    "crop": [state.crop.minX, state.crop.minY, state.crop.width, state.crop.height],
                    "canvas": [state.canvas.width, state.canvas.height], "natural": [state.natural.width, state.natural.height],
                    "paused": state.paused, "muted": state.muted, "position": state.position,
                    "duration": state.duration as Any? ?? NSNull(), "rate": state.rate,
                    "captionsAvailable": state.captionsAvailable, "captionsEnabled": state.captionsEnabled])
            return true
        case "picture", "cached-picture":
            guard let path = request["path"] as? String else { answer(["error": "path required"]); return true }
            let save: @MainActor (NSImage?, Error?) -> Void = { image, error in
                guard let image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    answer(["error": String(describing: error)]); return
                }
                do { try png.write(to: URL(fileURLWithPath: path)); answer(["ok": true, "width": image.size.width, "height": image.size.height]) }
                catch { answer(["error": String(describing: error)]) }
            }
            if request["op"] as? String == "cached-picture" { save(PageStills.shared.picture(of: tab.id), nil) }
            else {
                let rect = (request["rect"] as? [Double]).flatMap { values -> CGRect? in
                    guard values.count == 4, values.allSatisfy(\.isFinite) else { return nil }
                    return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                }
                page.snapshot(PageShot(rect: rect, width: (request["width"] as? Double).map { CGFloat($0) }), done: save)
            }
            return true
        case "media-eval":
            guard let script = request["js"] as? String else { answer(["error": "js required"]); return true }
            // Reading autoplay state must not itself grant user activation.
            page.run(script, gesture: false) { result in
                switch result {
                case .success(let value): answer(["value": Bench.plain(value)])
                case .failure(let error): answer(["error": String(describing: error)])
                }
            }
            return true
        case "native-freeze":
            Task { @MainActor in
                let accepted = await page.freezeForSleep(request["frozen"] as? Bool ?? true)
                answer(["accepted": accepted, "frozen": page.sleepState.frozen,
                        "discarded": page.sleepState.discarded])
            }
            return true
        case "media":
            let report = page.media.report
            var out: [String: Any] = [
                "audible": report.audible, "playing": report.playing, "native": report.native,
                "sessionState": report.sessionState, "noisy": tab.noisy, "muted": tab.muted,
                "immersed": tab.immersed, "camera": String(describing: tab.camera),
                "microphone": String(describing: tab.microphone),
                "awake": browser.awake(because: tab) ?? "", "fullscreenState": page.fullscreenState,
                "nativeSleep": ["supported": page.sleepState.supported, "discarded": page.sleepState.discarded, "frozen": page.sleepState.frozen],
            ]
            if let session = report.session {
                out["session"] = ["title": session.title, "artist": session.artist, "album": session.album,
                                  "artwork": session.artwork.map(\.absoluteString)]
            }
            if let media = report.media {
                out["media"] = ["t": media.time, "d": media.duration, "paused": media.paused, "muted": media.muted, "video": media.video]
            }
            if let tune = tab.tune {
                out["tune"] = ["title": tune.title, "artist": tune.artist, "playing": tune.playing,
                               "duration": tune.duration, "position": tune.position(), "next": tune.next, "previous": tune.previous]
            }
            out["nativeCaptureKnown"] = page.media.nativeCaptureKnown
            if let capture = page.media.nativeCapture {
                out["nativeCapture"] = ["camera": capture.camera, "microphone": capture.microphone, "screen": capture.screen,
                                        "documentPiP": capture.documentPiP, "videoPiP": capture.videoPiP]
            }
            Task { @MainActor in
                if let native = try? await page.navigationRequest("media.read"),
                   let value = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(native), options: .fragmentsAllowed) {
                    out["core"] = value
                }
                if let capture = try? await page.navigationRequest("media.capture.state", ["profile": .string(page.profile)]),
                   let value = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(capture), options: .fragmentsAllowed) {
                    out["coreCapture"] = value
                }
                answer(out)
            }
            return true
        case "document-pip":
            // The page's own floating window: what is on screen, and a press
            // inside it as `click` presses a tab.
            let document = tab.documentPiP
            if request["action"] as? String == "click", let child = document.chromiumPage {
                _ = child.agentClick(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0, flags: [])
            }
            if request["action"] as? String == "close" { document.panel?.performClose(nil) }
            // Someone working in the browser: its window key, this one not.
            if request["action"] as? String == "behind" { BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil) }
            if request["action"] as? String == "picture", let path = request["path"] as? String, let child = document.chromiumPage {
                child.snapshot(PageShot(rect: nil, width: nil)) { image, error in
                    guard let image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                          let png = bitmap.representation(using: .png, properties: [:]) else {
                        answer(["error": String(describing: error)]); return
                    }
                    do { try png.write(to: URL(fileURLWithPath: path)); answer(["ok": true, "width": image.size.width, "height": image.size.height]) }
                    catch { answer(["error": String(describing: error)]) }
                }
                return true
            }
            var out: [String: Any] = [
                "showing": document.showing, "window": document.panel?.windowNumber ?? 0,
                "visible": document.panel?.isVisible ?? false, "key": document.panel?.isKeyWindow ?? false,
                "frame": document.panel.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
                "content": document.chromiumPage.map { [$0.bounds.width, $0.bounds.height] } ?? [],
                "remote": document.chromiumPage?.remoteID ?? "", "context": document.chromiumPage?.contextID ?? 0,
                "surface": Bench.plain(document.chromiumPage?.surfaceState ?? [:]),
            ]
            Task { @MainActor in
                if let child = document.chromiumPage, let native = try? await child.navigationRequest("tab.state"),
                   let value = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(native), options: .fragmentsAllowed) {
                    out["core"] = value
                }
                answer(out)
            }
            return true
        case "media-action":
            guard let action = request["action"] as? String else { answer(["error": "action required"]); return true }
            switch action {
            case "band-play": tab.tuneWatch.want(playing: true)
            case "band-pause": tab.tuneWatch.want(playing: false)
            case "exit-fullscreen": page.exitPageFullscreen()
            case "sleep-hush": SleepHush.shared.hush()
            default: page.mediaAction(action, value: request["value"] as? Double)
            }
            answer(["ok": true])
            return true
        default:
            return false
        }
    }
}
