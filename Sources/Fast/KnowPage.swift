import AppKit
import WebKit

// yab://you: what Yab keeps about you, as a notebook to read and correct
// (docs/get-to-know.md, The notebook). Get to Know ends here: the page is
// the first tab of its shut folder from the first second, and as the run
// ends it steps out into the folder's place, "Nice to meet you, Mira", the
// greeting written by the pen the update note is written in. Later the
// same page is "Notes about you", from Settings › AI › Memory or the card
// under the run's answer in its chat.
//
// Nothing on it is its own: memory's brief and pages, the profile forms
// fill from, the Wallet's addresses, and what the run said it couldn't
// settle or left alone (KnowReport). Crossing out forgets, a fix is kept as
// yours (a profile key you wrote is never written over), and both are
// saved as they happen, with Undo while the page stays open.

/// What the last Get to Know said besides memory, the profile and the
/// Wallet: a line about you, what it couldn't settle, what a page asked it
/// to keep that it left alone, and what it couldn't read.
struct KnowReport: Codable, Equatable {
    struct Choice: Codable, Equatable {
        var answer = ""
        /// The line memory keeps when this one is picked.
        var keep = ""
    }

    struct Doubt: Codable, Equatable {
        var question = ""
        /// What it is about: "phone", "email", or a profile key.
        var about = ""
        var choices: [Choice] = []
        /// The one picked, -1 for none of them, nil while it waits.
        var picked: Int?
        /// What the pick wrote over, put back when the answer changes.
        var was: Was?
    }

    /// Before a pick: the brief's line it added (nil when the line was
    /// there already), the profile key's value, and each address's phone or
    /// email it wrote over.
    struct Was: Codable, Equatable {
        var line: String?
        var value: String?
        var source: String?
        var edited = false
        var addresses: [String: String] = [:]
    }

    struct Left: Codable, Equatable {
        var site = ""
        var url = ""
        var said = ""
    }

    struct Skipped: Codable, Equatable {
        var site = ""
        var why = ""
    }

    /// One sentence of your story, said to you: its words, links to other
    /// pages as `[[people/…|Name]]` and `[[sites/host|Name]]`, and the line
    /// of the brief it says, so crossing it out or fixing it changes memory.
    struct Sentence: Codable, Equatable {
        var text = ""
        /// The brief's line as written, when the sentence says one.
        var line = ""
        /// Your words in its place, once fixed.
        var fixed: String?
        var gone = false

        init(text: String = "", line: String = "") { self.text = text; self.line = line }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = ((try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil) ?? ""
            line = ((try? c.decodeIfPresent(String.self, forKey: .line)) ?? nil) ?? ""
            fixed = (try? c.decodeIfPresent(String.self, forKey: .fixed)) ?? nil
            gone = ((try? c.decodeIfPresent(Bool.self, forKey: .gone)) ?? nil) ?? false
        }
    }

    /// A mark the pen draws by what it means: by a sentence ("s2.1", its
    /// paragraph and place) or a person ("people/katya.md").
    struct Doodle: Codable, Equatable {
        static let marks = ["star", "coffee", "rocket", "heart", "spark"]
        var at = ""
        var mark = ""
    }

    /// Something Yab can set up from what the run read, and why. `kind` is
    /// one of `Setup.kinds`; `what` says what to make, by kind (docs/get-to-know.md,
    /// Set up for you).
    struct Setup: Codable, Equatable {
        static let kinds = ["live", "action", "routine", "snippet", "space"]
        var id = ""
        var kind = ""
        var title = ""
        var why = ""
        /// The sentence it came from ("s1.0"), for "see note".
        var from = ""
        var what: [String: String] = [:]
        /// "added" or "away" once you've said, nil while it is offered.
        var state: String?
    }

    var at = Date()
    var minutes = 0
    var sites = 0
    var portrait = ""
    var story: [[Sentence]] = []
    var doodles: [Doodle] = []
    var setups: [Setup] = []
    var doubts: [Doubt] = []
    var left: [Left] = []
    var skipped: [Skipped] = []
    /// The page has been written out once: after that it opens at rest.
    var seen = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? nil ?? Date()
        minutes = ((try? c.decodeIfPresent(Int.self, forKey: .minutes)) ?? nil) ?? 0
        sites = ((try? c.decodeIfPresent(Int.self, forKey: .sites)) ?? nil) ?? 0
        portrait = ((try? c.decodeIfPresent(String.self, forKey: .portrait)) ?? nil) ?? ""
        story = ((try? c.decodeIfPresent([[Sentence]].self, forKey: .story)) ?? nil) ?? []
        doodles = ((try? c.decodeIfPresent([Doodle].self, forKey: .doodles)) ?? nil) ?? []
        setups = ((try? c.decodeIfPresent([Setup].self, forKey: .setups)) ?? nil) ?? []
        doubts = ((try? c.decodeIfPresent([Doubt].self, forKey: .doubts)) ?? nil) ?? []
        left = ((try? c.decodeIfPresent([Left].self, forKey: .left)) ?? nil) ?? []
        skipped = ((try? c.decodeIfPresent([Skipped].self, forKey: .skipped)) ?? nil) ?? []
        seen = ((try? c.decodeIfPresent(Bool.self, forKey: .seen)) ?? nil) ?? false
    }

    static var file: URL { Store.file("know.json") }

    /// A run has written one, and nothing has forgotten it since.
    static var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func load() -> KnowReport? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KnowReport.self, from: data)
    }

    @discardableResult
    static func save(_ report: KnowReport) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// What `know_report` was handed, kept short: a line of two sentences,
    /// three questions of two or three answers, a few things left alone.
    static func given(_ input: [String: Any]) -> KnowReport {
        func text(_ any: Any?, _ limit: Int) -> String {
            let t = (any as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " \u{2014} ", with: ", ").replacingOccurrences(of: "\u{2014}", with: ", ")
            return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
        }
        // The line a pick keeps is one line of the brief: no list mark or
        // heading of its own, so it is written, and taken back, as itself.
        func line(_ any: Any?) -> String {
            let flat = (any as? String ?? "").components(separatedBy: .newlines).joined(separator: " ")
            let bare = flat.replacingOccurrences(of: #"^[\s\-*•#>]+"#, with: "", options: .regularExpression)
            return text(bare, 200)
        }
        var report = KnowReport()
        report.portrait = text(input["portrait"], 320)
        report.doubts = (input["doubts"] as? [[String: Any]] ?? []).compactMap { raw -> Doubt? in
            let choices = (raw["choices"] as? [[String: Any]] ?? []).prefix(3).compactMap { choice -> Choice? in
                let answer = text(choice["answer"], 90)
                return answer.isEmpty ? nil : Choice(answer: answer, keep: line(choice["keep"]))
            }
            let question = text(raw["question"], 120)
            guard !question.isEmpty, choices.count >= 2 else { return nil }
            return Doubt(question: question, about: about(text(raw["about"], 30)), choices: Array(choices))
        }.prefix(3).map { $0 }
        // Your story: a few short paragraphs said to you, each sentence with
        // the brief's line it says. A paragraph may come as bare sentences.
        report.story = (input["story"] as? [Any] ?? []).prefix(5).compactMap { paragraph -> [Sentence]? in
            let said = (paragraph as? [Any] ?? []).prefix(4).compactMap { raw -> Sentence? in
                let words: String, kept: String
                if let raw = raw as? [String: Any] { words = text(raw["text"], 280); kept = line(raw["line"]) }
                else { words = text(raw, 280); kept = "" }
                guard !words.isEmpty else { return nil }
                // The line as written in the brief, list mark and all, when it is one.
                let written = kept.isEmpty ? "" : KnowNotes.lines(in: "USER.md").first { $0.contains(kept) || KnowNotes.plain($0) == KnowNotes.plain(kept) } ?? ""
                return Sentence(text: words, line: written)
            }
            return said.isEmpty ? nil : Array(said)
        }
        let places = Set(report.story.indices.flatMap { p in report.story[p].indices.map { "s\(p).\($0)" } })
        var marked = Set<String>(), spots = Set<String>()
        report.doodles = (input["doodles"] as? [[String: Any]] ?? []).compactMap { raw -> Doodle? in
            let mark = text(raw["mark"], 12).lowercased(), at = text(raw["at"], 120)
            // A sentence it marks, or a person's page; one mark of each kind, one a place.
            guard Doodle.marks.contains(mark), !marked.contains(mark), !spots.contains(at),
                  places.contains(at) || at.hasPrefix("people/") else { return nil }
            marked.insert(mark); spots.insert(at)
            return Doodle(at: at, mark: mark)
        }.prefix(4).map { $0 }
        var count: [String: Int] = [:]
        report.setups = (input["setups"] as? [[String: Any]] ?? []).compactMap { raw -> Setup? in
            let kind = text(raw["kind"], 12).lowercased(), title = text(raw["title"], 90)
            guard Setup.kinds.contains(kind), !title.isEmpty, count[kind, default: 0] < 3 else { return nil }
            count[kind, default: 0] += 1
            var what: [String: String] = [:]
            for (key, value) in raw["what"] as? [String: Any] ?? [:] where key.count <= 20 {
                let v = text(value, 600)
                if !v.isEmpty { what[key] = v }
            }
            let from = text(raw["from"], 12)
            return Setup(id: "setup:\(kind):\(count[kind]!)", kind: kind, title: title, why: text(raw["why"], 140),
                         from: places.contains(from) ? from : "", what: what)
        }.prefix(10).map { $0 }
        report.left = (input["left"] as? [[String: Any]] ?? []).compactMap { raw -> Left? in
            let said = text(raw["said"], 280)
            return said.isEmpty ? nil : Left(site: text(raw["site"], 60), url: text(raw["url"], 300), said: said)
        }.prefix(4).map { $0 }
        report.skipped = (input["skipped"] as? [[String: Any]] ?? []).compactMap { raw -> Skipped? in
            let site = text(raw["site"], 60)
            return site.isEmpty ? nil : Skipped(site: site, why: text(raw["why"], 120))
        }.prefix(8).map { $0 }
        return report
    }

    /// What a question is about, as a pick writes it: "phone", "email", or
    /// a profile key, however the run put it.
    static func about(_ said: String) -> String {
        let word = said.lowercased().trimmingCharacters(in: .whitespaces)
        if ["phone", "phone number", "mobile", "mobile number", "cell", "cellphone", "telephone", "tel"].contains(word) { return "phone" }
        if ["email", "e-mail", "email address", "e-mail address", "mail"].contains(word) { return "email" }
        return word.replacingOccurrences(of: " ", with: "")
    }
}

/// People's faces on the notebook: the picture the run saw on a person's
/// profile (`know_report`'s `photos`), fetched once by Yab, made small and
/// kept beside their page in memory ("people/jonas-berg.jpg"), so Forget
/// Everything takes it too. Nothing is fetched for a page that isn't there.
enum KnowFaces {
    static let side: CGFloat = 96
    static let limit = 3_000_000

    /// The picture's file for a person's page, "people/jonas-berg.md".
    static func file(_ person: String) -> URL? {
        guard person.hasPrefix("people/"), person.hasSuffix(".md"), !person.contains(".."), person.split(separator: "/").count == 2 else { return nil }
        return Memory.folder.appendingPathComponent(String(person.dropLast(3)) + ".jpg")
    }

    static func has(_ person: String) -> Bool { file(person).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// The pictures `know_report` named, fetched in the background: only
    /// https, only a picture, only for a person memory has a page for.
    static func keep(_ named: [[String: Any]], grant: ContextGrant? = nil) {
        guard ContextPrivacy.shared.valid(grant) else { return }
        for raw in named.prefix(12) {
            guard let person = raw["person"] as? String, let to = file(person), Memory.files().contains(person),
                  let text = raw["url"] as? String, let url = URL(string: text), url.scheme == "https" else { continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                guard let data, data.count <= limit, (response as? HTTPURLResponse)?.statusCode == 200,
                      (response?.mimeType ?? "").hasPrefix("image/"), let small = shrink(data) else { return }
                ContextPrivacy.shared.transaction {
                    guard ContextPrivacy.shared.valid(grant), Memory.files().contains(person) else { return }
                    try? small.write(to: to, options: .atomic)
                }
            }.resume()
        }
    }

    /// A square of `side` points, cut from the middle, as a JPEG.
    static func shrink(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 8, image.size.height > 8 else { return nil }
        let px = Int(side * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let cut = min(image.size.width, image.size.height)
        let from = NSRect(x: (image.size.width - cut) / 2, y: (image.size.height - cut) / 2, width: cut, height: cut)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: px, height: px).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: from, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    /// The picture as a data URL for the page, or nil.
    static func dataURL(_ person: String) -> String? {
        guard let url = file(person), let data = try? Data(contentsOf: url) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}

@MainActor
enum KnowPage {
    static let host = "you"

    /// `met`: opened as Get to Know ends, greeting you; otherwise the notes.
    /// `section`: the part of the page to open at (the sections' names).
    static func url(met: Bool = false, section: String? = nil) -> URL {
        URL(string: (met ? "yab://you?met" : "yab://you") + (section.map { "#" + $0 } ?? ""))!
    }

    static func isKnow(_ url: URL?) -> Bool { url?.scheme == DiaryPage.scheme && url?.host() == host }

    /// The page as a tab of yours: not held in a run's shut folder.
    static func open(in browser: Browser) -> Tab? {
        browser.everyTab.first { isKnow($0.address) && $0.answering == nil }
    }

    /// The page held as the first tab of a run's shut folder.
    static func held(_ run: String, in browser: Browser) -> Tab? {
        browser.everyTab.first { $0.answering == run && isKnow($0.address) }
    }

    /// Get to Know has begun: its page is the first tab of its shut folder
    /// from the first second, so the folder stands at the end of the row
    /// even while the agent only reads, and as the run ends the page steps
    /// out of it into the folder's place (docs/get-to-know.md, The shut
    /// folder). Out of sight all the while: sealed, as the agent's tabs are.
    static func hold(_ run: String, in browser: Browser) {
        guard !browser.inMail, held(run, in: browser) == nil else { return }
        let tab = browser.open(url(), foreground: false, atEnd: true)
        tab.answering = run
        Folders.shared.refresh()
    }

    /// The run ended with nothing to show, or you stopped it: its page goes
    /// with its folder.
    static func drop(_ run: String, in browser: Browser) {
        guard let tab = held(run, in: browser) else { return }
        browser.close(tab)
        Folders.shared.refresh()
    }

    /// Get to Know is over: its page where its folder stood, at the end of
    /// the row, behind the tab you are on. It says itself that the run is
    /// done, so the corner says nothing, unless the tabs are put away or
    /// mail's space is in front.
    static func arrive(in browser: Browser, for run: String? = nil) {
        let first = KnowNotes.firstName()
        let greeting = first.isEmpty ? "Nice to meet you" : "Nice to meet you, \(first)"
        // Self.: Swift 6.3 (Xcode 26) can't tell the local from the function.
        let held = run.flatMap { Self.held($0, in: browser) }
        let page: Tab?
        if let mine = open(in: browser) {
            // Opened by you while it ran: that one greets you, and the one
            // it held goes.
            if let held { browser.close(held) }
            mine.go(to: url(met: true))
            page = mine
        } else if let held {
            // Out of its folder, into the folder's place.
            held.answering = nil
            held.go(to: url(met: true))
            page = held
        } else if !browser.inMail {
            page = browser.open(url(met: true), foreground: false, atEnd: true)
        } else {
            // Mail's space is never one a tab can be sent to: it opens once
            // mail is left.
            page = nil
        }
        Folders.shared.refresh()
        guard browser.inMail || browser.tabsAway else { return }
        browser.toaster.pop(greeting, mark: "notes", undo: { [weak browser] in
            guard let browser else { return }
            if browser.inMail { browser.leaveMail() }
            if let tab = page ?? open(in: browser) { browser.select(tab) }
            else { _ = browser.open(url(met: true), foreground: true) }
        }, act: "Show")
    }

    /// Notes About You, from Settings or the run's chat: the page in front,
    /// the one open already if there is one, the window brought forward over
    /// Settings; at `section` when a link names one.
    static func show(in browser: Browser, section: String? = nil) {
        NSApp.activate()
        BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
        if browser.inMail { browser.leaveMail() }
        guard let tab = open(in: browser) else {
            _ = browser.open(url(section: section), foreground: true)
            return
        }
        browser.select(tab)
        guard let section, section.allSatisfy({ $0.isLetter || $0 == "-" }) else { return }
        if let web = tab.builtPage, !tab.loading {
            web.run("window.yabGo && yabGo('\(section)')")
        } else {
            let met = tab.address?.query()?.split(separator: "&").contains("met") == true
            tab.go(to: url(met: met, section: section))
        }
    }

    /// Words for the page's HTML, as its words and never as markup.
    nonisolated static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The run's three lines in its chat, their first words leading into the
    /// page: Memory to who you are, Profile to what forms get, Wallet to the
    /// addresses, Missing to what it left alone.
    nonisolated static func linked(_ said: String) -> String {
        var text = said
        for (word, section) in [("Memory", "brief"), ("Profile", "forms"), ("Wallet", "addresses"), ("Missing", "left")] {
            // At a line's start, or where one line joins two stores ("…; Wallet has").
            text = text.replacingOccurrences(of: #"(^|\n|;\s)"# + word + #"\b(?!\])"#, with: "$1[" + word + "](yab://you#" + section + ")",
                                             options: .regularExpression)
        }
        return text
    }

    /// The field over the page, on Autofill's place, with the address's
    /// lines to fix, as ⌘E on its row gives them.
    static func editAddress(_ id: String, in browser: Browser) {
        browser.openPlace(.autofill)
        guard browser.query.stock.addresses.contains(where: { $0.id == id }) else { return }
        browser.beginEdit(.address(id))
    }

    static func page(for url: URL) -> Data {
        let met = url.query()?.split(separator: "&").contains("met") == true
        let first = KnowNotes.firstName()
        let title = met ? (first.isEmpty ? "Nice to meet you" : "Nice to meet you, \(first)") : "Notes about you"
        // The name is words an agent may have written: never markup.
        return Data(html(title: escaped(title)).utf8)
    }
}

/// What the card under Get to Know's answer shows of its page: the
/// greeting's name, the portrait, how many lines wait there, and whether
/// the page has been looked at. Read off the main thread: the Wallet is the
/// keychain.
struct KnowSummary: Equatable {
    var first = ""
    var portrait = ""
    var lines = 0
    var seen = false

    static func load() -> KnowSummary {
        let report = KnowReport.load()
        let state = KnowNotes.state(met: false)
        let voice = (state["voice"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["rows"] as? [Any])?.count ?? 0) }
        let lines = ["brief", "profile", "links", "addresses", "people", "making"].reduce(voice) { $0 + ((state[$1] as? [Any])?.count ?? 0) }
        return KnowSummary(first: KnowNotes.firstName(), portrait: report?.portrait ?? "", lines: lines, seen: report?.seen ?? false)
    }
}

// MARK: - what the page draws

/// The page's rows, read from the stores. Off the main thread: the Wallet
/// is the keychain.
enum KnowNotes {
    static let profileRows: [(key: String, label: String)] = [
        ("name", "Name"), ("headline", "Headline"), ("role", "Role"), ("company", "Company"), ("location", "Location"),
        ("languages", "Languages"), ("pronouns", "Pronouns"), ("timezone", "Time zone"), ("bio", "In a line"), ("about", "About"),
    ]
    static let linkRows: [(key: String, label: String)] = [
        ("linkedin", "LinkedIn"), ("x", "X"), ("github", "GitHub"), ("website", "Site"), ("telegram", "Telegram"), ("instagram", "Instagram"),
    ]
    /// People and projects shown before "and N more in Memory".
    static let peopleShown = 12
    static let projectsShown = 6
    /// An address nobody used for this long, and not home or work, looks old.
    static let old: TimeInterval = 365 * 86_400

    /// The name the page greets: the profile's first word, else the brief's
    /// first bold name.
    static func firstName() -> String {
        let name = Profile.load().name.trimmingCharacters(in: .whitespaces)
        if let first = name.split(separator: " ").first { return String(first) }
        guard let brief = try? String(contentsOf: Memory.user, encoding: .utf8),
              let range = brief.range(of: #"\*\*([^*]+)\*\*"#, options: .regularExpression) else { return "" }
        let bold = brief[range].replacingOccurrences(of: "**", with: "")
        return bold.split(separator: " ").first.map(String.init) ?? ""
    }

    /// Everything, for the page to draw.
    static func state(met: Bool) -> [String: Any] {
        let profile = Profile.load()
        let report = KnowReport.load()
        let addresses = Wallet.addresses()
        var out: [String: Any] = [
            "first": firstName(),
            "met": met,
            "fresh": met && report.map { !$0.seen } == true,
            "portrait": report?.portrait ?? "",
            "minutes": report?.minutes ?? 0,
            "sites": report?.sites ?? 0,
            "notes": Memory.notes,
            // An agent connected, as Settings › AI › Memory's row asks: with
            // none, the empty page offers no Get to Know Me (#266).
            "agent": onMain { AgentSetupModel.shared.anyConnected },
        ]
        out["brief"] = numbered(lines(in: "USER.md")).map { line, nth in
            ["id": lineID("USER.md", line, nth), "kind": "line", "path": "USER.md", "raw": line, "nth": nth, "value": plain(line)]
        }
        func profileRow(_ key: String, _ label: String) -> [String: Any]? {
            let value = profile[key]
            guard !value.isEmpty else { return nil }
            let edited = profile.edited.contains(key)
            return ["id": "profile:" + key, "kind": "profile", "key": key, "label": label, "value": value,
                    "source": source(profile.sources[key], edited: edited)]
        }
        out["profile"] = profileRows.compactMap { profileRow($0.key, $0.label) }
        out["links"] = linkRows.compactMap { profileRow($0.key, $0.label) }
        out["addresses"] = addressRows(addresses, profile: profile, billing: Set(Wallet.cards().map(\.billing).filter { !$0.isEmpty }))
        out["doubts"] = (report?.doubts ?? []).enumerated().map { index, doubt in
            ["id": "doubt:\(index)", "question": doubt.question, "about": doubt.about, "choices": doubt.choices.map(\.answer), "picked": doubt.picked ?? -2]
        }
        out["voice"] = voice()
        let told = story(report)
        out["story"] = told.paragraphs
        // Lines of the brief the story doesn't say, under it as they are.
        out["also"] = (out["brief"] as? [[String: Any]] ?? []).filter { !told.lines.contains($0["id"] as? String ?? "") }
        out["doodles"] = (report?.doodles ?? []).map { ["at": $0.at, "mark": $0.mark] }
        // Quick Actions and routines live on the main thread.
        out["setups"] = onMain { KnowSetups.offered(report) }
        let people = subjects("people/").map { row -> [String: Any] in
            var row = row
            let path = row["path"] as? String ?? ""
            if let photo = KnowFaces.dataURL(path) { row["photo"] = photo }
            row["color"] = tint(path)
            return row
        }
        out["people"] = Array(people.prefix(peopleShown))
        out["morePeople"] = max(0, people.count - peopleShown)
        var making: [[String: Any]] = []
        if let working = profileRow("working", "Now") { making.append(working) }
        let projects = subjects("projects/")
        making += projects.prefix(projectsShown)
        out["making"] = making
        out["moreProjects"] = max(0, projects.count - projectsShown)
        out["left"] = (report?.left ?? []).map { ["site": $0.site, "url": $0.url, "said": $0.said] }
        out["skipped"] = (report?.skipped ?? []).map { ["site": $0.site, "why": $0.why] }
        return out
    }

    /// Work for the main thread from the page's queue, or right here when
    /// already on it.
    static func onMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(work) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }

    // MARK: the story

    /// Your story as the page tells it: the run's sentences, each with the
    /// id of the brief's line it says while that line is there; or, from a
    /// run before stories, the brief's own lines, three to a paragraph.
    /// Also the ids of the lines it says.
    static func story(_ report: KnowReport?) -> (paragraphs: [[[String: Any]]], lines: Set<String>) {
        let brief = numbered(lines(in: "USER.md"))
        func id(of line: String) -> String? {
            brief.first { $0.line == line }.map { lineID("USER.md", $0.line, $0.nth) }
        }
        var says = Set<String>()
        if let story = report?.story, !story.isEmpty {
            let paragraphs = story.enumerated().map { p, sentences in
                sentences.enumerated().map { i, s -> [String: Any] in
                    var row: [String: Any] = ["id": "s\(p).\(i)", "text": s.fixed ?? s.text, "gone": s.gone]
                    if let fixed = s.fixed { row["was"] = s.text; row["fixed"] = fixed }
                    if !s.line.isEmpty, let line = id(of: s.fixed.map { "- " + fixedLine($0) } ?? s.line) ?? id(of: s.line) {
                        row["line"] = line
                        says.insert(line)
                    }
                    return row
                }
            }
            return (paragraphs, says)
        }
        let rows = brief.map { line, nth -> [String: Any] in
            let id = lineID("USER.md", line, nth)
            says.insert(id)
            // Crossed out and fixed as the brief's rows always were.
            return ["id": id, "text": shownRaw(line), "gone": false, "line": id, "brief": true,
                    "kind": "line", "path": "USER.md", "raw": line, "nth": nth, "value": plain(line)]
        }
        return (stride(from: 0, to: rows.count, by: 3).map { Array(rows[$0..<min($0 + 3, rows.count)]) }, says)
    }

    /// The brief's line a fixed sentence is kept as: your words, said to be
    /// yours, so an agent reading the brief knows who wrote them.
    static func fixedLine(_ words: String) -> String { "Corrected by the user: \u{201C}\(words)\u{201D}" }

    /// A brief's line as the story shows it: its links and bold kept for the
    /// page to draw, its list mark and "Full page:" pointers gone.
    static func shownRaw(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") { t = String(t.dropFirst(2)) }
        t = t.replacingOccurrences(of: #"\s*(Full page|See):?\s*\[\[[^\]]+\]\]\.?"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// A person's color when there is no picture: the same for the same page.
    static func tint(_ path: String) -> String {
        let colors = ["#3f7be0", "#d0702e", "#2e9d6a", "#d0507a", "#8a5cf5", "#2fa3b8", "#c4972a"]
        var hash: UInt64 = 5381
        for byte in path.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return colors[Int(hash % UInt64(colors.count))]
    }

    // MARK: the profile

    /// Where a key came from, as the page says it.
    static func source(_ raw: String?, edited: Bool) -> String {
        if edited { return "Yours. Agents won’t change it." }
        let raw = (raw ?? "").trimmingCharacters(in: .whitespaces)
        switch raw.lowercased() {
        case "": return ""
        case "you": return "Written by you"
        case "memory": return "From your notes"
        case "agent": return "Found by your agent"
        case "contact card": return "From your contact card"
        default:
            let said = raw.replacingOccurrences(of: "their ", with: "your ", options: .caseInsensitive)
            return "From " + said
        }
    }

    // MARK: the Wallet

    /// Home or work, as Get to Know kept it.
    static func kind(_ address: StreetAddress) -> String? {
        let source = address.source ?? ""
        if source.hasSuffix(", home") { return "Home" }
        if source.hasSuffix(", work") { return "Work" }
        return nil
    }

    /// The name that says an address is yours: the profile's first word, or
    /// the brief's, once the profile's name is crossed out.
    static func owner(_ profile: Profile) -> String {
        let named = profile.name.split(separator: " ").first.map(String.init) ?? firstName()
        return named.lowercased()
    }

    /// Addressed to someone else: a name on it that isn't yours.
    static func theirs(_ address: StreetAddress, owner: String) -> Bool {
        !owner.isEmpty && !address.name.isEmpty && !address.name.lowercased().contains(owner)
    }

    /// `copy` is the place `kept` is, again: the same street and postal code
    /// addressed to you, or to the company an office is (the office brought
    /// in from another browser under the company's name).
    static func twin(_ kept: StreetAddress, _ copy: StreetAddress, owner: String) -> Bool {
        guard sameStreet(kept, copy) else { return false }
        if key(kept.name) == key(copy.name) || !theirs(copy, owner: owner) { return true }
        let company = key(kept.organization)
        return !company.isEmpty && (key(copy.name) == company || key(copy.organization) == company)
    }

    /// Home and work as Get to Know kept them, then everything else in the
    /// Wallet, each with what it looks like: the same place again, someone
    /// else's, or long unused. An address a card is billed to is never
    /// tidied away for being old: the card would bill somewhere else.
    static func addressRows(_ all: [StreetAddress], profile: Profile, billing: Set<String> = [], now: Date = Date()) -> [[String: Any]] {
        let mine = all.filter { kind($0) != nil }.sorted { kind($0) == "Home" && kind($1) != "Home" }
        let others = all.filter { kind($0) == nil }
        let first = owner(profile)
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.dateFormat = "MMM yyyy"
        var rows: [[String: Any]] = []
        for address in mine {
            let found = address.found.map { "Found in " + $0 } ?? "Found by Get to Know"
            rows.append(["id": "address:" + address.id, "kind": "address", "key": address.id, "label": kind(address) ?? "",
                         "value": line(address, withName: false), "source": found, "mark": address.mark, "yours": true])
        }
        for address in others {
            var hint = "", act = ""
            let theirs = theirs(address, owner: first)
            if let twin = mine.first(where: { twin($0, address, owner: first) }) {
                hint = "same as " + (kind(twin) ?? "home").lowercased()
                act = "merge"
            } else if theirs {
                let whose = address.name.split(separator: " ").first.map(String.init) ?? address.name
                hint = whose + "’s, not yours"
            } else if !billing.contains(address.id), let when = address.used ?? address.saved, now.timeIntervalSince(when) > old {
                hint = "looks old"
                act = "forget"
            }
            var said = address.source.map { $0.isEmpty ? "Saved" : "From " + $0 } ?? "Saved"
            if let used = address.used { said += ", last used " + month.string(from: used) }
            else { said += ", never used" }
            if billing.contains(address.id) { said += ", a card bills here" }
            rows.append(["id": "address:" + address.id, "kind": "address", "key": address.id,
                         "label": address.source.map { $0.isEmpty ? "Saved" : $0 } ?? "Saved",
                         "value": line(address, withName: theirs), "source": said, "note": hint, "act": act, "yours": false])
        }
        return rows
    }

    /// Where a picked phone or email goes: home, and every copy of it that
    /// is yours, which a form may be filled from; with no home, the address
    /// forms get unasked.
    static func homes(_ all: [StreetAddress], owner: String) -> [StreetAddress] {
        let home = all.filter { kind($0) == "Home" }
        guard !home.isEmpty else { return all.first { $0.used != nil && !theirs($0, owner: owner) }.map { [$0] } ?? [] }
        return home + all.filter { copy in kind(copy) == nil && home.contains { twin($0, copy, owner: owner) } && !theirs(copy, owner: owner) }
    }

    /// The same street and postal code, or with none, the same street and
    /// city; never two flats of one building.
    static func sameStreet(_ a: StreetAddress, _ b: StreetAddress) -> Bool {
        guard !a.line1.isEmpty, key(a.line1) == key(b.line1) else { return false }
        let flat = { (x: StreetAddress) in x.street.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().joined(separator: " ") }
        if !flat(a).isEmpty, !flat(b).isEmpty, key(flat(a)) != key(flat(b)) { return false }
        if !a.postal.isEmpty || !b.postal.isEmpty { return key(a.postal) == key(b.postal) }
        return !a.city.isEmpty && key(a.city) == key(b.city)
    }

    static func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// "Södermannagatan 12, 116 40 Stockholm", with the company for an
    /// office and the name when it is someone else's.
    static func line(_ address: StreetAddress, withName: Bool) -> String {
        var parts: [String] = []
        if withName, !address.name.isEmpty { parts.append(address.name) }
        if !address.organization.isEmpty { parts.append(address.organization) }
        parts.append(address.street.replacingOccurrences(of: "\n", with: ", "))
        parts.append([address.postal, address.city].filter { !$0.isEmpty }.joined(separator: " "))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: memory

    /// The lines of a page, as written: its list's items and its sentences
    /// alike, as an agent may write either; never a heading, the
    /// frontmatter, a comment or a table.
    static func lines(in path: String) -> [String] {
        guard let body = Memory.read(path) else { return [] }
        return sections(body).map(\.line)
    }

    /// A line worth a row of its own: words, not a page's structure.
    static func said(_ trimmed: String) -> Bool {
        !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("<!--") && !trimmed.hasPrefix("-->")
            && !trimmed.hasPrefix("|") && !trimmed.hasPrefix("```") && trimmed != "---" && trimmed != "-"
    }

    /// Each line with how many of the same came before it on its page: two
    /// alike are still two rows, each crossed out or fixed on its own.
    static func numbered(_ lines: [String]) -> [(line: String, nth: Int)] {
        var seen: [String: Int] = [:]
        return lines.map { line in
            let nth = seen[line, default: 0]
            seen[line] = nth + 1
            return (line, nth)
        }
    }

    /// A line's id: its page and its words, so it stays the same line
    /// while others around it go; the second of two alike, its turn too.
    static func lineID(_ path: String, _ line: String, _ nth: Int = 0) -> String {
        var hash: UInt64 = 5381
        for byte in line.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return "line:\(path):" + String(hash, radix: 36) + (nth > 0 ? "~\(nth)" : "")
    }

    /// A line as read: no list mark, no bold, links to other pages as
    /// their names, "Full page: …" and "See …" pointers left out.
    static func plain(_ raw: String) -> String { String(shown(raw).text) }

    /// A line as the page shows it, and for each of its characters where it
    /// stands in the line as written; each link's span there, and whether
    /// its words were made from where it goes (a page's name).
    struct Shown {
        var text: [Character] = []
        var from: [Range<Int>] = []
        var links: [(span: Range<Int>, shown: Range<Int>, target: String?)] = []
        /// Where the words begin in the line as written, past its mark.
        var head = 0
    }

    static func shown(_ raw: String) -> Shown {
        let r = Array(raw)
        var s = Shown()
        var i = 0
        while i < r.count, r[i] == " " || r[i] == "\t" { i += 1 }
        if i + 1 < r.count, r[i] == "-" || r[i] == "*" || r[i] == "•", r[i + 1] == " " { i += 2 }
        s.head = i
        func at(_ j: Int, _ word: String) -> Bool {
            let w = Array(word)
            return j + w.count <= r.count && Array(r[j..<j + w.count]) == w
        }
        func close(_ from: Int, _ end: String) -> Int? {
            var j = from
            while j < r.count { if at(j, end) { return j }; if r[j] == "\n" { return nil }; j += 1 }
            return nil
        }
        // "Full page: [[…]]" and "See [[…]]": where the page is, not a fact.
        func pointer(_ j: Int) -> Int? {
            var k = j
            while k < r.count, r[k] == " " { k += 1 }
            guard at(k, "Full page") || at(k, "See") else { return nil }
            k += at(k, "Full page") ? 9 : 3
            while k < r.count, r[k] == " " { k += 1 }
            if k < r.count, r[k] == ":" { k += 1 }
            while k < r.count, r[k] == " " { k += 1 }
            guard at(k, "[["), let end = close(k + 2, "]]") else { return nil }
            k = end + 2
            if k < r.count, r[k] == "." { k += 1 }
            return k
        }
        func emit(_ c: Character, _ from: Range<Int>) { s.text.append(c); s.from.append(from) }
        while i < r.count {
            if let past = pointer(i) { i = past; continue }
            if at(i, "[["), let end = close(i + 2, "]]") {
                let inner = Array(r[i + 2..<end])
                let bar = inner.lastIndex(of: "|")
                let start = s.text.count
                let words = bar.map { $0 + 1 } ?? (inner.lastIndex(of: "/").map { $0 + 1 } ?? 0)
                var up = true
                for k in words..<inner.count {
                    var c = inner[k]
                    if c == "-" { c = " "; up = true; emit(c, i + 2 + k..<i + 3 + k); continue }
                    if up { c = Character(String(c).uppercased()); up = false }
                    emit(c, i + 2 + k..<i + 3 + k)
                }
                s.links.append((i..<end + 2, start..<s.text.count, bar == nil ? String(inner) : nil))
                i = end + 2
                continue
            }
            if r[i] == "[", let mid = close(i + 1, "]("), let end = close(mid + 2, ")"),
               ["http://", "https://", "mailto:"].contains(where: { at(mid + 2, $0) }) {
                let start = s.text.count
                var k = i + 1
                while k < mid {
                    if at(k, "**") { k += 2; continue }
                    if r[k] == "`" { k += 1; continue }
                    emit(r[k], k..<k + 1)
                    k += 1
                }
                s.links.append((i..<end + 1, start..<s.text.count, nil))
                i = end + 1
                continue
            }
            if at(i, "**") { i += 2; continue }
            if r[i] == "`" { i += 1; continue }
            emit(r[i], i..<i + 1)
            i += 1
        }
        while let last = s.text.last, last == " " || last == "\t" { s.text.removeLast(); s.from.removeLast() }
        while let firstChar = s.text.first, firstChar == " " || firstChar == "\t" {
            s.text.removeFirst(); s.from.removeFirst()
            s.links = s.links.map { ($0.span, $0.shown.lowerBound - 1..<$0.shown.upperBound - 1, $0.target) }
        }
        return s
    }

    /// A line fixed from its words as the page shows them: only what the
    /// words changed is changed in the line as written, so its list mark,
    /// its bold, its links and its pointers stay. A change inside a link's
    /// words keeps where it goes; one across a link's edge takes the link
    /// out, its words then yours.
    static func fixed(_ raw: String, to value: String) -> String {
        let s = shown(raw)
        let old = s.text, new = Array(value)
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var q = 0
        while q < old.count - p, q < new.count - p, old[old.count - 1 - q] == new[new.count - 1 - q] { q += 1 }
        guard p < old.count - q || p < new.count - q else { return raw }
        var lo = p, hi = old.count - q
        func crosses(_ lo: Int, _ hi: Int) -> Bool {
            s.links.contains { link in
                let inside = lo >= link.shown.lowerBound && hi <= link.shown.upperBound
                    && (lo < hi || lo > link.shown.lowerBound && lo < link.shown.upperBound)
                return !link.shown.isEmpty && lo < link.shown.upperBound && hi > link.shown.lowerBound && !inside
                    && (lo > link.shown.lowerBound || hi < link.shown.upperBound)
            }
        }
        // Words only taken out, or only put in, can stand a letter to either
        // side over the same letters ("Bunas " or " Bunas"): where they keep
        // clear of a link's edge, a link keeps its page.
        let added = new.count - old.count
        if crosses(lo, hi), hi == lo || added == -(hi - lo) {
            let len = hi - lo
            func same(_ a: Int, _ b: Int) -> Bool { len > 0 ? old[a] == old[b] : new[a] == new[b] }
            var a = lo
            while crosses(a, a + len), a > 0, same(a - 1, a - 1 + max(len, added)) { a -= 1 }
            if crosses(a, a + len) {
                a = lo
                while crosses(a, a + len), a + max(len, added) < (len > 0 ? old.count : new.count), same(a, a + max(len, added)) { a += 1 }
            }
            if !crosses(a, a + len) { lo = a; hi = a + len }
        }
        // A change across a link's edge takes all of the link.
        var grew = true
        while grew {
            grew = false
            for link in s.links where !link.shown.isEmpty {
                let inside = lo >= link.shown.lowerBound && hi <= link.shown.upperBound
                    && (lo < hi || lo > link.shown.lowerBound && lo < link.shown.upperBound)
                let touches = lo < link.shown.upperBound && hi > link.shown.lowerBound
                if touches, !inside, lo > link.shown.lowerBound || hi < link.shown.upperBound {
                    lo = min(lo, link.shown.lowerBound); hi = max(hi, link.shown.upperBound); grew = true
                }
            }
        }
        let middle = String(new[lo..<(new.count - (old.count - hi))])
        let r = Array(raw)
        // Words typed right on from a link's words, a name grown or begun
        // anew, are the link's: it says them, and goes where it went.
        if lo == hi, let link = s.links.first(where: {
            !$0.shown.isEmpty && ($0.shown.upperBound == lo && middle.first.map { $0.isLetter || $0.isNumber } == true
                || $0.shown.lowerBound == lo && middle.last.map { $0.isLetter || $0.isNumber } == true)
        }) {
            if let target = link.target {
                var words = Array(old[link.shown])
                words.insert(contentsOf: Array(middle), at: lo - link.shown.lowerBound)
                return String(r[..<link.span.lowerBound]) + "[[" + target + "|" + String(words) + "]]" + String(r[link.span.upperBound...])
            }
            let at = link.shown.upperBound == lo ? s.from[lo - 1].upperBound : s.from[lo].lowerBound
            return String(r[..<at]) + middle + String(r[at...])
        }
        // Where in the line as written: a change is the characters it
        // covers, whole links among them; an insertion goes between two,
        // outside a link it borders.
        var start: Int, end: Int
        if lo < hi {
            start = s.from[lo].lowerBound
            end = s.from[hi - 1].upperBound
            for link in s.links where !link.shown.isEmpty && lo <= link.shown.lowerBound && hi >= link.shown.upperBound {
                start = min(start, link.span.lowerBound); end = max(end, link.span.upperBound)
            }
            if let link = s.links.first(where: { $0.target != nil && lo >= $0.shown.lowerBound && hi <= $0.shown.upperBound && !(lo == $0.shown.lowerBound && hi == $0.shown.upperBound) }),
               let target = link.target {
                // Inside the words made from a page's name: the link keeps
                // its page and says the new words.
                var words = Array(old[link.shown])
                words.replaceSubrange(lo - link.shown.lowerBound..<hi - link.shown.lowerBound, with: Array(middle))
                return String(r[..<link.span.lowerBound]) + "[[" + target + "|" + String(words) + "]]" + String(r[link.span.upperBound...])
            }
        } else if lo < old.count {
            start = s.links.first { $0.shown.lowerBound == lo }?.span.lowerBound ?? s.from[lo].lowerBound
            end = start
        } else if lo > 0 {
            start = s.links.first { $0.shown.upperBound == lo }?.span.upperBound ?? s.from[lo - 1].upperBound
            end = start
        } else {
            start = s.head; end = start
        }
        return String(r[..<start]) + middle + String(r[end...])
    }

    /// The page's section a line is under, "## Current" and its "###": its
    /// list's items and its sentences, the frontmatter left out.
    static func sections(_ body: String) -> [(heading: String, sub: String, line: String)] {
        var out: [(String, String, String)] = []
        var heading = "", sub = "", inFront = false
        for (index, line) in body.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0, trimmed == "---" { inFront = true; continue }
            if inFront { if trimmed == "---" { inFront = false }; continue }
            if trimmed.hasPrefix("### ") { sub = String(trimmed.dropFirst(4)); continue }
            if trimmed.hasPrefix("## ") { heading = String(trimmed.dropFirst(3)); sub = ""; continue }
            if said(trimmed) { out.append((heading, sub, line)) }
        }
        return out
    }

    /// People or projects: each page's name, and the first thing it says
    /// about them now; the ones changed last first.
    static func subjects(_ folder: String) -> [[String: Any]] {
        let paths = Memory.files().filter { $0.hasPrefix(folder) }
        var found: [(row: [String: Any], changed: Date, title: String)] = []
        for path in paths {
            let url = Memory.folder.appendingPathComponent(path)
            guard let body = try? String(contentsOf: url, encoding: .utf8), Memory.meaningful(body) else { continue }
            let title = MemoryShelf.title(path: path, body: body)
            let lines = sections(body)
            let line = (lines.first { $0.heading.lowercased() == "current" } ?? lines.first { $0.heading.lowercased() != "history" })?.line
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            var row: [String: Any] = ["id": "note:" + path, "kind": "note", "path": path, "who": title, "value": line.map(plain) ?? ""]
            if let line { row["raw"] = line; row["nth"] = numbered(body.components(separatedBy: "\n")).first { $0.line == line }?.nth ?? 0 }
            found.append((row, changed, title))
        }
        return found.sorted { a, b in
            a.changed != b.changed ? a.changed > b.changed : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }.map(\.row)
    }

    /// How you write, from agent/writing-voice.md: each part of it (email
    /// at work, with friends) and its first two rules.
    static func voice() -> [[String: Any]] {
        let path = "agent/writing-voice.md"
        guard let body = Memory.read(path) else { return [] }
        var groups: [(name: String, rows: [[String: Any]])] = []
        let entries = sections(body).filter { $0.heading.lowercased() != "history" }
        for (entry, nth) in zip(entries, numbered(entries.map(\.line)).map(\.nth)) {
            let name = plain(entry.sub)
            if groups.last?.name != name { groups.append((name, [])) }
            guard groups[groups.count - 1].rows.count < 2 else { continue }
            groups[groups.count - 1].rows.append(["id": lineID(path, entry.line, nth), "kind": "line", "path": path, "raw": entry.line, "nth": nth,
                                                  "value": plain(entry.line)])
        }
        return groups.prefix(6).map { ["group": $0.name, "rows": $0.rows] }
    }
}

// MARK: - what the page does

/// What yab://you asks, answered for that page alone. The stores are read
/// and written on a queue of its own, the keychain being slow; each change
/// answers with the page as it now stands, as JSON with its keys in order,
/// so the page can tell when nothing changed.
final class KnowRelay: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = KnowRelay()
    static let name = "yabYou"

    private let queue = DispatchQueue(label: "yab.know", qos: .userInitiated)
    /// How to take back what the page crossed out or fixed, by its row, the
    /// last change last; the oldest let go past `kept`.
    private var undo: [String: [() -> Void]] = [:]
    private var order: [String] = []
    private static let kept = 200
    /// The page as last drawn, and what it was drawn from, for the page's
    /// every look to be cheap while nothing changed.
    private var drawn: (from: String, met: Bool, json: String)?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == DiaryPage.scheme,
              message.frameInfo.securityOrigin.host == KnowPage.host,
              let body = message.body as? [String: Any],
              let verb = body["do"] as? String
        else {
            replyHandler(nil, "no")
            return
        }
        // Yours alone: an agent's tab never gets here (Bench refuses agents
        // yab://you), and one that did would be told nothing.
        let (browser, agents) = MainActor.assumeIsolated { () -> (Browser?, Bool) in
            let browser = BrowserWindows.shared.browser(for: message.webView?.window) ?? Agents.shared.browser ?? Links.browser
            let tab = message.webView.flatMap { web in browser?.everyTab.first { $0.webKitOnly("WebKit knowledge-page message source", build: false) === web } }
            return (browser, tab?.agent.map { $0 != Agents.script } ?? false)
        }
        guard !agents else {
            replyHandler(nil, "no")
            return
        }
        let met = message.frameInfo.request.url?.query()?.split(separator: "&").contains("met") == true
        switch verb {
        case "memory", "edit-address", "know":
            MainActor.assumeIsolated { self.act(verb, body, in: browser) }
            replyHandler(true, nil)
        default:
            let epoch = ContextPrivacy.shared.epoch
            queue.async {
                guard ContextPrivacy.shared.current(epoch) else { DispatchQueue.main.async { replyHandler(nil, "This context was cleared.") }; return }
                let out = self.change(verb, body, met: met, epoch: epoch)
                DispatchQueue.main.async { replyHandler(out, nil) }
            }
        }
    }

    /// What the page asks of the window it is in: Memory in Settings, an
    /// address in Autofill's place.
    @MainActor
    private func act(_ verb: String, _ body: [String: Any], in browser: Browser?) {
        guard let browser else { return }
        switch verb {
        case "memory":
            browser.openSettings(.agentMemory)
        case "edit-address":
            if let id = body["key"] as? String { KnowPage.editAddress(id, in: browser) }
        case "know":
            // Get to Know Me on the empty page: the same run every other button starts.
            ContextConsent.request()
        default:
            break
        }
    }

    /// A change to the stores, then the page as it stands, as JSON. On
    /// `queue`.
    private func change(_ verb: String, _ body: [String: Any], met: Bool, epoch: String) -> String {
        let id = body["id"] as? String ?? ""
        var extra: [String: Any] = [:]
        var memory = false
        if verb == "state" {
            let from = KnowRelay.drawnFrom()
            if let drawn, drawn.from == from, drawn.met == met { return drawn.json }
            let json = KnowRelay.json(KnowNotes.state(met: met))
            drawn = (from, met, json)
            return json
        }
        if verb == "setup" { extra["said"] = setup(id, body["act"] as? String ?? "") }
        else if verb == "forget-all" {
            DispatchQueue.main.async { MemoryAsk.forgetEverything() }
            undo = [:]; order = []
        } else {
            ContextPrivacy.shared.transaction {
                guard ContextPrivacy.shared.current(epoch) else { return }
                switch verb {
        case "forget":
            memory = forget(id, body)
        case "fix":
            let (now, wrote) = fix(id, body)
            if let now { extra["now"] = now }
            memory = wrote
        case "tidy":
            extra["done"] = tidy(Set(body["ids"] as? [String] ?? []))
        case "undo":
            if var list = undo[id], let back = list.popLast() {
                undo[id] = list.isEmpty ? nil : list
                if let at = order.lastIndex(of: id) { order.remove(at: at) }
                back()
            }
            memory = true
        case "pick":
            memory = pick(id, body["pick"] as? Int ?? -1)
        case "say":
            memory = say(id, body)
        case "seen":
            if var report = KnowReport.load(), !report.seen {
                report.seen = true
                KnowReport.save(report)
            }
        default:
            break
        }
            }
        }
        // Settings › AI › Memory lists memory's pages: read again when one changed.
        if memory { DispatchQueue.main.async { MemoryShelf.shared.reload() } }
        drawn = nil
        var out = KnowNotes.state(met: met)
        out.merge(extra) { $1 }
        return KnowRelay.json(out)
    }

    private static func json(_ out: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// What the page is drawn from, cheaply: memory's pages and when each
    /// changed, the profile's and the report's, and the Wallet's count of
    /// changes; the keychain isn't asked.
    private static func drawnFrom() -> String {
        func stamp(_ url: URL) -> String {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) } ?? "-"
        }
        var parts = [ContextPrivacy.shared.epoch, stamp(Profile.file), stamp(KnowReport.file), String(Wallet.changes),
                     String(KnowNotes.onMain { AgentSetupModel.shared.anyConnected })]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        if let walk = FileManager.default.enumerator(at: Memory.folder, includingPropertiesForKeys: keys) {
            for case let url as URL in walk {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                parts.append(url.lastPathComponent + ":" + String(values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return parts.joined(separator: "|")
    }

    /// Kept to take back, the last one first.
    private func keep(_ id: String, _ back: @escaping () -> Void) {
        let epoch = ContextPrivacy.shared.epoch
        undo[id, default: []].append { guard ContextPrivacy.shared.current(epoch) else { return }; back() }
        order.append(id)
        guard order.count > KnowRelay.kept else { return }
        let oldest = order.removeFirst()
        if var list = undo[oldest], !list.isEmpty {
            list.removeFirst()
            undo[oldest] = list.isEmpty ? nil : list
        }
    }

    // MARK: crossing out

    /// True when a page of memory changed.
    private func forget(_ id: String, _ body: [String: Any]) -> Bool {
        let kind = body["kind"] as? String ?? ""
        switch kind {
        case "profile":
            guard let key = body["key"] as? String, Profile.keys.contains(key) else { return false }
            var profile = Profile.load()
            // Crossed out already, the second press of a double one.
            guard !profile[key].isEmpty else { return false }
            let was = (value: profile[key], source: profile.sources[key], edited: profile.edited.contains(key))
            // Crossed out is yours too: nothing writes it back.
            profile.merge([key: ""], source: "you", force: true)
            Profile.save(profile, origin: .manual(Set(Profile.keys.filter { Profile.cells(Profile.load())[$0] != Profile.cells(profile)[$0] })))
            keep(id) { KnowRelay.restore(key, was.value, was.source, was.edited) }
        case "address":
            guard let key = body["key"] as? String, let address = Wallet.addresses().first(where: { $0.id == key }) else { return false }
            let merged = body["act"] as? String == "merge" ? carry(address) : nil
            Wallet.forget(address: key)
            keep(id) {
                Wallet.save(address, origin: .manual(Set(Wallet.contextKeys)))
                merged?()
            }
        case "line", "note":
            guard let path = body["path"] as? String, let raw = body["raw"] as? String else { return false }
            let nth = body["nth"] as? Int ?? 0
            if kind == "note" {
                // A person or a project crossed out: its page goes.
                guard KnowRelay.subject(path) else { return false }
                let url = Memory.folder.appendingPathComponent(path)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                try? FileManager.default.removeItem(at: url)
                keep(id) { try? text.write(to: url, atomically: true, encoding: .utf8) }
                return true
            }
            guard let back = replace(path, raw, nth: nth, with: nil) else { return false }
            keep(id, back)
            return true
        default:
            return false
        }
        return false
    }

    /// Tidy Up: of the rows the page struck, those that still look old are
    /// forgotten and those still the same place twice merged.
    private func tidy(_ ids: Set<String>) -> [String] {
        let rows = KnowNotes.addressRows(Wallet.addresses(), profile: Profile.load(), billing: Set(Wallet.cards().map(\.billing).filter { !$0.isEmpty }))
        var done: [String] = []
        for row in rows {
            guard let act = row["act"] as? String, !act.isEmpty, let id = row["id"] as? String, ids.contains(id) else { continue }
            _ = forget(id, ["kind": "address", "key": row["key"] ?? "", "act": act])
            done.append(id)
        }
        return done
    }

    /// The copy of home or work that goes: when it was used last, and what
    /// it says that the one staying doesn't (a flat, a phone, an email), go
    /// into the one that stays, and a card billed to it is billed there.
    /// How to take that back.
    private func carry(_ copy: StreetAddress) -> (() -> Void)? {
        let all = Wallet.addresses()
        let owner = KnowNotes.owner(Profile.load())
        guard let twin = all.first(where: { $0.id != copy.id && KnowNotes.kind($0) != nil && KnowNotes.twin($0, copy, owner: owner) })
                ?? all.first(where: { $0.id != copy.id && KnowNotes.twin($0, copy, owner: owner) }) else { return nil }
        var kept = twin
        if let used = copy.used, (kept.used ?? .distantPast) < used {
            kept.used = used
            if let site = copy.usedOn { kept.usedOn = site }
        }
        for field in [\StreetAddress.phone, \.email, \.region, \.country, \.organization, \.city] where kept[keyPath: field].isEmpty {
            kept[keyPath: field] = copy[keyPath: field]
        }
        if !kept.street.contains("\n"), copy.street.contains("\n"), KnowNotes.key(kept.line1) == KnowNotes.key(copy.line1) {
            kept.street = copy.street
        }
        if kept != twin { Wallet.save(kept, origin: .manual(Set(Wallet.contextKeys))) }
        let billed = Wallet.cards().filter { $0.billing == copy.id }.map(\.id)
        for card in billed { Wallet.update(card: card) { $0.billing = twin.id } }
        return {
            if kept != twin { Wallet.save(twin, origin: .manual(Set(Wallet.contextKeys))) }
            for card in billed { Wallet.update(card: card) { $0.billing = copy.id } }
        }
    }

    private static func restore(_ key: String, _ value: String, _ source: String?, _ edited: Bool) {
        var profile = Profile.load()
        profile[key] = value
        profile.sources[key] = source
        if edited { profile.edited.insert(key) } else { profile.edited.remove(key) }
        Profile.save(profile, origin: .manual(Set(Profile.keys.filter { Profile.cells(Profile.load())[$0] != Profile.cells(profile)[$0] })))
    }

    // MARK: fixing

    /// The row's new words; for a line of memory, the id it has now, and
    /// whether a page of memory changed. Nil when it couldn't be kept: the
    /// line changed underneath, or the page is full.
    private func fix(_ id: String, _ body: [String: Any]) -> (String?, Bool) {
        let value = (body["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return (nil, false) }
        switch body["kind"] as? String ?? "" {
        case "profile":
            guard let key = body["key"] as? String, Profile.keys.contains(key) else { return (nil, false) }
            var profile = Profile.load()
            let was = (value: profile[key], source: profile.sources[key], edited: profile.edited.contains(key))
            profile.merge([key: value], source: "you", force: true)
            Profile.save(profile, origin: .manual([key]))
            keep(id) { KnowRelay.restore(key, was.value, was.source, was.edited) }
            return (id, false)
        case "line", "note":
            guard let path = body["path"] as? String, let raw = body["raw"] as? String else { return (nil, false) }
            let nth = body["nth"] as? Int ?? 0
            let line = KnowNotes.fixed(raw, to: value.replacingOccurrences(of: "\n", with: " "))
            guard line != raw else { return (id, false) }
            guard let back = replace(path, raw, nth: nth, with: line) else { return (nil, false) }
            let now = body["kind"] as? String == "note" ? id : KnowNotes.lineID(path, line, nth)
            keep(now, back)
            return (now, true)
        default:
            return (nil, false)
        }
    }

    /// The `nth` of the lines of a page as the page saw it, replaced or
    /// taken out: how to put it back, or nil when it isn't there as seen.
    private func replace(_ path: String, _ raw: String, nth: Int = 0, with line: String?) -> (() -> Void)? {
        guard KnowRelay.editable(path) else { return nil }
        let url = Memory.files().contains(path) ? Memory.folder.appendingPathComponent(path) : Memory.file(path)
        guard let url, let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = body.components(separatedBy: "\n")
        let alike = lines.indices.filter { lines[$0] == raw }
        guard nth < alike.count else { return nil }
        let index = alike[nth]
        if let line { lines[index] = line } else { lines.remove(at: index) }
        let written = lines.joined(separator: "\n")
        guard written.utf8.count <= Memory.fileLimit, (try? written.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return {
            // As it was, unless the page changed since: then the line alone.
            guard let now = try? String(contentsOf: url, encoding: .utf8) else { return }
            if now == written {
                try? body.write(to: url, atomically: true, encoding: .utf8)
                return
            }
            var current = now.components(separatedBy: "\n")
            if let line, let at = current.firstIndex(of: line) { current[at] = raw }
            else if line == nil { current.insert(raw, at: min(index, current.count)) }
            try? current.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// The pages whose lines the page may change: the brief, how you write,
    /// and people's and projects' pages.
    static func editable(_ path: String) -> Bool {
        path == "USER.md" || path == "agent/writing-voice.md" || subject(path)
    }

    static func subject(_ path: String) -> Bool {
        (path.hasPrefix("people/") || path.hasPrefix("projects/")) && path.hasSuffix(".md") && !path.contains("..")
            && Memory.files().contains(path)
    }

    /// Add, Not Now, or Undo on an offer: where it went, in words.
    private func setup(_ id: String, _ act: String) -> String {
        KnowNotes.onMain {
            let browser = BrowserWindows.shared.browser(for: NSApp.keyWindow) ?? Agents.shared.browser ?? Links.browser
            return KnowSetups.answer(id, act, in: browser) ?? ""
        }
    }

    // MARK: the story

    /// A sentence of the story crossed out (`act` "cross") or fixed
    /// (`value`): the report keeps it so, and the brief's line it says goes,
    /// or becomes your words. Undo puts both back. True when the brief changed.
    private func say(_ id: String, _ body: [String: Any]) -> Bool {
        let parts = id.dropFirst().split(separator: ".").compactMap { Int($0) }
        guard id.hasPrefix("s"), parts.count == 2, var report = KnowReport.load(),
              report.story.indices.contains(parts[0]), report.story[parts[0]].indices.contains(parts[1]) else { return false }
        let (p, i) = (parts[0], parts[1])
        let was = report.story[p][i]
        var now = was
        let value = (body["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if body["act"] as? String == "cross" {
            guard !was.gone else { return false }
            now.gone = true
        } else {
            guard !value.isEmpty, value != (was.fixed ?? was.text) else { return false }
            now.fixed = value == was.text ? nil : value
        }
        // The line as the brief has it now: yours if fixed before.
        let current = was.fixed.map { "- " + KnowNotes.fixedLine($0) } ?? was.line
        var back: (() -> Void)?
        if !current.isEmpty {
            let line = now.gone ? nil : now.fixed.map { "- " + KnowNotes.fixedLine($0) } ?? was.line
            back = replace("USER.md", current, with: line)
        }
        report.story[p][i] = now
        KnowReport.save(report)
        keep(id) {
            back?()
            guard var report = KnowReport.load(), report.story.indices.contains(p), report.story[p].indices.contains(i) else { return }
            report.story[p][i] = was
            KnowReport.save(report)
        }
        return back != nil
    }

    // MARK: questions

    /// An answer to what the run couldn't settle: its line kept in the
    /// brief, and the key it is about set, on the profile or on your home
    /// and its copies. The answer before it, or None of These, takes back
    /// all the one before wrote, and puts back what it wrote over. True
    /// when the brief changed.
    private func pick(_ id: String, _ choice: Int) -> Bool {
        guard id.hasPrefix("doubt:"), let index = Int(id.dropFirst(6)), var report = KnowReport.load(),
              report.doubts.indices.contains(index) else { return false }
        var doubt = report.doubts[index]
        var memory = false
        if let was = doubt.was {
            memory = was.line != nil
            if let line = was.line { _ = replace("USER.md", line, with: nil) }
            if let value = was.value, Profile.keys.contains(doubt.about) { KnowRelay.restore(doubt.about, value, was.source, was.edited) }
            for (address, value) in was.addresses {
                guard var kept = Wallet.addresses().first(where: { $0.id == address }) else { continue }
                if doubt.about == "phone" { kept.phone = value } else { kept.email = value }
                Wallet.save(kept, origin: .manual(Set(Wallet.contextKeys)))
            }
            doubt.was = nil
        }
        doubt.picked = choice
        if doubt.choices.indices.contains(choice) {
            let picked = doubt.choices[choice]
            var was = KnowReport.Was()
            if !picked.keep.isEmpty {
                let line = "- " + picked.keep
                // Kept already, it stays whatever is picked later.
                if !KnowNotes.lines(in: "USER.md").contains(line), Memory.write("USER", text: picked.keep, replacing: nil) == nil {
                    was.line = line
                    memory = true
                }
            }
            let about = doubt.about
            if Profile.keys.contains(about) {
                var profile = Profile.load()
                was.value = profile[about]
                was.source = profile.sources[about]
                was.edited = profile.edited.contains(about)
                profile.merge([about: picked.answer], source: "you", force: true)
                Profile.save(profile, origin: .manual(Set(Profile.keys.filter { Profile.cells(Profile.load())[$0] != Profile.cells(profile)[$0] })))
            } else if about == "phone" || about == "email" {
                let owner = KnowNotes.owner(Profile.load())
                for var address in KnowNotes.homes(Wallet.addresses(), owner: owner) {
                    was.addresses[address.id] = about == "phone" ? address.phone : address.email
                    if about == "phone" { address.phone = picked.answer } else { address.email = picked.answer }
                    Wallet.save(address, origin: .manual(Set(Wallet.contextKeys)))
                }
            }
            doubt.was = was
        }
        report.doubts[index] = doubt
        KnowReport.save(report)
        return memory
    }
}
