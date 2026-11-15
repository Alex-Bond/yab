import Foundation
import SyncKit

// A step of an agent's work in words: the table is SyncKit's (StepWords),
// the iPhone's too, so a step reads the same on both. What only this Mac
// knows is here: a step done in a tab is said by that page's title, a tool
// you said no to by what it would have done, and the dock's older notes.

extension StepWords {
    func verb(_ state: ChatItem.State) -> String { verb(state.rawValue) }

    /// The step in one line of words: "Opening github.com".
    func line(_ state: ChatItem.State = .running) -> String { line(state.rawValue) }

    /// A step of a chat, in words.
    @MainActor static func of(_ item: ChatItem) -> StepWords {
        // A tool you said no to: what it would have done.
        if item.extra?["declined"] != nil {
            var asked = item
            asked.extra?["declined"] = nil
            let base = of(asked)
            let what = base.object.isEmpty ? spoken(item.name.isEmpty ? item.kind.rawValue : item.name) : base.object
            return StepWords("You declined:", "You declined:", "You declined:", what, .close, middle: base.middle)
        }
        return of(kind: item.kind.rawValue, name: item.name, detail: item.detail, text: item.text,
                  widget: item.extra?["widgetTitle"] ?? "", place: place(item.detail, page: item.page))
    }

    /// A tool call, by its name and what it was about.
    @MainActor static func tool(_ name: String, detail: String, outcome: String = "", page: ChatItem.Page? = nil) -> StepWords {
        tool(name, detail: detail, outcome: outcome, place: place(detail, page: page))
    }

    /// A step as the stream tells it, a tool's name and its input.
    @MainActor static func of(tool: String, input: [String: Any]) -> StepWords {
        let part: [String: Any] = ["type": "tool_use", "id": "now", "name": tool, "input": input]
        guard let item = ChatItem.claude(part, message: "now") else { return StepWords("Working", "Worked", "Couldn\u{2019}t finish", "", .think) }
        return of(item)
    }

    // MARK: - what it was about

    /// The page a "tab:<id>" detail names: as it was when the step was done
    /// in it, else as its tab is now. The site is the page's, or the tab's
    /// for a page that had none.
    @MainActor static func place(_ detail: String, page: ChatItem.Page?) -> StepPlace? {
        guard detail.hasPrefix("tab:") else { return nil }
        let tab = page?.host.isEmpty == false ? nil : ChatStepMark.tab(detail)
        let site = page?.host.isEmpty == false ? page?.host : tab?.address?.host()
        if let page { return StepPlace(title: page.title, host: page.host, site: site) }
        guard let tab else { return nil }
        return StepPlace(title: tab.title, host: tab.address?.host(), site: site)
    }

    /// A step's detail as the line says it: a tab by its title, several
    /// sites as "tabelog.com and 2 more", keys by their names.
    @MainActor static func said(_ detail: String, page: ChatItem.Page? = nil) -> String {
        said(detail, place: place(detail, page: page))
    }

    /// The hosts a detail names: one, or several joined by commas.
    @MainActor static func hosts(_ detail: String, page: ChatItem.Page? = nil) -> [String] {
        hosts(detail, place: place(detail, page: page))
    }

    // MARK: - said elsewhere

    /// What the dock, the task page, a tab's card and the menu bar say for
    /// an agent's `now`: a step's words already, or an older note ("click ·
    /// github.com", from an agent that came on its own) put in the same words.
    @MainActor static func say(_ now: String, name: String) -> String {
        if now.isEmpty || now.hasSuffix("is working") || now.hasPrefix("Starting") { return "\(name) is working" }
        if now.hasPrefix("Next: ") { return String(now.dropFirst(6)) }
        if now.hasPrefix("Steered: ") { return "Heard what you added" }
        if now.hasPrefix("Queued: ") { return "Keeping your message for next" }
        if now == "answered the page" { return "Answering the page" }
        let parts = now.components(separatedBy: " \u{00B7} ")
        let verb = parts.first ?? ""
        let host = parts.count > 1 ? parts[1] : ""
        // An older note is lower case: a tool's name, and a host maybe.
        guard let first = verb.first, first.isLowercase || verb.first == "_" || ["Bash", "Edit", "Write", "Read", "Grep", "Glob", "Task", "TodoWrite", "WebSearch", "WebFetch"].contains(verb) else { return now }
        if verb.hasPrefix("press") {
            let keys = verb.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return keys.isEmpty ? "Pressing keys" : "Pressing " + keyWords(keys)
        }
        let legacy = ["read": "snapshot", "shot": "screenshot", "go": "open", "nav": "navigate", "fill": "type", "select": "choose", "submit": "click", "webfetch": "WebFetch", "websearch": "WebSearch"]
        let tool = legacy[verb] ?? verb
        let words = self.tool(tool, detail: host)
        // A page's hand on a site: "Clicking on github.com".
        if !host.isEmpty, [StepArt.click, .type, .scroll, .point, .code].contains(words.art) {
            // "Running a script on" says its own "on".
            return words.running + (words.running.hasSuffix(" on") ? " " : " on ") + host
        }
        if !host.isEmpty, [StepArt.readPage, .shot].contains(words.art) { return words.running + " " + host }
        return words.line(.running)
    }
}
