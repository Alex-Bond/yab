import AppKit
import WebKit

// The bench's words for a tab dragged out of its window (TearOff), on a
// test run only:
//
//     ./bench tearoff state            every window, its frame, its tabs, each
//                                      tab's web view and where it is drawn,
//                                      all on the screen from the first
//                                      screen's top-left, as pointer.py has it
//     ./bench tearoff mark ID VALUE    a word left in the tab's page
//     ./bench tearoff read ID          the word, and when the page was loaded
//     ./bench tearoff place N FRAME    window N moved to FRAME
//     ./bench tearoff shot PATH        every window and the card, drawn from
//                                      their own layers, where they are
//     ./bench tearoff film DIR SECONDS the same, twenty times a second, while
//                                      something else moves the pointer, and
//                                      the card's and windows' frames at 120 Hz
//     ./bench tearoff new FRAME        a new window, at FRAME if given
//     ./bench tearoff scroll N DX      window N's run of tabs across the top
//                                      scrolled DX points along
//     ./bench tearoff hit X Y          the window a press at X, Y lands in
extension Bench {
    func tearOffCommand(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "tearoff only works on a --test run"]); return }
        let act = request["act"] as? String ?? "state"
        func tab(_ request: [String: Any]) -> Tab? {
            guard let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty else { return nil }
            return BrowserWindows.shared.browsers.lazy.flatMap(\.tabs).first { $0.id.uuidString.lowercased().hasPrefix(ref) }
        }
        switch act {
        case "state":
            answer(Self.tearState())
        case "mark", "read":
            guard let tab = tab(request), let web = tab.builtPage else { answer(["error": "no such tab with a page"]); return }
            let value = (try? JSONSerialization.data(withJSONObject: [request["value"] as? String ?? ""]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let js = act == "mark"
                ? "window.__yabTear = \(value)[0]; [window.__yabTear, performance.timeOrigin]"
                : "[window.__yabTear || null, performance.timeOrigin]"
            web.run(js, gesture: false) { result in
                let list = (try? result.get()) as? [Any] ?? []
                var out: [String: Any] = ["mark": list.first.map(Bench.plain) ?? NSNull(),
                                          "origin": list.count > 1 ? Bench.plain(list[1]) : NSNull(),
                                          "url": web.url?.absoluteString ?? ""]
                if case .failure(let error) = result { out["error"] = error.localizedDescription }
                answer(out)
            }
        case "place":
            // A window moved and sized, from the first screen's top-left.
            guard let number = request["number"] as? Int, let rect = request["frame"] as? [Double], rect.count == 4,
                  let window = NSApp.windows.first(where: { $0.windowNumber == number }) else {
                answer(["error": "place needs a window number and a frame"])
                return
            }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            window.setFrame(NSRect(x: rect[0], y: top - rect[1] - rect[3], width: rect[2], height: rect[3]), display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(Self.tearState()) }
        case "new":
            // A new window beside the others, for its own strip.
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let frame = (request["frame"] as? [Double]).flatMap { rect in
                rect.count == 4 ? NSRect(x: rect[0], y: top - rect[1] - rect[3], width: rect[2], height: rect[3]) : nil
            }
            BrowserWindows.shared.newWindow(from: BrowserWindows.shared.activeBrowser, frame: frame)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { answer(Self.tearState()) }
        case "scroll":
            // The run of tabs across the top of window N (from 1) scrolled
            // along by DX points, as a wheel over it scrolls it.
            let windows = BrowserWindows.shared.openWindows()
            let number = request["number"] as? Int ?? 1
            guard windows.indices.contains(number - 1), let scroll = windows[number - 1].browser.keySky.runScroll else {
                answer(["error": "scroll needs an open window number with tabs across the top"])
                return
            }
            let clip = scroll.contentView
            let most = max(0, (scroll.documentView?.frame.width ?? 0) - clip.bounds.width)
            let x = min(max(clip.bounds.origin.x + CGFloat(request["dx"] as? Double ?? 0), 0), most)
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            scroll.reflectScrolledClipView(clip)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                answer(["x": Double(clip.bounds.origin.x), "most": Double(most), "state": Self.tearState()])
            }
        case "hit":
            // The window a let-go at X, Y (the first screen's top-left)
            // would land in, as TearOff picks it.
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let point = CGPoint(x: request["x"] as? Double ?? 0, y: top - (request["y"] as? Double ?? 0))
            let number = TearOff.window(at: point)
            let window = number.flatMap { n in NSApp.windows.first { $0.windowNumber == n } }
            var out: [String: Any] = ["number": number ?? NSNull(), "ours": window.flatMap { BrowserWindows.shared.browser(for: $0) } != nil]
            if let number, window == nil,
               let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
               let row = rows.first {
                out["owner"] = row[kCGWindowOwnerName as String] as? String ?? ""
            }
            // Every window there, any layer, front first.
            let flipY = request["y"] as? Double ?? 0
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            out["under"] = rows.compactMap { row -> [String: Any]? in
                guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                      rect.contains(CGPoint(x: request["x"] as? Double ?? 0, y: flipY)) else { return nil }
                return ["number": row[kCGWindowNumber as String] as? Int ?? 0, "layer": row[kCGWindowLayer as String] as? Int ?? 0,
                        "ours": (row[kCGWindowOwnerPID as String] as? Int) == Int(ProcessInfo.processInfo.processIdentifier),
                        "frame": [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }]
            }
            answer(out)
        case "shot":
            let path = request["path"] as? String ?? NSTemporaryDirectory() + "yab-tearoff.png"
            guard let png = Self.tearPicture(), (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
                answer(["error": "no picture"])
                return
            }
            answer(["path": path])
        case "film":
            let folder = request["path"] as? String ?? NSTemporaryDirectory() + "yab-tearoff-film"
            let seconds = min(max(request["seconds"] as? Double ?? 3, 0.2), 20)
            // Without pictures, whose drawing holds the main thread a tenth
            // of a second each, only the frames and alpha, undisturbed.
            let pictures = request["pictures"] as? Bool ?? true
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let roll = TearRoll()
            // One canvas for every frame: the screen the windows are on.
            let screen = BrowserWindows.shared.activeWindow?.screen ?? NSScreen.main
            let canvas = screen?.frame
            let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let at = Date().timeIntervalSince(roll.start)
                    if pictures, let png = Self.tearPicture(scale: 1, canvas: canvas) {
                        try? png.write(to: URL(fileURLWithPath: folder + String(format: "/%04d.png", roll.times.count)))
                        roll.times.append(at)
                    }
                    if at >= seconds {
                        timer.invalidate()
                        let done = ["frames": roll.times.count, "times": roll.times, "motion": roll.motion] as [String: Any]
                        if let data = try? JSONSerialization.data(withJSONObject: done) {
                            try? data.write(to: URL(fileURLWithPath: folder + "/done.json"))
                        }
                    }
                }
            }
            // Between pictures, the card's and the windows' frames and
            // alpha as fast as the screen draws: how the card grows into a
            // new window, step by step (`motion` in done.json).
            let sampler = Timer(timeInterval: 1.0 / 120, repeats: true) { sampler in
                MainActor.assumeIsolated {
                    let at = Date().timeIntervalSince(roll.start)
                    guard at < seconds else { sampler.invalidate(); return }
                    var row: [String: Any] = ["t": at]
                    if let card = TearOff.shared.cardPanel {
                        row["card"] = Self.flipped(card.frame)
                        row["cardAlpha"] = Double(card.alphaValue)
                    }
                    row["windows"] = BrowserWindows.shared.browsers.compactMap { BrowserWindows.shared.window(for: $0) }
                        .filter(\.isVisible)
                        .map { ["number": $0.windowNumber, "frame": Self.flipped($0.frame), "alpha": Double($0.alphaValue)] as [String: Any] }
                    roll.motion.append(row)
                }
            }
            // In the tracking run loop mode too: a drag holds the main loop
            // in event tracking while the pointer is down.
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(sampler, forMode: .common)
            answer(["started": folder, "seconds": seconds])
        default:
            answer(["error": "tearoff: state, mark, read, shot or film"])
        }
    }

    /// From the first screen's top-left, y down.
    private static func flipped(_ rect: CGRect) -> [Double] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return [rect.minX, top - rect.maxY, rect.width, rect.height].map { Double($0) }
    }

    static func tearState() -> [String: Any] {
        let windows = BrowserWindows.shared.openWindows().compactMap { entry -> [String: Any]? in
            guard let window = BrowserWindows.shared.window(for: entry.browser) else { return nil }
            let browser = entry.browser
            let screen = { (rect: CGRect) -> CGRect in TearOff.screen(rect, in: browser) }
            let tabs = browser.tabs.map { tab -> [String: Any] in
                var out: [String: Any] = [
                    "id": String(tab.id.uuidString.prefix(8)).lowercased(),
                    "url": tab.address?.absoluteString ?? "",
                    "pinned": tab.pin != nil,
                    "kept": tab.kept,
                    "web": tab.builtPage.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "",
                    "inWindow": tab.builtPage?.window === window,
                ]
                // Across the top, where the strip draws it now; the column's
                // rows linger in drawnRows a while after it goes.
                let row = browser.prefs.sidebar ? browser.drawnRows[DrawnRows.tab(tab.id)] ?? browser.keySky.place(tab.id)
                    : browser.keySky.place(tab.id)
                if let row, row.width > 0 { out["frame"] = flipped(screen(row)) }
                // As much of it as the run across the top shows.
                if !browser.prefs.sidebar, let seen = browser.keySky.seen(tab.id), seen.width > 0 { out["seen"] = flipped(screen(seen)) }
                // What that place is known from (KeySky.census).
                out["placed"] = browser.keySky.census(tab.id)
                return out
            }
            return ["number": window.windowNumber,
                    "frame": flipped(window.frame),
                    "key": window.isKeyWindow,
                    "column": browser.prefs.sidebar && browser.sideShown > 0,
                    // Where the rows' space is: its origin there, and the room
                    // it covers on the screen (TearGround).
                    "ground": [Double(browser.keySky.ground.x), Double(browser.keySky.ground.y)],
                    "anchor": browser.keySky.groundView.flatMap { view in
                        view.window.map { flipped($0.convertToScreen(view.convert(view.bounds, to: nil))) }
                    } ?? [],
                    "content": window.contentView.map { flipped(window.convertToScreen($0.frame)) } ?? [],
                    "active": browser.active.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? "",
                    "tabs": tabs]
        }
        let tear = TearOff.shared
        var out: [String: Any] = ["windows": windows, "torn": tear.torn,
                                  "screens": NSScreen.screens.map { ["frame": flipped($0.frame), "visible": flipped($0.visibleFrame)] }]
        if let card = tear.cardFrame { out["card"] = flipped(card) }
        if let target = tear.targetWindow { out["target"] = target.windowNumber }
        if let index = tear.targetIndex { out["index"] = index }
        if let line = tear.linePanel { out["line"] = flipped(line.frame) }
        if let tab = tear.tab { out["tab"] = String(tab.id.uuidString.prefix(8)).lowercased() }
        out["push"] = [Double(tear.handPast.dx), Double(tear.handPast.dy)]
        return out
    }

    /// Every browser window, back to front, and the card and its line over
    /// them, each drawn from its own layers where it stands on the screen.
    /// WebKit's pages come out blank, the card's picture of one doesn't.
    static func tearPicture(scale given: CGFloat? = nil, canvas: CGRect? = nil) -> Data? {
        let browsers = BrowserWindows.shared.browsers.compactMap { BrowserWindows.shared.window(for: $0) }.filter(\.isVisible)
        let ordered = NSApp.orderedWindows.reversed().filter { window in browsers.contains { $0 === window } }
        let panels = [TearOff.shared.cardPanel, TearOff.shared.linePanel].compactMap { $0 }
        let all = ordered + panels
        guard let first = all.first else { return nil }
        let union = canvas ?? all.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let scale = given ?? (first.screen?.backingScaleFactor ?? 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(union.width * scale), pixelsHigh: Int(union.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
        cg.fill(CGRect(origin: .zero, size: union.size))
        for window in all {
            guard let content = window.contentView, let layer = content.superview?.layer ?? content.layer else { continue }
            cg.saveGState()
            cg.translateBy(x: window.frame.minX - union.minX, y: window.frame.minY - union.minY)
            cg.setAlpha(window.alphaValue)
            Bench.render(layer, in: cg)
            cg.restoreGState()
        }
        return rep.representation(using: .png, properties: [:])
    }
}

/// A film's frames as they are taken.
@MainActor
private final class TearRoll {
    let start = Date()
    var times: [Double] = []
    var motion: [[String: Any]] = []
}
