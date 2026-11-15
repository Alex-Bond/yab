import AppKit

// The bench's words for files going into a page and out of one, on a test
// run only (evals/files/check.py):
//
//     {"do": "files"}                     what is waiting: a page's file
//                                         question, the peek, the tabs, the
//                                         downloads folder and what it keeps
//     {"do": "files", "id": ID, "js": JS} a script's value in a tab of yours
//     {"do": "files", "press": [X, Y]}    a click at that CSS point of the page
//                                         in front, handed to the page
//     {"do": "files", "pick": [PATH…]}    the Files place answered with these,
//                                         as a row picked there answers it
//     {"do": "files", "adopt": ID}        a bench tab made yours and put in
//                                         front, so its windows and downloads
//                                         are judged as yours are
//     {"do": "files", "pin": ID}          that tab pinned
//     {"do": "files", "only": ID}         every other tab, the peek and small
//                                         windows closed ("" closes all)
//     {"do": "files", "tip": true}        the downloads stack's "All
//                                         Downloads" tip held up (false lets
//                                         the pointer decide again)
extension Bench {
    func filesCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "files only works on a --test run"]); return }
        func tab(_ key: String) -> Tab? {
            guard let ref = (request[key] as? String)?.lowercased(), !ref.isEmpty else { return nil }
            return browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
        }
        // A script in a tab of yours, the page's own world, its value: the
        // bench's "eval" is an agent's and keeps to the agent's tabs.
        if let code = request["js"] as? String {
            guard let page = tab("id")?.builtPage else { answer(["error": "no such tab"]); return }
            page.run(code) { result in
                switch result {
                case .success(let value): answer(["value": Bench.plain(value)])
                case .failure(let error): answer(["error": error.localizedDescription])
                }
            }
            return
        }
        // A press and let-go at a point of the page in front, in its CSS
        // pixels, handed to the page itself: a probe started behind other
        // windows isn't key, and the window would take the press for itself.
        if let at = request["press"] as? [Double], at.count == 2 {
            guard let web = browser.active?.builtPage, let window = web.window else { answer(["error": "no page"]); return }
            let zoom = web.pageZoom * web.magnification
            let local = CGPoint(x: at[0] * zoom, y: web.isFlipped ? at[1] * zoom : web.bounds.height - at[1] * zoom)
            let point = web.convert(local, to: nil)
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                if type == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
            }
        }
        if let paths = request["pick"] as? [String] {
            guard browser.fileAnswer != nil else { answer(["error": "no page is asking for a file"]); return }
            browser.finishFiles(paths.map { URL(fileURLWithPath: $0) })
        }
        if let mine = tab("adopt") {
            mine.adopt()
            mine.agent = nil
            browser.select(mine)
        }
        if let pinned = tab("pin") { browser.pin(pinned) }
        // Everything but this tab put away: other tabs, the peek, small
        // windows, for the next case to start clean.
        if let keep = request["only"] as? String {
            if browser.peeking != nil { browser.closePeek() }
            for page in browser.outside { browser.letGo(outside: page) }
            for other in browser.tabs where !other.id.uuidString.lowercased().hasPrefix(keep.lowercased()) || keep.isEmpty {
                browser.close(other)
            }
        }
        if let tip = request["tip"] as? Bool { browser.hoard.holdStackTip(tip) }
        // On the screen, from the first screen's top-left, as CGEvents
        // place the pointer: the page in front and the stack's panel.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        func flipped(_ rect: CGRect) -> [Double] { [rect.minX, top - rect.maxY, rect.width, rect.height].map { Double($0) } }
        var page: [Double] = []
        if let web = browser.active?.builtPage, let window = web.window {
            page = flipped(window.convertToScreen(web.convert(web.bounds, to: nil)))
        }
        let stack = browser.hoard.stackWindow.flatMap { $0.isVisible ? flipped($0.frame) : nil } ?? []
        // The stack's parts in its panel, and the column's band there: its
        // cards' edge `air.leading` in, as wide as the column.
        let layout = HoardStack.measured.mapValues { [$0.minX, $0.minY, $0.width, $0.height].map { Double($0) } }
        let band = browser.hoard.stackWindow.map { panel -> [Double] in
            [Double(HoardStack.air.leading), Double(panel.frame.width - HoardStack.air.leading - HoardStack.air.trailing)]
        } ?? []
        answer([
            "page": page,
            "stack": stack,
            "layout": layout,
            "band": band,
            "asking": browser.fileAnswer != nil,
            "place": String(describing: browser.query.place),
            "peek": browser.peeking.map { ["url": $0.address?.absoluteString ?? "", "pending": $0.pending?.absoluteString ?? ""] } ?? NSNull(),
            "outside": browser.outside.count,
            "active": browser.activeID?.uuidString ?? "",
            "tabs": browser.tabs.map { ["id": $0.id.uuidString, "url": $0.address?.absoluteString ?? "",
                                        "pending": $0.pending?.absoluteString ?? "", "pin": $0.pin != nil,
                                        "failure": $0.failure ?? ""] },
            "downloads": browser.prefs.downloads.path,
            "kept": browser.loot.kept.map(\.name),
            "fetches": browser.hoard.fetches.map(\.name),
        ])
    }
}
