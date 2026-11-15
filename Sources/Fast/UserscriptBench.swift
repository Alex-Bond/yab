import AppKit
import SwiftUI
import WebKit

// MARK: - commands in ⌘T

extension Browser {
    /// The menu commands userscripts registered on the page under the
    /// field, the words naming them, each with its script's name at the
    /// end; and "Turn Off <name> Here" for each script running there.
    func userscriptRows(_ text: String) -> [Suggestion] {
        let words = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard words.count >= 2, let tab = active, !tab.shy, let url = tab.address else { return [] }
        let scripts = Userscripts.shared
        let named = { (title: String) in
            let lower = title.lowercased()
            return lower.contains(words) || lower.split(separator: " ").contains { $0.hasPrefix(words) }
        }
        var rows: [Suggestion] = []
        for record in scripts.on(url, in: AddonProfiles.of(tab)) where record.enabled {
            for command in scripts.commands[tab.id]?[record.id] ?? [] where named(command.caption) {
                rows.append(Suggestion(key: command.caption, title: record.name, url: nil, kind: .page("us:" + record.id + "\u{1F}" + command.id)))
            }
            let off = "Turn Off \(record.name) Here"
            if named(off) || named(record.name) && words.count >= 3 {
                rows.append(Suggestion(key: off, title: "Userscript", url: nil, kind: .page("us-off:" + record.id)))
            }
        }
        return Array(rows.prefix(6))
    }

    func takeUserscriptRow(_ what: String) {
        guard let tab = active else { return }
        if what.hasPrefix("us-off:") {
            Userscripts.shared.turnOff(String(what.dropFirst(7)), in: AddonProfiles.of(tab))
            return
        }
        let parts = what.dropFirst(3).split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        Userscripts.shared.run(parts[1], of: parts[0], in: tab)
    }
}

// MARK: - the bench

extension Bench {
    /// Userscripts driven as a person would (evals/userscripts/check.py):
    /// the card's buttons, Site Controls' rows and ⌘T's commands, with
    /// their pictures. Test worlds only.
    func userscriptProbe(_ request: [String: Any], browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "This is a native test-only control."]); return }
        let scripts = Userscripts.shared
        let action = request["action"] as? String ?? "state"
        let name = request["script"] as? String ?? ""
        let id = scripts.records.first(where: { $0.id == name || $0.name == name })?.id ?? name
        Task {
            switch action {
            case "state":
                answer(userscriptState(browser))
            case "offer":
                guard let tab = find(request, in: browser), let url = (request["url"] as? String).flatMap(URL.init(string:)) else { answer(missing(request)); return }
                scripts.offer(url, in: tab, browser: browser)
                answer(["ok": true])
            case "add-file":
                // Add Userscript… after its open panel, or a file dropped on
                // the list: the same entry the row and the drop call.
                guard let path = request["path"] as? String else { answer(["error": "path is required"]); return }
                scripts.add(URL(fileURLWithPath: path), browser: browser, tab: find(request, in: browser))
                answer(["ok": true])
            case "try":
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                for _ in 0..<600 where scripts.offers[tab.id].map({ !$0.ready && $0.problem == nil }) == true { try? await Task.sleep(for: .milliseconds(100)) }
                await scripts.tryOut(tab, browser: browser)
                answer(userscriptState(browser))
            case "keep":
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                // Its files fetched first, as the card's Keep waits for them.
                for _ in 0..<600 where scripts.offers[tab.id].map({ !$0.ready && $0.problem == nil }) == true { try? await Task.sleep(for: .milliseconds(100)) }
                guard let offer = scripts.offers[tab.id] else { answer(["error": "no card in this tab"]); return }
                guard offer.problem == nil else { answer(["error": "Keep is disabled on this card: " + (offer.problem ?? "")]); return }
                await scripts.keep(tab)
                answer(userscriptState(browser))
            case "dismiss":
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                scripts.dismiss(tab)
                answer(userscriptState(browser))
            case "tampermonkey":
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                scripts.useTampermonkey(tab)
                answer(["ok": true])
            case "enable":
                scripts.setEnabled(id, request["enabled"] as? Bool ?? true)
                answer(userscriptState(browser))
            case "delete":
                scripts.delete(id)
                answer(userscriptState(browser))
            case "values":
                answer(["values": scripts.values(of: id)])
            case "eval":
                // In the script's own world: what ran there, its errors.
                guard let tab = find(request, in: browser), let web = tab.builtPage else { answer(missing(request)); return }
                let inPage = (scripts.scripts[id] ?? scripts.offers[tab.id]?.script)?.inPage ?? false
                do { answer(["value": Bench.plain(try await BoostJavaScript.evaluate(request["js"] as? String ?? "null", on: web, world: scripts.pageWorld(id, inPage: inPage)))]) }
                catch { answer(["error": error.localizedDescription]) }
            case "command":
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                scripts.run(request["command"] as? String ?? "", of: id, in: tab)
                answer(["ok": true])
            case "field":
                // ⌘T's rows for these words over the tab in front, and Return on one.
                let rows = browser.userscriptRows(request["text"] as? String ?? "")
                if let take = request["take"] as? String, let row = rows.first(where: { $0.key == take }), case .page(let what) = row.kind {
                    browser.takeUserscriptRow(what)
                }
                answer(["rows": rows.map { ["key": $0.key, "title": $0.title] }])
            case "check-updates":
                answer(["results": await scripts.checkUpdates(force: true), "dotted": Extensions.shared.dotted])
            case "update":
                await scripts.applyPending(id)
                answer(userscriptState(browser))
            case "move-read":
                if #available(macOS 15.4, *) {
                    let items = (try? await UserscriptMove.fromTampermonkey()) ?? []
                    answer(["items": items.map { ["name": $0.script.name, "how": $0.how, "stays": $0.stays ?? "", "values": $0.values.count, "enabled": $0.enabled] }])
                } else { answer(["items": []]) }
            case "move":
                var items: [UserscriptMove.Item] = []
                var from = "Tampermonkey"
                if let path = request["backup"] as? String {
                    do { items = try UserscriptMove.fromBackup(URL(fileURLWithPath: path)); from = "a backup" }
                    catch { answer(["error": error.localizedDescription]); return }
                } else if #available(macOS 15.4, *) {
                    items = (try? await UserscriptMove.fromTampermonkey()) ?? []
                }
                let done = await UserscriptMove.move(items, from: from)
                answer(["moved": done.moved, "failed": done.failed, "listed": items.map { ["name": $0.script.name, "stays": $0.stays ?? ""] }])
            case "moved-out":
                answer(["moved": UserscriptMove.movedOut(request["code"] as? String ?? "")])
            // What Tampermonkey has registered: each user script file, whether
            // it reads as a moved script, and its start; with the scripts
            // its userScripts list keeps.
            case "tm-registered":
                guard let installed = Userscripts.shared.tampermonkey else { answer(["error": "no Tampermonkey"]); return }
                let folder = Extensions.folder(for: installed.id).appendingPathComponent("_yab", isDirectory: true)
                let files = ((try? FileManager.default.contentsOfDirectory(at: folder.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix(ExtensionShims.userScriptPrefix) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                let list = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("userscripts.json")))) as? [[String: Any]] ?? []
                let uuids = try! NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
                answer(["files": files.map { file -> [String: Any] in
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    let start = text.range(of: "yab_user_script:").map { String(text[$0.lowerBound...].prefix(1200)) } ?? String(text.prefix(400))
                    let needle = request["needle"] as? String ?? ""
                    return ["name": file.lastPathComponent, "bytes": text.utf8.count, "moved": UserscriptMove.movedOut(text), "start": start,
                            "has": !needle.isEmpty && text.contains(needle), "uuids": uuids.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(4).compactMap { Range($0.range, in: text).map { String(text[$0]) } }]
                }, "scripts": list.map { ["id": $0["id"] ?? "", "matches": $0["matches"] ?? [], "js": ($0["js"] as? [[String: Any]] ?? []).map { ($0["code"] as? String).map { String($0.prefix(600)) } ?? ($0["file"] as? String ?? "") }] },
                         "restarts": UserscriptMove.restarts])
            case "card-shot":
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                answer(await Self.userscriptCardShot(tab, browser: browser, to: request["path"] as? String ?? NSTemporaryDirectory() + "yab-userscript-card.png"))
            case "rows-shot":
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                answer(Self.userscriptOffscreen(VStack(alignment: .leading, spacing: 0) { BoostSiteBlock(browser: browser, tab: tab) }
                    .padding(SiteControlsView.inset).frame(width: SiteControlsView.width).background(Palette.ground),
                    to: request["path"] as? String ?? NSTemporaryDirectory() + "yab-userscript-rows.png"))
            case "settings-shot":
                answer(Self.userscriptOffscreen(ThreadForm { UserscriptsSection() }.formStyle(.grouped).frame(width: 620, height: 420),
                                          to: request["path"] as? String ?? NSTemporaryDirectory() + "yab-userscript-settings.png"))
            default:
                answer(["error": "unknown userscript-probe action " + action])
            }
        }
    }

    private func userscriptState(_ browser: Browser) -> [String: Any] {
        let scripts = Userscripts.shared
        let tabs = BrowserWindows.shared.browsers.flatMap { $0.tabs }
        return [
            "records": scripts.records.map { record -> [String: Any] in
                var out: [String: Any] = ["id": record.id, "name": record.name, "version": record.version, "enabled": record.enabled,
                                          "revision": record.revision, "moved": record.moved ?? ""]
                if let pending = record.pending { out["pending"] = ["version": pending.version, "rights": pending.rights] }
                if let script = scripts.scripts[record.id] {
                    out["permission"] = script.permission; out["inPage"] = script.inPage; out["sites"] = script.sites
                    out["requires"] = script.requires.map { ["url": $0.url, "sha256": $0.sha256] }
                }
                out["errors"] = scripts.errors[record.id] ?? []
                out["refused"] = scripts.refused[record.id] ?? []
                return out
            },
            "offers": scripts.offers.values.map { offer -> [String: Any] in
                ["tab": tabs.first { $0.id == offer.tabID }.map(Bench.short) ?? "", "name": offer.script.name, "version": offer.script.version,
                 "permission": offer.script.permission, "facts": offer.facts ?? "", "problem": offer.problem ?? "", "tried": offer.tried,
                 "replaces": offer.replaces ?? "", "requires": offer.script.requires.count]
            },
            "commands": scripts.commands.flatMap { tab, byScript in
                byScript.flatMap { script, list in list.map { ["tab": tabs.first { $0.id == tab }.map(Bench.short) ?? "", "script": script, "id": $0.id, "caption": $0.caption] } }
            },
            "dotted": Extensions.shared.dotted,
            "tampermonkey": scripts.tampermonkey?.id ?? "",
            "trouble": scripts.trouble ?? "",
            "toast": browser.toaster.shown ? browser.toaster.words : "",
        ]
    }

    /// The page with the card over its corner, as BoostBench's card-shot draws it.
    private static func userscriptCardShot(_ tab: Tab, browser: Browser, to path: String) async -> [String: Any] {
        let web = tab.page
        guard let content = web.window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return ["error": "the tab is not on screen"] }
        let image: NSImage? = await withCheckedContinuation { continuation in
            web.snapshot(PageShot()) { image, _ in continuation.resume(returning: image) }
        }
        guard let pageImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return ["error": "no page picture"] }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let drawn = rep.cgImage else { return ["error": "no window picture"] }
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width, height = content.bounds.height
        guard let out = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ["error": "no bitmap"] }
        let frame = web.convert(web.bounds, to: content)
        let top = content.isFlipped ? frame.minY : height - frame.maxY
        let card = NSHostingView(rootView: UserscriptCard(browser: browser, tab: tab))
        let tall = card.fittingSize.height, wide = card.fittingSize.width
        out.draw(drawn, in: CGRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
        out.draw(pageImage, in: CGRect(x: frame.minX * scale, y: (height - top - frame.height) * scale, width: frame.width * scale, height: frame.height * scale))
        let x = frame.maxX - wide + 16, w = wide - 32, h = tall - 32
        if h > 0, let corner = drawn.cropping(to: CGRect(x: x * scale, y: (top + 16) * scale, width: w * scale, height: h * scale)) {
            out.draw(corner, in: CGRect(x: x * scale, y: (height - top - 16 - h) * scale, width: w * scale, height: h * scale))
        }
        guard let image = out.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return ["error": "no png"] }
        return ["path": path, "card": tall]
    }

    /// A view drawn off screen, as the column draws a chat's pictures.
    static func userscriptOffscreen<V: View>(_ view: V, to path: String) -> [String: Any] {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: host.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WindowHosting.measured(host)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return ["error": "no bitmap"] }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return ["error": "no png"] }
        return ["path": path, "height": host.frame.height]
    }
}

extension Browser {
    /// Registered commands only: turning a script off is still found by typing.
    func pageUserscriptRows(on tab: Tab) -> [FieldPageRows.Candidate] {
        guard !tab.shy, let url = tab.address else { return [] }
        let scripts = Userscripts.shared
        return scripts.on(url, in: AddonProfiles.of(tab)).filter(\.enabled).flatMap { record in
            (scripts.commands[tab.id]?[record.id] ?? []).map { command in
                let id = "us:" + record.id + "\u{1F}" + command.id
                return .init(id: id, kind: .userscriptCommands,
                    row: Suggestion(key: command.caption, title: record.name, url: nil, kind: .page(id)))
            }
        }
    }
}
