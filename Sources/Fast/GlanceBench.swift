import AppKit

/// Native keyboard events against the current responder, without assigning
/// the search query or focusing the search on the probe's behalf.
extension Bench {
    func folderPreviewCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing, let window = Links.window else { answer(["error": "folder preview needs a test window"]); return }
        switch request["action"] as? String {
        case "pin-delay":
            let delay = max(0, request["seconds"] as? Double ?? 0)
            browser.glance.pinLoader = { tab, browser, query, done in
                PinList.items(for: tab, in: browser, query: query) { items in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { done(items) }
                }
            }
        case "pin-trace":
            guard let id = request["id"] as? String,
                  let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) })
            else { answer(["error": "pin-trace needs a pin id"]); return }
            let glance = browser.glance, key = TabGlance.pinKey(tab.id)
            glance.drop()
            if let frame = browser.keySky.place(tab.id) { glance.folderFrames[key] = frame }
            if let box = request["anchor"] as? [Double], box.count == 4 {
                glance.folderFrames[key] = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
            }
            let start = CACurrentMediaTime()
            var samples: [[String: Any]] = []
            func sample() {
                samples.append(["ms": (CACurrentMediaTime() - start) * 1000,
                                "shown": glance.shownFolder == key, "count": glance.pinItems.count,
                                "frame": glance.previewFrame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []])
            }
            glance.pretendFolder(key, true)
            sample()
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
                MainActor.assumeIsolated {
                    sample()
                    if CACurrentMediaTime() - start >= (request["seconds"] as? Double ?? 1) {
                        timer.invalidate()
                        answer(["samples": samples])
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            return
        case "place-folder":
            if let name = request["folder"] as? String, let nest = browser.nests.first(where: { $0.name == name }),
               let index = request["index"] as? Int {
                browser.move(nest, to: index, in: nil)
            }
        case "focus-page":
            if let web = browser.active?.builtPage { window.makeFirstResponder(web) }
        case "keys":
            var keys: [(UInt16, String, NSEvent.ModifierFlags)] = []
            if let text = request["text"] as? String {
                keys = text.map { (Bench.keyCode(for: $0), String($0), []) }
            } else {
                switch request["key"] as? String {
                case "escape": keys = [(53, "\u{1b}", [])]
                case "return": keys = [(36, "\r", [])]
                case "delete": keys = [(51, "\u{7f}", [])]
                case "select-all": keys = [(0, "a", [.command])]
                case "left": keys = [(123, "\u{f702}", [.function, .numericPad])]
                case "right": keys = [(124, "\u{f703}", [.function, .numericPad])]
                case "down": keys = [(125, "\u{f701}", [.function, .numericPad])]
                case "up": keys = [(126, "\u{f700}", [.function, .numericPad])]
                default: answer(["error": "unknown preview key"]); return
                }
            }
            for (code, chars, flags) in keys {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: chars, charactersIgnoringModifiers: chars,
                                                  isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let glance = browser.glance
            let editor = window.firstResponder as? NSTextView
            let field = editor?.delegate as? NSTextField
            let root = window.contentView
            let box = field.map { $0.convert($0.bounds, to: root) }
            let searchFrame: [Double] = box.map { rect in
                [Double(rect.minX), Double(root?.isFlipped == true ? rect.minY : (root?.bounds.height ?? 0) - rect.maxY), Double(rect.width), Double(rect.height)]
            } ?? []
            let iconCount = glance.shownFolder.map { key in
                glance.items(key).filter { item in
                    if case .tab(let tab) = item { return tab.icon != nil }
                    return false
                }.count
            } ?? 0
            answer(["falls": glance.previewFalls, "pinCount": glance.pinItems.count,
                    "anchor": glance.shownFolder.flatMap { glance.folderFrames[$0] }.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
                    "fieldDark": field?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                    "theme": SpaceWash.card(browser.prefs)?.color.hex ?? "",
                    "searchFrame": searchFrame, "iconCount": iconCount, "folder": glance.shownFolder ?? "", "query": glance.query, "lit": glance.lit,
                    "at": glance.at ?? "", "focused": field?.identifier?.rawValue == "folder-preview-search",
                    "editor": editor?.string ?? "", "responder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "",
                    "active": browser.activeID?.uuidString ?? "", "typing": browser.active?.typing == true,
                    "frame": glance.previewFrame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
                    "items": glance.shownFolder.map { glance.items($0).map(\.id) } ?? []])
        }
    }
}
