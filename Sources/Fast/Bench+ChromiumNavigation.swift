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
