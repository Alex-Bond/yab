import AppKit
import CoreGraphics
import QuartzCore

// Mail's speed stand (docs/mail.md, Measuring and testing): one of mail's
// keys pressed as the keyboard presses it, in a test world, timed from the
// key to the first frame where what it does reads on screen, not to the end
// of its flight; with the main thread's CPU for it and the frames dropped
// while it plays. `evals/mail/time.py` runs every action on mailboxes of
// 1,000 to 50,000 messages and holds them to their budgets.
//
// The new state is the desk's own (the letter open with its mail, the row
// gone, the field up). Once it holds, the window is laid out and drawn at
// once, as its next commit would be: a window nobody sees (a locked screen)
// isn't drawn by itself. The frame is the display's first tick after that
// commit; a locked screen still ticks and shows nothing, which the answer
// says (`window_visible`, `screen_locked`). A mail's own HTML is WebKit's,
// painted in its own process: `bodies_ms` says when the last of the
// letter's mails finished loading.

@MainActor
enum MailTime {
    /// One press, in ms from the key.
    struct Sample {
        /// The key handled: the app's own work for it, done.
        var handled: Double
        /// The new state laid out and drawn.
        var reached: Double
        /// The commit that holds it, at the end of that pass.
        var commit: Double
        /// The display's first frame after the commit; nil when it didn't tick.
        var frame: Double?
        /// The main thread's CPU from the key to `reached`, and over the
        /// whole settle after it, the flight included.
        var cpu: Double
        var cpuSettle: Double
        var dropped: Int
        var bodies: Double?
        /// Where `cpu` went: the key handled (the desk's own work and what
        /// SwiftUI did inside it), the window laid out, drawn; and the CPU
        /// to the end of the commit that holds it, Core Animation drawing
        /// the layers that changed.
        var cpuKey: Double = 0
        var cpuLayout: Double = 0
        var cpuDraw: Double = 0
        var cpuCommit: Double?
    }

    /// One of mail's keys: where it starts from, the key, the state it
    /// brings, and back to where the next press starts.
    struct Act {
        var start: () -> Void = {}
        var prepare: (Int) -> Bool
        var key: (Int) -> String
        var reached: () -> Bool
        var after: (Int) -> Void = { _ in }
        var finish: () -> Void = {}
        /// Typed into the search's field as its binding takes a key: the
        /// field editor of a window nobody sees keeps words SwiftUI hasn't
        /// put in it yet, and a key would land after them.
        var types = false
        /// Typed into a draft's words, the window's first responder: through
        /// the app as the keyboard types, or to the window itself when the
        /// app has no key window (a probe that isn't the active app).
        var writes = false
    }

    static let actions = ["open", "back", "j", "k", "e", "h", "search", "list", "compose", "send", "type"]

    /// When a mail's own HTML last finished loading (MailBody), for
    /// `bodies_ms`.
    static var bodyLoaded: CFTimeInterval = 0

    // MARK: - the verb

    /// `mail-time`: `action` one of `actions` with `runs` (10) and `settle`
    /// seconds between presses (0.6), `from` the first press's number when
    /// a long series comes in parts; or `load` (a generated mailbox from
    /// the fake's /fake/dump, `dump` and `base` for the account after) and
    /// `status`. A --test run only.
    static func command(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "mail-time only works on a --test run"]); return }
        let action = request["action"] as? String ?? ""
        switch action {
        case "load":
            guard let dump = (request["dump"] as? String).flatMap(URL.init(string:)),
                  let base = (request["base"] as? String).flatMap(URL.init(string:)) else {
                answer(["error": "load needs the fake's dump and its Gmail base"]); return
            }
            let account = (request["account"] as? String ?? "me@example.com").lowercased()
            load(dump, base: base, account: account, browser: browser)
            answer(["loading": true, "account": account])
        case "status":
            var out: [String: Any] = ["loading": loading.going, "loaded": loading.count, "total": loading.total, "error": loading.error ?? ""]
            if let engine = MailCenter.shared.engines.values.first {
                out["messages"] = engine.store.messageIDs().count
                out["threads"] = engine.store.threadCount()
            }
            out["synced"] = MailCenter.shared.status.values.compactMap { $0.synced?.timeIntervalSince1970 }.max() ?? 0
            out["rows"] = MailDesk.shared.rows.count
            out["split"] = MailList.shared.split
            answer(out)
        default:
            guard let act = self.act(action, browser: browser) else {
                answer(["error": "mail-time action: " + (actions + ["load", "status"]).joined(separator: ", ")]); return
            }
            guard browser.inMail, browser.mailPageTab != nil, let window = Links.window else {
                answer(["error": "mail-time needs mail's space in front (agent-mail-space act=enter)"]); return
            }
            let runs = max(1, min(request["runs"] as? Int ?? 10, 100))
            let settle = max(0.2, min(request["settle"] as? Double ?? 0.6, 3))
            measure(action, act, from: max(0, request["from"] as? Int ?? 0), runs: runs, settle: settle, window: window, answer: answer)
        }
    }

    // MARK: - a mailbox loaded whole

    private static var loading: (going: Bool, count: Int, total: Int, error: String?) = (false, 0, 0, nil)

    /// Every message the fake keeps, as Gmail gives them, put in the
    /// account's store a page at a time with the history where the fake
    /// stands, then the account in: its first sync is a refresh with
    /// nothing new, as on a Mac that has kept the mailbox for years.
    private static func load(_ dump: URL, base: URL, account: String, browser: Browser) {
        loading = (true, 0, 0, nil)
        let file = MailStore.file(for: account)
        Task.detached(priority: .userInitiated) {
            do {
                let store = MailStore(file: file)
                var offset = 0, total = 1
                while offset < total {
                    var parts = URLComponents(url: dump, resolvingAgainstBaseURL: false)
                    parts?.queryItems = [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "5000")]
                    guard let url = parts?.url else { throw MailTrouble.unreadable }
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MailTrouble.unreadable }
                    let json = page["messages"] as? [[String: Any]] ?? []
                    store.put(json.compactMap { one in
                        MailGmail.message(one, full: (one["payload"] as? [String: Any])?["parts"] != nil)
                    })
                    if offset == 0 {
                        store.set("me", page["me"] as? String ?? account)
                        store.set("history", page["history"] as? String ?? "")
                    }
                    total = page["total"] as? Int ?? 0
                    offset += max(json.count, 1)
                    let done = min(offset, total)
                    await MainActor.run { loading.count = done; loading.total = total }
                }
                store.set("synced", String(Date().timeIntervalSince1970))
                await MainActor.run {
                    loading.going = false
                    browser.prefs.usesMail = true
                    MailCenter.shared.add(account, gmail: MailGmail(base: base, token: { "fake" }, tries: 2, wait: 0.1))
                    MailCenter.shared.pinOnce(in: browser)
                }
            } catch {
                await MainActor.run { loading = (false, loading.count, loading.total, String(describing: error)) }
            }
        }
    }

    // MARK: - the actions

    private static var desk: MailDesk { MailDesk.shared }

    /// The list in front, nothing over it, the keys the page's.
    private static func toList(_ browser: Browser) {
        if browser.editing { browser.close() }
        if desk.searching { MailSearch.shared.close() }
        if desk.draft != nil { desk.closeDraft() }
        if desk.screen != .list { desk.back() }
        keys(browser)
    }

    /// The keys the page's, as a hand on the list has them: no field keeps them.
    private static func keys(_ browser: Browser) {
        guard let window = Links.window else { return }
        if let web = browser.mailPageTab?.page, web.window === window { window.makeFirstResponder(web) } else { window.makeFirstResponder(nil) }
    }

    private static func act(_ action: String, browser: Browser) -> Act? {
        // How far down the list J and K, E and H go before starting again.
        let reach = { min(12, desk.rows.count) }
        var target = ""
        var typed = ""
        var length = 0
        var placed = false
        switch action {
        case "open":
            return Act(prepare: { n in
                toList(browser)
                guard reach() > 0 else { return false }
                desk.sel = n % reach()
                target = desk.rows[desk.sel].id
                return true
            }, key: { _ in "return" }, reached: {
                desk.screen == .thread && desk.open?.id == target && !desk.messages.isEmpty
            }, after: { _ in desk.back() })
        case "back":
            // esc from a thread opened from the list: the list there again,
            // the row it was opened from chosen.
            return Act(prepare: { n in
                toList(browser)
                guard reach() > 0 else { return false }
                desk.sel = n % reach()
                target = desk.rows[desk.sel].id
                desk.show(desk.rows[desk.sel])
                keys(browser)
                return desk.screen == .thread
            }, key: { _ in "escape" }, reached: {
                desk.screen == .list && desk.rows.indices.contains(desk.sel) && desk.rows[desk.sel].id == target
            })
        case "j", "k":
            let by = action == "j" ? 1 : -1
            return Act(prepare: { _ in
                if desk.searching || desk.draft != nil || browser.editing { toList(browser) }
                guard reach() > 1 else { return false }
                // From the first thread down, or the twelfth up, again at the end.
                let at = desk.screen == .thread ? desk.open.flatMap { open in desk.rows.firstIndex { $0.id == open.id } } : nil
                if at.map({ by > 0 ? $0 >= reach() - 1 : $0 <= 0 }) ?? true {
                    desk.show(desk.rows[by > 0 ? 0 : reach() - 1], push: false)
                }
                guard let now = desk.open.flatMap({ open in desk.rows.firstIndex { $0.id == open.id } }),
                      desk.rows.indices.contains(now + by) else { return false }
                target = desk.rows[now + by].id
                keys(browser)
                return true
            }, key: { _ in action }, reached: {
                desk.open?.id == target && !desk.messages.isEmpty
            }, finish: { toList(browser) })
        case "e":
            return Act(prepare: { n in
                toList(browser)
                guard reach() > 0 else { return false }
                desk.sel = n % min(4, reach())
                guard desk.rows[desk.sel].real else { return false }
                target = desk.rows[desk.sel].id
                return true
            }, key: { _ in "e" }, reached: {
                !desk.rows.contains { $0.id == target }
            }, after: { _ in desk.undoLast() })
        case "h":
            return Act(prepare: { n in
                toList(browser)
                guard reach() > 0 else { return false }
                desk.sel = n % min(4, reach())
                return desk.rows[desk.sel].real
            }, key: { _ in "h" }, reached: {
                browser.editing && browser.query.place == .mail && browser.query.stock.mail?.mode == .remind
            }, after: { _ in browser.close() })
        case "search":
            // A word typed a letter at a time: each letter one press.
            let words = ["deck", "invoice", "launch", "pricing", "review", "friday"]
            return Act(start: {
                toList(browser)
                desk.searching = true
            }, prepare: { n in
                if !desk.searching { desk.searching = true }
                let word = words[(n / 4) % words.count]
                typed = String(word.prefix(n % 4 + 1))
                // The word so far, whichever press this is: the key adds one letter.
                MailSearch.shared.typed = String(typed.dropLast())
                return true
            }, key: { _ in String(typed.last ?? "a") }, reached: {
                // The rows under the field are the word's, not the last letter's.
                MailSearch.shared.typed == typed && MailSearch.shared.answered == typed && MailSearch.shared.hits.first?.id == "words:" + typed
            }, finish: {
                MailSearch.shared.typed = ""
                MailSearch.shared.close()
            }, types: true)
        case "list":
            return Act(start: { MailList.shared.split = "needs" }, prepare: { _ in
                toList(browser)
                // ⇥'s next, as the column orders its lists and splits.
                let order = MailList.shared.tabbed
                target = order[((order.firstIndex(of: MailList.shared.split) ?? 0) + 1) % max(1, order.count)]
                return true
            }, key: { _ in "tab" }, reached: {
                MailList.shared.split == target && desk.screen == .list
            }, finish: { MailList.shared.split = "needs" })
        case "compose":
            return Act(prepare: { _ in toList(browser); return true }, key: { _ in "c" }, reached: {
                desk.screen == .compose && desk.draft != nil
            }, after: { _ in desk.closeDraft() })
        case "send":
            return Act(prepare: { n in
                toList(browser)
                desk.compose()
                guard desk.draft != nil else { return false }
                desk.draft?.to = "tim@okafor.co"
                desk.draft?.subject = "Timed \(n + 1)"
                desk.draft?.body = "Sent by the speed stand, run \(n + 1)."
                desk.save()
                return true
            }, key: { _ in "cmd+return" }, reached: {
                desk.draft == nil && desk.screen != .compose
            })
        case "type":
            // A letter typed in the middle of a long mail with marks, as
            // writing one again is: the letter in the words and drawn.
            let letters = Array("then we go on as planned ")
            return Act(start: {
                toList(browser)
                desk.compose()
                let html = longDraft()
                desk.draft?.to = "tim@okafor.co"
                desk.draft?.subject = "Typed by the speed stand"
                desk.draft?.html = html
                desk.draft?.body = MailRich.text(MailRich.trimmed(MailRich.doc(html: html)))
            }, prepare: { _ in
                guard desk.screen == .compose, let words = desk.words, let window = words.window else { return false }
                if window.firstResponder !== words { window.makeFirstResponder(words) }
                let text = words.string as NSString
                if !placed {
                    // At the end of the paragraph in the middle; the caret
                    // moves on with each letter from there.
                    let middle = text.paragraphRange(for: NSRange(location: text.length / 2, length: 0))
                    words.setSelectedRange(NSRange(location: max(middle.location, middle.upperBound - 1), length: 0))
                    placed = true
                }
                length = text.length
                return true
            }, key: { n in
                let letter = letters[n % letters.count]
                return letter == " " ? "space" : String(letter)
            }, reached: {
                (desk.words?.string as NSString?)?.length == length + 1
            }, finish: { desk.closeDraft() }, writes: true)
        default:
            return nil
        }
    }

    /// A long mail with marks for `type`: a hundred paragraphs of 36 words,
    /// some bold, some links, a bulleted list of six every ten paragraphs
    /// and a quote every 25; some 3,700 words.
    private static func longDraft() -> String {
        let words = "we looked again at the plan for the launch and the numbers for the quarter and here is where it stands after the call with the team on Friday"
            .split(separator: " ").map(String.init)
        var html = ""
        for paragraph in 0..<100 {
            var line: [String] = []
            for n in 0..<36 {
                let word = words[(paragraph * 7 + n) % words.count]
                if n % 9 == 4 {
                    line.append("<b>" + word + "</b>")
                } else if n % 13 == 6 {
                    line.append("<a href=\"https://fold.studio/notes/\(paragraph)\">" + word + "</a>")
                } else {
                    line.append(word)
                }
            }
            html += "<p>" + line.joined(separator: " ") + ".</p>"
            if paragraph % 10 == 5 {
                html += "<ul>"
                for item in 1...6 { html += "<li>Point \(item) of part \(paragraph / 10 + 1), <i>kept short</i></li>" }
                html += "</ul>"
            }
            if paragraph % 25 == 12 { html += "<blockquote>As you wrote on Monday: the numbers come first, then the words.</blockquote>" }
        }
        return html
    }

    // MARK: - timing

    private static func measure(_ action: String, _ act: Act, from first: Int, runs: Int, settle: Double, window: NSWindow,
                                answer: @escaping ([String: Any]) -> Void) {
        guard let view = window.contentView else { answer(["error": "no window"]); return }
        let pacer = Pacer()
        let link = view.displayLink(target: pacer, selector: #selector(Pacer.tick(_:)))
        link.add(to: .main, forMode: .common)
        var samples: [Sample] = []
        var skipped = 0
        act.start()

        func finish() {
            link.invalidate()
            act.finish()
            answer(report(action, samples, skipped: skipped, frames: pacer.times.count, window: window))
        }

        func next(_ n: Int) {
            guard n < first + runs, skipped < runs else { return finish() }
            guard act.prepare(n) else {
                skipped += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) { next(n + 1) }
                return
            }
            // What preparing set going lands first, then the key.
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                press(act, n, settle: settle, window: window, view: view, pacer: pacer) { sample in
                    if let sample { samples.append(sample) } else { skipped += 1 }
                    act.after(n)
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle) { next(n + 1) }
                }
            }
        }
        // What starting set going (the search coming up, the first list)
        // lands before the first press is prepared.
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { next(first) }
    }

    /// One press: the key, the state it brings laid out, its commit, its
    /// frame, the CPU, and what the display dropped while it played.
    private static func press(_ act: Act, _ n: Int, settle: Double, window: NSWindow, view: NSView, pacer: Pacer,
                              done: @escaping (Sample?) -> Void) {
        let key = act.key(n)
        guard let (flags, name, typed) = Bench.chord(key) else { return done(nil) }
        let ticked = pacer.times.count
        let t0 = CACurrentMediaTime()
        let cpu0 = Bench.mainCPU()
        if act.types {
            MailSearch.shared.typed += typed ?? name
        } else {
            Bench.send(flags, name, typed, to: window, straight: act.writes && NSApp.keyWindow !== window)
        }
        let handled = CACurrentMediaTime()
        let cpuKey = Bench.mainCPU() - cpu0
        var reached: Double?
        var cpu = 0.0, cpuLaid = 0.0, cpuStart = cpuKey
        var cpuCommit: Double?
        var commit: Double?
        var watch: CFRunLoopObserver?

        func lay() -> Bool {
            guard reached == nil, act.reached() else { return reached != nil }
            // A state that comes after the key (a search's answer): its own
            // pass is laid out from here.
            cpuStart = Bench.mainCPU() - cpu0
            view.layoutSubtreeIfNeeded()
            cpuLaid = Bench.mainCPU() - cpu0
            window.displayIfNeeded()
            reached = CACurrentMediaTime()
            cpu = Bench.mainCPU() - cpu0
            return true
        }

        func end() {
            if let watch { CFRunLoopRemoveObserver(CFRunLoopGetMain(), watch, .commonModes) }
            watch = nil
            guard let reached else { return done(nil) }
            let stop = t0 + settle
            let wait = max(0, stop - CACurrentMediaTime())
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                let times = Array(pacer.times.dropFirst(ticked))
                let committed = commit ?? reached
                let frame = times.first { $0 > committed }
                let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
                let refresh = pacer.frame
                let bodies = bodyLoaded > t0 ? bodyLoaded : nil
                let ms = { (at: Double) in (at - t0) * 1000 }
                done(Sample(handled: ms(handled), reached: ms(reached), commit: ms(committed), frame: frame.map(ms),
                            cpu: cpu, cpuSettle: Bench.mainCPU() - cpu0, dropped: gaps.filter { $0 > refresh * 1.5 }.count,
                            bodies: bodies.map(ms), cpuKey: cpuKey, cpuLayout: cpuLaid - cpuStart, cpuDraw: cpu - cpuLaid,
                            cpuCommit: cpuCommit))
            }
        }

        _ = lay()
        // Each pass of the main run loop from here, after its commit: the
        // state checked until it holds, then the commit that has it. One
        // that holds only now, after this pass's commit, is committed at
        // once rather than when something next wakes the run loop.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                guard watch != nil else { return }
                if reached != nil {
                    commit = CACurrentMediaTime()
                    cpuCommit = Bench.mainCPU() - cpu0
                    end()
                } else if lay() {
                    CATransaction.flush()
                    commit = CACurrentMediaTime()
                    cpuCommit = Bench.mainCPU() - cpu0
                    end()
                }
            }
        }
        watch = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // A state that never comes: given up after three seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if watch != nil, reached == nil { end() } }
    }

    // MARK: - the answer

    static func report(_ action: String, _ samples: [Sample], skipped: Int, frames: Int, window: NSWindow) -> [String: Any] {
        let framed = samples.compactMap(\.frame)
        let measured = framed.count == samples.count && !samples.isEmpty ? "frame" : "commit"
        var out: [String: Any] = [
            "action": action, "runs": samples.count, "skipped": skipped, "measured": measured,
            "ms": spread(measured == "frame" ? framed : samples.map(\.commit)),
            "handled_ms": spread(samples.map(\.handled)), "reached_ms": spread(samples.map(\.reached)),
            "commit_ms": spread(samples.map(\.commit)),
            "cpu_ms": spread(samples.map(\.cpu)), "cpu_settle_ms": spread(samples.map(\.cpuSettle)),
            "cpu_key_ms": spread(samples.map(\.cpuKey)), "cpu_layout_ms": spread(samples.map(\.cpuLayout)),
            "cpu_draw_ms": spread(samples.map(\.cpuDraw)), "cpu_commit_ms": spread(samples.compactMap(\.cpuCommit)),
            "dropped": samples.map(\.dropped).reduce(0, +), "frames_ticked": frames,
            "window_visible": window.occlusionState.contains(.visible), "app_active": NSApp.isActive,
            "screen_locked": screenLocked, "still": MailDesk.still,
            "samples": samples.map { sample -> [String: Any] in
                ["handled": round(sample.handled), "reached": round(sample.reached), "commit": round(sample.commit),
                 "frame": sample.frame.map(round) ?? NSNull(), "cpu": round(sample.cpu), "cpu_settle": round(sample.cpuSettle),
                 "dropped": sample.dropped, "bodies": sample.bodies.map(round) ?? NSNull(),
                 "cpu_key": round(sample.cpuKey), "cpu_layout": round(sample.cpuLayout), "cpu_draw": round(sample.cpuDraw),
                 "cpu_commit": sample.cpuCommit.map(round) ?? NSNull()]
            },
        ]
        if !framed.isEmpty { out["frame_ms"] = spread(framed) }
        let bodies = samples.compactMap(\.bodies)
        if !bodies.isEmpty { out["bodies_ms"] = spread(bodies) }
        if action == "search" { out["typed_by"] = "field" }
        // The keyboard's way through the app, or straight to the window.
        if action == "type" { out["typed_by"] = NSApp.keyWindow === window ? "app" : "window" }
        if let engine = MailCenter.shared.engines.values.first { out["messages"] = engine.store.messageIDs().count }
        return out
    }

    /// p50, p95 and the worst, nearest-rank, in ms to a tenth.
    static func spread(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        let at = { (p: Double) in sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
        return ["p50": round(at(0.5)), "p95": round(at(0.95)), "max": round(sorted.last ?? 0)]
    }

    private static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// The screen's lock, as the session says it: the window isn't seen
    /// then, whatever the display ticks.
    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
