import AppKit
import PDFKit
import YabCoreClient

private extension URL {
    /// A binary property list attribute, such as Where From, as strings.
    func extendedAttribute(_ name: String) throws -> [String]? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
    }
}

extension Bench {
    /// Test-only control of existing UI, not an alternate implementation.
    func chromiumNavigationProbe(_ request: [String: Any], tab: Tab, page: ChromiumPage,
                                 browser: Browser, answer: @escaping ([String: Any]) -> Void) -> Bool {
        guard Store.testing else { return false }
        switch request["op"] as? String {
        case "nav-health":
            // Observe a busy page without waiting behind its input queue.
            // Test-only, read-only native IPC; no renderer script is evaluated.
            Task { @MainActor in
                do {
                    let (core, remote) = try await page.endpoint()
                    let state = try await core.request("media.read", params: ["tab": .string(remote)])
                    let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                    answer(["value": value])
                } catch { answer(["error": String(describing: error)]) }
            }
            return true
        case "feature-rejection":
            // Exercise the real serialized feature-command error route.
            page.command("page.cdpForTesting", ["command": .string("Yab.nonexistentFeature")])
            Task { @MainActor in
                await page.queueTail?.value
                answer(page.surfaceState)
            }
            return true
        case "peek-pressure":
            guard tab.id == browser.activeID, page.window != nil,
                  let x = request["x"] as? Double, let y = request["y"] as? Double,
                  x.isFinite, y.isFinite, page.bounds.contains(CGPoint(x: x, y: y)) else {
                answer(["error": "Pressure probe needs a point in the active page"]); return true
            }
            let point = CGPoint(x: x, y: y)
            page.receivePressure(stage: 1, amount: 0.8, point: point)
            page.receivePressure(stage: 2, amount: 1, point: point)
            page.receivePressure(stage: 0, amount: 0, point: point)
            answer(["sent": true]); return true
        case "nav-options-batch":
            // The exact ExtensionOptionsRestoreTests putAway/bringBack seam.
            // Timed tidy and automatic sleep keep their separate real guards.
            switch request["action"] as? String {
            case "put-away":
                guard let raw = request["ids"] as? [String], !raw.isEmpty, raw.count <= 8,
                      Set(raw).count == raw.count,
                      raw.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                    answer(["error": "Exact original tab UUIDs required"]); return true
                }
                let ids = Set(raw.compactMap(UUID.init(uuidString:)))
                let original = browser.tabs.enumerated().filter { ids.contains($0.element.id) }
                guard original.count == ids.count, original.allSatisfy({ row in
                    let tab = row.element
                    return !tab.shy && !tab.bench && !tab.kept && tab.pin == nil && tab.id != browser.activeID &&
                        !tab.gone && (tab.builtPage as? ChromiumPage)?.profile == page.profile && tab.address != nil
                }) else { answer(["error": "Only exact background native fixture pages may be put away"]); return true }
                let sources = Dictionary(uniqueKeysWithValues: original.map { ($0.offset, $0.element.id.uuidString.lowercased()) })
                guard let batch = browser.putAway(original.map(\.element)) else {
                    answer(["error": "Original putAway refused the fixture batch"]); return true
                }
                let ghosts = browser.ghosts.filter { $0.batch == batch }.sorted { $0.index < $1.index }
                answer(["batch": batch.uuidString.lowercased(), "active": browser.activeID?.uuidString.lowercased() ?? "",
                        "ghosts": ghosts.map { ghost in
                    ["ghost": ghost.id.uuidString.lowercased(), "source": sources[ghost.index] ?? "",
                     "url": ghost.url.absoluteString, "title": ghost.title, "index": ghost.index] as [String: Any]
                }]); return true
            case "bring-back":
                guard let raw = request["batch"] as? String, let batch = UUID(uuidString: raw),
                      let expected = request["ghosts"] as? [String], !expected.isEmpty,
                      Set(expected).count == expected.count,
                      expected.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                    answer(["error": "Exact retained batch and ghost UUIDs required"]); return true
                }
                let ghosts = browser.ghosts.filter { $0.batch == batch }.sorted { $0.index < $1.index }
                guard ghosts.count == expected.count, Set(ghosts.map(\.id)) == Set(expected.compactMap(UUID.init(uuidString:))) else {
                    answer(["error": "The original closed batch changed"]); return true
                }
                let restored = browser.bringBack(batch)
                answer(["batch": batch.uuidString.lowercased(), "active": browser.activeID?.uuidString.lowercased() ?? "",
                        "remainingGhosts": browser.ghosts.filter { $0.batch == batch }.map { $0.id.uuidString.lowercased() },
                        "restored": restored.enumerated().map { index, tab in
                    ["ghost": index < ghosts.count ? ghosts[index].id.uuidString.lowercased() : "",
                     "id": Bench.short(tab), "uuid": tab.id.uuidString.lowercased(), "url": tab.address?.absoluteString ?? "",
                     "title": tab.title, "asleep": tab.asleep,
                     "index": browser.tabs.firstIndex(where: { $0 === tab }) ?? -1] as [String: Any]
                }]); return true
            default: answer(["error": "put-away or bring-back required"]); return true
            }
        case "nav-pointer":
            // Exercise the person's AppKit pointer route, not scripts.input's
            // separate CDP coordinate API. Points are in the visible page.
            guard Store.testing, let window = page.window,
                  let x = request["x"] as? Double, let y = request["y"] as? Double,
                  x.isFinite, y.isFinite else { answer(["error": "native pointer requires a finite point and test window"]); return true }
            let at = page.convert(NSPoint(x: x, y: page.isFlipped ? y : page.bounds.height - y), to: nil)
            func send(_ type: NSEvent.EventType) {
                guard let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
                switch type {
                case .leftMouseDown: page.mouseDown(with: event)
                case .leftMouseUp: page.mouseUp(with: event)
                default: page.mouseMoved(with: event)
                }
            }
            send(.mouseMoved)
            if request["hover"] as? Bool != true { send(.leftMouseDown); send(.leftMouseUp) }
            answer(["delivered": true]); return true
        case "nav-pinch":
            // Two fingers over the page in front, as the trackpad hands them
            // to the app: gesture events posted to the queue, so whatever is
            // under the fingers takes them through AppKit. "scale" is what
            // the fingers would make of the page, "steps" events "gap"
            // seconds apart, at "x", "y" in points of the page from its top
            // left. "double" taps twice instead (Smart Zoom).
            guard let window = page.window else { answer(["error": "no page in a window"]); return true }
            let frame = page.convert(page.bounds, to: nil)
            let at = NSPoint(x: frame.minX + (request["x"] as? Double ?? Double(frame.width / 2)),
                             y: frame.maxY - (request["y"] as? Double ?? Double(frame.height / 2)))
            if request["double"] as? Bool == true {
                guard let event = Bench.smartMagnify(at: at, in: window) else { answer(["error": "no gesture event"]); return true }
                NSApp.postEvent(event, atStart: false)
                answer(["eventType": Int(event.type.rawValue)]); return true
            }
            let steps = max(request["steps"] as? Int ?? 60, 1), gap = request["gap"] as? Double ?? 0.008
            let each = pow(request["scale"] as? Double ?? 2, 1 / Double(steps)) - 1
            var moves: [(NSEvent.Phase, Double)] = [(.began, 0)]
            moves += Array(repeating: (.changed, each), count: steps)
            moves.append((.ended, 0))
            let events = moves.compactMap { Bench.magnify($0.1, phase: $0.0, at: at, in: window) }
            guard events.count == moves.count, events.allSatisfy({ $0.type == .magnify }) else {
                answer(["error": "no magnify event", "types": events.map { Int($0.type.rawValue) }]); return true
            }
            for (index, event) in events.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(index)) { NSApp.postEvent(event, atStart: false) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(events.count) + 0.05) {
                answer(["events": events.count, "phases": events.map { Int($0.phase.rawValue) }.prefix(3).map { $0 },
                        "magnification": Double(events[1].magnification)])
            }
            return true
        case "nav-swipe":
            answer(["gesture": page.swipe.swipeGesture, "settled": page.swipe.swipeSettled,
                    "pull": tab.pull.map { ["listed": $0.listed, "armed": $0.armed, "back": $0.back,
                        "title": $0.stop?.title ?? "", "rows": $0.stops.map(\.title)] as [String: Any] } ?? [:]])
            return true
        case "nav-history":
            if let row = request["row"] as? Int { DoorList.shared.take(row, as: nil) }
            if let index = request["pick"] as? Int { DoorList.shared.pickHistory(index) }
            Task { @MainActor in
                do {
                    let snapshot = try await page.navigationHistory()
                    answer(["current": snapshot.currentIndex,
                            "entries": snapshot.entries.map { ["id": $0.id, "url": $0.url.absoluteString, "title": $0.title] as [String: Any] },
                            "stops": DoorList.shared.stops.map { ["title": $0.title, "host": $0.host, "kind": String(describing: $0.kind), "index": $0.index] as [String: Any] },
                            "panel": DoorList.shared.history?.entries.map { ["url": $0.url.absoluteString, "current": $0.current] as [String: Any] } ?? []])
                } catch { answer(["error": String(describing: error)]) }
            }
            return true
        case "nav-permission":
            // What Chromium itself holds for a site (test read), beside Yab's own decision.
            guard let origin = request["origin"] as? String else { answer(["error": "origin required"]); return true }
            Task { @MainActor in
                do {
                    let value = try await page.navigationRequest("permission.state", ["origin": .string(origin)])
                    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
                    answer(object ?? [:])
                } catch { answer(["error": String(describing: error)]) }
            }
            return true
        case "dev-file-panel":
            guard let panel = page.window?.attachedSheet as? NSSavePanel else { answer(["shown": false]); return true }
            let state: [String: Any] = ["shown": true, "open": panel is NSOpenPanel,
                                        "name": panel.nameFieldStringValue, "window": panel.windowNumber]
            if request["cancel"] as? Bool == true { panel.cancel(nil) }
            answer(state); return true
        case "nav-save-panel":
            // Drive the actual AppKit save sheet; never answer CEF directly.
            guard let panel = page.window?.attachedSheet as? NSSavePanel,
                  !(panel is NSOpenPanel) else { answer(["shown": false]); return true }
            let state: [String: Any] = ["shown": true, "name": panel.nameFieldStringValue,
                                        "window": panel.windowNumber]
            if request["cancel"] as? Bool == true { panel.cancel(nil) }
            else if let path = request["path"] as? String, path.hasPrefix("/") {
                let url = URL(fileURLWithPath: path)
                panel.directoryURL = url.deletingLastPathComponent()
                panel.nameFieldStringValue = url.lastPathComponent
                panel.ok(nil)
            }
            answer(state); return true
        case "sys-cdp":
            // A raw DevTools command, for what a Mac can't be made to do from
            // a farm job (offline, memory pressure). evals/chromium-system.
            guard let name = request["command"] as? String else { answer(["error": "command required"]); return true }
            Task { @MainActor in
                do {
                    let fields = try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: request["params"] ?? [String: Any]()))
                    let value = try await page.navigationRequest("page.cdpForTesting", ["command": .string(name), "params": .object(fields),
                        "session": .string(request["cdpSession"] as? String ?? "")])
                    answer(["value": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)) ?? NSNull()])
                } catch { answer(["error": String(describing: error)]) }
            }
            return true
        case "sys-window":
            // Where the page's window is, its display and whether AX has the tree.
            answer(["screen": page.window?.screen?.localizedName ?? "", "scale": page.window?.backingScaleFactor ?? 0,
                    "accessibility": page.remoteAccessibility.element != nil, "dragging": page.dragState.source != nil,
                    "find": tab.finder.shown, "tip": page.tipText, "inputSource": page.inputContext?.selectedKeyboardInputSource ?? "",
                    "windows": BrowserWindows.shared.openWindows().count])
            return true
        case "nav-crash":
            Task { @MainActor in _ = try? await page.navigationRequest("page.crashForTesting") }
            answer(["ok": true]); return true
        case "nav-downloads":
            if request["cancel"] as? Bool == true, let fetch = browser.hoard.fetches.first { browser.hoard.cancel(fetch) }
            answer(["rows": browser.hoard.fetches.map { fetch in
                let step = browser.hoard.meter.steps[fetch.id]
                return ["name": fetch.name, "failed": fetch.failed, "received": step?.got ?? 0, "total": step?.total ?? 0] as [String: Any]
            }])
            return true
        case "nav-image-bytes":
            // A picture's bytes as Copy Image takes them (Browser.imageData),
            // or as ⌘F reads them with `largest`: their size and pixels.
            guard let address = (request["url"] as? String).flatMap(URL.init(string:)) else { answer(["error": "url required"]); return true }
            Task { @MainActor in
                let began = Date()
                let data = await Browser.imageData(address, from: tab, largest: request["largest"] as? Int)
                let source = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                answer(["bytes": data?.count ?? 0, "width": properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                        "height": properties?[kCGImagePropertyPixelHeight] as? Int ?? 0,
                        "type": source.flatMap { CGImageSourceGetType($0) as String? } ?? "",
                        "ms": Int(Date().timeIntervalSince(began) * 1000)])
            }
            return true
        case "nav-save-pdf":
            guard let path = request["folder"] as? String else { answer(["error": "folder required"]); return true }
            PageSave.save(tab, as: "pdf", in: URL(fileURLWithPath: path, isDirectory: true)) { result in
                switch result {
                case .success(let file):
                    let document = PDFDocument(url: file)
                    answer(["path": file.path, "pages": document?.pageCount ?? 0, "text": document?.string ?? ""])
                case .failure(let error): answer(["error": error.localizedDescription])
                }
            }
            return true
        case "nav-print":
            browser.printPage()
            answer(["ok": true]); return true
        case "nav-print-status":
            let sheet = page.window?.attachedSheet
            if request["cancel"] as? Bool == true, let sheet {
                func cancel(_ view: NSView) -> Bool {
                    if let button = view as? NSButton, button.title == "Cancel" { button.performClick(nil); return true }
                    return view.subviews.contains { cancel($0) }
                }
                if let content = sheet.contentView { _ = cancel(content) }
            }
            answer(["sheet": sheet?.windowNumber ?? 0, "printed": Browser.printed?.absoluteString ?? "",
                    "nativeRequestObserved": page.nativePrintRequestID != nil,
                    "preview": page.printPreviewForTesting]); return true
        case "nav-zoom":
            if request["reset"] as? Bool == true { tab.resetZoom() }
            else if let increasing = request["increasing"] as? Bool { tab.stepZoom(increasing: increasing) }
            else if let factor = request["factor"] as? Double { tab.magnify(to: factor) }
            answer(["zoom": Double(tab.zoom)]); return true
        case "nav-dialog":
            if let user = request["user"] as? String { browser.typeAsk(tab, user) }
            if let password = request["password"] as? String { browser.typeSecret(tab, password) }
            if let accept = request["accept"] as? Bool {
                browser.answer(tab, accept ? .yes(request["text"] as? String) : .no)
            }
            answer(["asks": tab.asks.map { ["kind": String(describing: $0.kind), "host": $0.host, "message": $0.message, "failed": $0.failed] }]); return true
        case "nav-kept":
            answer(["files": browser.loot.kept.prefix(20).map { keep in
                let wheres = (try? URL(fileURLWithPath: keep.path).extendedAttribute("com.apple.metadata:kMDItemWhereFroms")) ?? nil
                return ["name": keep.name, "from": keep.from, "path": keep.path, "page": keep.page?.absoluteString ?? "",
                        "whereFroms": wheres ?? [String]()] as [String: Any]
            }])
            return true
        case "nav-pasteboard":
            let board = NSPasteboard.general
            if request["clear"] as? Bool == true { board.clearContents(); board.setString("", forType: .string) }
            answer(["string": board.string(forType: .string) ?? "",
                    "types": board.types?.map(\.rawValue) ?? [],
                    "image": NSImage(pasteboard: board).map { [$0.size.width, $0.size.height] } ?? []])
            return true
        case "nav-print-file":
            // What the print sheet would print, saved to `path` instead of
            // shown: the page's printed PDF through the sheet's own print
            // operation (printOperation(for:)), with only its destination
            // changed to a file (Save as PDF). `source`: the PDF itself.
            guard let path = request["path"] as? String else { answer(["error": "path required"]); return true }
            Task { @MainActor in
                do {
                    let data = try await page.printedPDF()
                    if let source = request["source"] as? String { try data.write(to: URL(fileURLWithPath: source), options: .atomic) }
                    guard let document = PDFDocument(data: data), let operation = page.printOperation(for: document) else {
                        answer(["error": "no print operation"]); return
                    }
                    let info = operation.printInfo
                    // `landscape`: the paper turned in the sheet after the pages were made.
                    if request["landscape"] as? Bool == true { info.orientation = .landscape }
                    info.jobDisposition = .save
                    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: path)
                    operation.printInfo = info
                    operation.showsPrintPanel = false
                    operation.showsProgressPanel = false
                    let ran = operation.run()
                    let first = document.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
                    answer(["saved": ran, "path": path, "pages": document.pageCount,
                            "sourcePage": [first.width, first.height],
                            "paper": [info.paperSize.width, info.paperSize.height],
                            "margins": [info.topMargin, info.leftMargin, info.bottomMargin, info.rightMargin]])
                } catch { answer(["error": error.localizedDescription]) }
            }
            return true
        case "nav-veils":
            // Hide Elements as the window sees it: picking or not, and what
            // Site Controls lists as hidden on this site.
            answer(["veiling": browser.veiling, "host": browser.hereHost ?? "",
                    "hidden": browser.hereVeils.map { ["selector": $0.selector, "label": $0.label] }])
            return true
        case "nav-ask-print":
            // window.print() from the page itself, as a site's Print button.
            Task { @MainActor in _ = try? await page.navigationRequest("script.document", ["expression": .string("setTimeout(()=>print(),30),true"), "userGesture": .bool(true)]) }
            answer(["ok": true]); return true
        case "nav-close-row":
            // The sidebar row's close, as its cross and menu call it.
            browser.shut(tab)
            answer(["ok": true]); return true
        case "nav-quit":
            // The same AppKit termination path as Quit, without requiring a
            // foreground key window on the farm. The Leave card still decides.
            answer(["ok": true])
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        case "nav-upload":
            guard let paths = request["paths"] as? [String] else { answer(["error": "paths required"]); return true }
            tab.uploading = (paths.map { URL(fileURLWithPath: $0) }, Date().addingTimeInterval(30))
            answer(["ok": true]); return true
        default: return false
        }
    }
}
