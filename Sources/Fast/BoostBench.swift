import AppKit
import SwiftUI
import WebKit

extension Bench {
    func boostProbe(_ request: [String: Any], browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing, request["session"] == nil else { answer(["error": "This is a native test-only control."]); return }
        if request["action"] as? String == "editor" {
            boostEditorProbe(request, browser: browser, answer: answer)
            return
        }
        if request["action"] as? String == "add-menu" {
            // The real Add button's anchor in Site Controls, for app-local
            // presses. Connection overrides stay inside disposable test worlds.
            if let connected = request["connected"] as? Bool {
                Agents.connectedInTests = connected
                Agents.assumedInTests = connected
            }
            if request["cancelPicker"] as? Bool == true { (NSApp.modalWindow as? NSOpenPanel)?.cancel(nil) }
            func anchor(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == BoostAddMenu.anchorID { return view }
                return view.subviews.lazy.compactMap { anchor($0) }.first
            }
            var out = ActionMenu.state()
            out["connected"] = Agents.connected
            out["siteControls"] = ExtensionPanel.shared.isShown
            out["draft"] = browser.chatAttach.words
            out["chatOpen"] = browser.chatOpen
            out["place"] = browser.fieldShowing ? browser.query.place?.rawValue ?? "" : ""
            out["filePicker"] = NSApp.modalWindow is NSOpenPanel
            for window in NSApp.windows where window.isVisible {
                guard let content = window.contentView, let view = anchor(content) else { continue }
                let rect = view.convert(view.bounds, to: content)
                out["anchorWindow"] = window.windowNumber
                out["anchor"] = [rect.minX, content.isFlipped ? rect.minY : content.bounds.height - rect.maxY, rect.width, rect.height]
                break
            }
            answer(out)
            return
        }
        let boosts = Boosts.shared
        if request["action"] as? String == "catalog" {
            answer(["entries": BoostCatalog.entries.map { entry -> [String: Any] in
                let payload = BoostShare.Payload(format: 1, id: entry.id, sites: [entry.site], files: entry.files)
                return ["id": entry.id, "site": entry.site, "url": entry.url.absoluteString, "files": entry.files,
                        "revision": (try? BoostShare.digest(payload)) ?? ""]
            }]); return
        }
        if request["action"] as? String == "person" {
            // A tab of the person's own, in front, as theirs would be.
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else { answer(["error": "person needs a url"]); return }
            answer(["id": Bench.short(browser.open(url, foreground: true))]); return
        }
        if ["trials", "keep-trial"].contains(request["action"] as? String) {
            // Every boost on trial, whoever's tab it is in (an agent's, in a
            // folder too): what its card shows, and with "keep-trial" its
            // Keep pressed as the card's button presses it, only when that
            // button is enabled.
            let everyone = BrowserWindows.shared.browsers.flatMap { $0.everyTab + $0.outside } + browser.everyTab + browser.outside
            func state(_ trial: Boosts.Trial, _ tab: Tab?, pictures: Bool) -> [String: Any] {
                var report = trial.report
                if !pictures { report.removeValue(forKey: "before"); report.removeValue(forKey: "after") }
                return ["tab": tab.map(Bench.short) ?? "", "url": trial.url.absoluteString, "name": trial.package.id,
                        "title": trial.package.name, "rung": trial.package.rung.rawValue, "permission": trial.package.permission,
                        "session": trial.session, "ready": trial.ready, "problem": trial.problem ?? "",
                        "keepEnabled": trial.ready && trial.problem == nil, "report": report,
                        // A quiet try's own page, which nobody sees, or the
                        // person's tab a passing one was put on (Boosts.fit).
                        "hidden": tab.map(boosts.isRoom) ?? true, "fitted": trial.fitted, "checked": trial.checked ?? ""]
            }
            let trials = boosts.trials.values.map { trial in (trial, everyone.first { $0.id == trial.tabID }) }
            if request["action"] as? String == "keep-trial" {
                let wanted = (request["id"] as? String ?? "").lowercased()
                guard let found = trials.first(where: { $0.1.map(Bench.short) == wanted }), let tab = found.1 else {
                    answer(["error": "no trial in tab \(wanted)"]); return
                }
                let trial = found.0
                guard trial.ready, trial.problem == nil else { answer(["error": "Keep is disabled on this card", "trial": state(trial, tab, pictures: false)]); return }
                Task {
                    await boosts.keep(trial.id, on: tab)
                    answer(["kept": boosts.records.map(\.id), "pending": boosts.trials[tab.id] != nil,
                            "problem": boosts.trials[tab.id]?.problem ?? ""])
                }
                return
            }
            answer(["trials": trials.map { state($0.0, $0.1, pictures: request["pictures"] as? Bool == true) },
                    // The chats that show a passing try's page before and after.
                    "pictured": boosts.pictures.map { ["chat": $0.key, "host": $0.value.host, "tries": $0.value.tries] as [String: Any] },
                    // What the person has in front: the tab row, the tab, the corner.
                    "tabs": browser.tabs.map(Bench.short), "active": browser.active.map(Bench.short) ?? "",
                    "toast": browser.toaster.shown ? browser.toaster.words : "",
                    // A way into making one: the chat it opened, the
                    // question in its place, whether an agent could answer.
                    "chatOpen": browser.chatOpen, "chatDraft": browser.chatDraft ?? "",
                    "question": Questions.shared.current?.title ?? "", "agentReady": Agents.ready,
                    "place": browser.fieldShowing ? browser.query.place?.rawValue ?? "" : "",
                    "records": boosts.records.map { ["id": $0.id, "name": $0.name, "rung": $0.rung.rawValue, "sites": $0.sites, "enabled": $0.enabled] as [String: Any] }])
            return
        }
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        Task {
            switch request["action"] as? String {
            case "spike":
                do { answer(try await BoostSpike.run(tab.address!)) }
                catch { answer(["error": error.localizedDescription]) }

            case "stage":
                let owner = Agents.shared.scripted(); tab.agent = owner.id
                do {
                    answer(try await boosts.stage(name: request["name"] as? String ?? "probe", changes: request["files"] as? [String: Any] ?? [:],
                                                  sites: request["sites"] as? [String] ?? [], tab: tab, session: owner.id))
                } catch { answer(["error": error.localizedDescription]) }
            case "fit":
                // The agent's quiet trial, from this tab, with `target` as the
                // person's tab the chat is about.
                let owner = Agents.shared.scripted(); tab.agent = owner.id
                owner.nativeOriginTab = (request["target"] as? String).flatMap { find(["id": $0], in: browser) }?.id
                do {
                    answer(try await boosts.fit(name: request["name"] as? String ?? "probe", changes: request["files"] as? [String: Any] ?? [:],
                                                sites: request["sites"] as? [String] ?? [], from: tab, session: owner.id,
                                                pages: request["pages"] as? [String] ?? []))
                } catch { answer(["error": error.localizedDescription]) }
            case "rows":
                // The tab row as the person sees it, and what Now has.
                Hints.shared.compose()
                answer(["tabs": browser.tabs.map(Bench.short), "now": Hints.shared.queue.map(\.title)])
            case "card-shot":
                answer(await Self.cardShot(tab, to: request["path"] as? String ?? NSTemporaryDirectory() + "yab-boost-card.png"))
            case "chat-shot":
                answer(Self.chatShot(request["chat"] as? String ?? Agents.script, answer: request["answer"] as? String ?? "",
                                     to: request["path"] as? String ?? NSTemporaryDirectory() + "yab-boost-chat.png"))
            case "keep":
                if let trial = boosts.trials[tab.id] { await boosts.keep(trial.id, on: tab) }
                answer(["kept": boosts.records.map(\.id), "pending": boosts.trials[tab.id] != nil])
            case "undo":
                await boosts.undo(on: tab); answer(["pending": boosts.trials[tab.id] != nil])
            case "enable":
                await boosts.setEnabled(request["name"] as? String ?? "probe", request["enabled"] as? Bool ?? false)
                answer(["ok": true])
            case "delete":
                await boosts.delete(request["name"] as? String ?? "probe"); answer(["ok": true])
            case "developer-mode":
                guard tab.address?.host == "127.0.0.1" else { answer(["error": "Only the loopback fixture can change its test mode."]); return }
                browser.setDevMode(tab, request["enabled"] as? Bool ?? false)
                answer(["enabled": tab.isDev])
            case "tool":
                let owner = Agents.shared.scripted(); tab.agent = owner.id
                answer(await BoostTools.run(request["tool"] as? String ?? "", arguments: request["arguments"] as? [String: Any] ?? [:],
                                            requestID: request["requestID"] as? String ?? UUID().uuidString, session: owner.id, browser: browser))
            case "approve-tool":
                guard let permit = tab.permit, permit.session == Agents.script else { answer(["error": "No test action awaits approval."]); return }
                if case .press(_, let ref) = permit.kind {
                    tab.approved = (Agents.script, ref, Date()); tab.permit = nil; answer(["ok": true])
                } else { answer(["error": "Only the fixture's tool action may be approved."]) }
            case "app":
                guard let id = request["name"] as? String, let package = boosts.packages[id], let url = BoostApp.url(package) else { answer(["error": "No plugin app."]); return }
                let opened = browser.open(url, foreground: true); answer(["id": Bench.short(opened), "url": url.absoluteString])
            case "service":
                let key = "boosts.service." + (request["name"] as? String ?? "")
                var result: [String: Any] = ["state": Store.settings.string(forKey: key + ".state") ?? ""]
                if let error = Store.settings.string(forKey: key + ".error"), !error.isEmpty { result["error"] = error }
                answer(result)
            case "contributions":
                let id = "boost:probe:command"
                if request["disable"] as? Bool == true, let index = browser.selectionCommands.commands.firstIndex(where: { $0.id == id }) {
                    browser.selectionCommands.commands[index].enabled = false; browser.selectionCommands.save()
                }
                answer(["commands": browser.selectionCommands.commands.filter { $0.id.hasPrefix("boost:probe:") }.count,
                        "commandEnabled": browser.selectionCommands.commands.first(where: { $0.id == id })?.enabled ?? false,
                        "actions": QuickActions.shared.actions.filter { $0.id.hasPrefix("boost:probe:") }.count,
                        "routines": Routines.shared.all.filter { $0.id.hasPrefix("boost:probe:") }.count])
            case "report":
                do {
                    guard let web = tab.webKitOnly("Boost report") else { answer(["error": "Boost reports are not available on this engine yet"]); return }
                    let result = try await BoostJavaScript.evaluate(BoostScript.report, on: web, world: Boosts.world(request["name"] as? String ?? "probe"))
                    answer(result as? [String: Any] ?? [:])
                } catch { answer(["error": error.localizedDescription]) }
            default:
                let trial = boosts.trials[tab.id]
                answer(["pending": trial != nil, "fitted": trial?.fitted ?? false, "ready": trial?.ready ?? false,
                        "checked": trial?.checked ?? "", "pictures": boosts.pictures[Agents.script] != nil, "records": boosts.records.map { ["id": $0.id, "enabled": $0.enabled, "revision": $0.revision] as [String: Any] }])
            }
        }
    }

    /// The person's tab as they see it with a boost on trial: the page as
    /// WebKit draws it, and the card over its corner as the window draws it
    /// (PageContent puts BoostTrialView at the top trailing corner).
    private static func cardShot(_ tab: Tab, to path: String) async -> [String: Any] {
        let web = tab.page
        guard let content = web.window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return ["error": "the tab is not on screen"] }
        let image: NSImage? = await withCheckedContinuation { continuation in
            web.snapshot(PageShot()) { image, _ in continuation.resume(returning: image) }
        }
        guard let pageImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return ["error": "no page picture"] }
        // AppKit's own drawing of the window, which has the SwiftUI over the
        // page and leaves the page itself blank (WebKit draws it apart).
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let drawn = rep.cgImage else { return ["error": "no window picture"] }
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width, height = content.bounds.height
        guard let out = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ["error": "no bitmap"] }
        let frame = web.convert(web.bounds, to: content)
        let top = content.isFlipped ? frame.minY : height - frame.maxY
        let card = NSHostingView(rootView: BoostTrialView(tab: tab))
        let tall = card.fittingSize.height, wide = card.fittingSize.width
        // A picture counts from its top, a bitmap context from its bottom.
        out.draw(drawn, in: CGRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
        out.draw(pageImage, in: CGRect(x: frame.minX * scale, y: (height - top - frame.height) * scale, width: frame.width * scale, height: frame.height * scale))
        // The card itself, inside the 16 round it (BoostTrialView's padding).
        let x = frame.maxX - wide + 16, w = wide - 32, h = tall - 32
        if h > 0, let corner = drawn.cropping(to: CGRect(x: x * scale, y: (top + 16) * scale, width: w * scale, height: h * scale)) {
            out.draw(corner, in: CGRect(x: x * scale, y: (height - top - 16 - h) * scale, width: w * scale, height: h * scale))
        }
        guard let image = out.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return ["error": "no png"] }
        return ["path": path, "card": tall]
    }

    /// A chat's answer with the pictures under it (ChatBoostPictures), drawn
    /// the way the column draws them, off screen.
    private static func chatShot(_ chat: String, answer: String, to path: String) -> [String: Any] {
        let view = VStack(alignment: .leading, spacing: 6) {
            ChatWords(text: answer, streaming: false, bubbles: true)
            ChatBoostPictures(chat: chat)
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .background(Palette.ground)
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
