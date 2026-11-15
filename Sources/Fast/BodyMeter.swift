import AppKit

// How many times SwiftUI ran each view's body, on a test run, so a change
// to how the window observes its state can be counted rather than guessed
// (docs/state-observation.md, evals/perf/bodies.py).
//
// The counts come from `let _ = BodyMeter.tick("File.Type")` lines that
// evals/perf/instrument_bodies.py writes into every body of a farm job's
// own copy of the sources before it builds; they are never committed. A
// handful of views count without it through StripRenderMeter.
@MainActor
enum BodyMeter {
    static let on = Store.testing
    private(set) static var counts: [String: Int] = [:]

    @inline(__always)
    static func tick(_ name: StaticString) {
        guard on else { return }
        counts[name.description, default: 0] += 1
    }

    static func reset() { counts = [:] }

    /// Every count, and their sum.
    static var report: [String: Any] {
        ["total": counts.values.reduce(0, +), "views": counts]
    }
}

extension Bench {
    /// `bodies`: reset the counts, read them, or do one of the everyday
    /// changes the eval counts and read them once the window has settled.
    ///
    ///     act=reset                 counts to zero
    ///     act=read [wait=S]         the counts, S seconds on (0.5)
    ///     act=pref-quiet            a setting nothing in the window draws (⌘Q's warning)
    ///     act=pref-glyph            a setting the tabs draw (letters or icons)
    ///     act=title                 the tab in front's page retitles itself
    ///     act=reload                the tab in front loaded again, read once it has
    ///
    /// Each act but reset and read resets first, so the answer is that
    /// change's alone. Test runs only.
    func bodiesCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "bodies only works on a --test run"]); return }
        let act = request["act"] as? String ?? "read"
        let wait = request["wait"] as? Double ?? 0.5
        func read(after seconds: Double = wait) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { answer(BodyMeter.report) }
        }
        switch act {
        case "reset":
            BodyMeter.reset()
            answer(["reset": true])
        case "read":
            read()
        case "pref-quiet":
            BodyMeter.reset()
            browser.prefs.warnsOnQuit.toggle()
            read()
        case "pref-glyph":
            BodyMeter.reset()
            browser.prefs.glyph = browser.prefs.glyph == .icons ? .letters : .icons
            read()
        case "title":
            guard let tab = browser.active, let web = tab.builtPage else { answer(["error": "title needs a loaded tab in front"]); return }
            BodyMeter.reset()
            let words = "Retitled \(Int.random(in: 1000...9999))"
            web.run("document.title = \(Bench.jsString(words)); 1") { _ in }
            read()
        case "reload":
            guard let tab = browser.active, tab.builtPage != nil else { answer(["error": "reload needs a loaded tab in front"]); return }
            BodyMeter.reset()
            tab.page.reload(fromOrigin: false)
            let started = Date()
            func done() {
                if (tab.loading || Date().timeIntervalSince(started) < 0.2) && Date().timeIntervalSince(started) < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done() }
                } else {
                    read()
                }
            }
            done()
        case "type":
            // Into the editor that has the cursor, ⌘T's field's, a letter a
            // run-loop turn apart (60 ms), as a person types, not all in one.
            guard let editor = Links.window?.firstResponder as? NSTextView, editor.isFieldEditor else {
                answer(["error": "type needs a field with the cursor"]); return
            }
            BodyMeter.reset()
            let letters = Array(request["text"] as? String ?? "hello")
            func next(_ index: Int) {
                guard index < letters.count else { return read() }
                editor.insertText(String(letters[index]), replacementRange: editor.selectedRange())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { next(index + 1) }
            }
            next(0)
        case "open", "link":
            // A new tab in front on url (as the stand's open tab), or the
            // tab in front following a link to it, read once the page has
            // loaded; an opened tab is closed after, uncounted, and the one
            // under it brought back.
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "\(act) needs a url"]); return
            }
            let under = browser.active
            BodyMeter.reset()
            let tab: Tab
            if act == "open" {
                tab = browser.open(url, foreground: true, atEnd: true)
            } else {
                guard let front = browser.active, let web = front.builtPage else { answer(["error": "link needs a loaded tab in front"]); return }
                tab = front
                web.run("location.href = \(Bench.jsString(url.absoluteString)); 1") { _ in }
            }
            let started = Date()
            func done() {
                let waited = Date().timeIntervalSince(started)
                if (tab.loading || tab.address != url || waited < 0.2) && waited < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done() }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    answer(BodyMeter.report)
                    if act == "open" {
                        browser.close(tab)
                        if let under, browser.tabs.contains(where: { $0.id == under.id }) { browser.select(under) }
                    }
                }
            }
            done()
        default:
            answer(["error": "bodies act is reset, read, pref-quiet, pref-glyph, title, reload, type, open or link"])
        }
    }

    nonisolated static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
