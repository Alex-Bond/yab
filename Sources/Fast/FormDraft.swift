import Foundation

// Drafts for a form's questions, the ones only words answer: "What are you
// hoping to get out of tonight?". Written by your AI in the person's voice
// from their profile and the page, and put into the box as a draft for
// them to read and send, never sent. Claude when it is yours or the only
// one connected, kept warm as below; else ChatGPT, Codex run once a form.
//
// Speed is the whole point, so the drafts start when the list shows, not
// when the row is taken, and Claude Code is kept running between forms:
// started cold it took 8 to 13 s on this Mac before a word came, nearly
// all of it Claude Code's own start; kept warm, a draft of two sentences
// took 1.9 to 4.3 s, Sonnet and Haiku alike, so Sonnet it is. It is
// started as soon as a page with a question in words has loaded (warm),
// so the first form of the day doesn't pay the start either: on adhd a
// first draft took 6.8 s from the caret coming in cold and 3.7 s warm.
// One request asks every question of a form at once. The process goes
// after ten minutes without a form, since each one holds about 200 MB.

@MainActor
final class FormDraft {
    static let shared = FormDraft()

    /// Drafts are written at all (Settings › Passwords): the page's words and
    /// the profile go to your AI for them, Claude or ChatGPT.
    static var on: Bool {
        get { Store.settings.object(forKey: "autofill.drafts") as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: "autofill.drafts") }
    }

    /// The model drafts are written with (Claude Code's alias): Settings ›
    /// AI › Models' Form drafts, else Sonnet.
    static var model: String {
        (Store.settings.string(forKey: "models.drafts.cli") == "claude" ? Store.settings.string(forKey: "models.drafts.model") : nil)
            ?? Store.settings.string(forKey: "autofill.draftModel") ?? "sonnet"
    }
    static var effort: String? { Store.settings.string(forKey: "models.drafts.effort") }
    /// Codex's model when Form drafts names one; else Codex's own.
    static var codexModel: String? {
        Store.settings.string(forKey: "models.drafts.cli") == "codex" ? Store.settings.string(forKey: "models.drafts.model") : nil
    }

    /// Claude Code, kept running between forms (WarmClaude).
    private let claude = WarmClaude(room: "agent/forms", idle: 600) {
        ["--model", FormDraft.model, "--append-system-prompt", FormDraft.system] + (FormDraft.effort.map { ["--effort", $0] } ?? [])
    }
    /// Who writes the drafts: Claude, kept warm, when it is yours or the
    /// only one connected; else ChatGPT, through Codex run once a form
    /// with no tools (PlanText), about 5 s cold.
    /// Form drafts' own plan when it is connected; none connected (only
    /// Cursor, say), nobody: never Claude Code you didn't connect.
    private var cli: String? {
        Store.testing ? "claude"
            : ModelDefaults.draftWriter(chosen: Store.settings.string(forKey: "models.drafts.cli"), connected: PlanText.agents)
    }
    private var codexSaid = ""
    private var codexAsked = 0
    private var codexRunning = false

    /// Whether a draft can be had at all: Claude Code found, and not given
    /// up on, or Codex connected.
    var usable: Bool { cli == "claude" ? claude.usable : cli != nil }
    /// Whether the drafts' writer is Claude kept warm (warm() does something).
    var warms: Bool { cli == "claude" }
    /// What happened last, for the bench: "started", "no claude", "ended", "timed out"; the others' "wrote", "no answer".
    var said: String { cli == "claude" ? claude.said : codexSaid }
    var running: Bool { cli == "claude" ? claude.running : codexRunning }
    var asked: Int { cli == "claude" ? claude.asked : codexAsked }

    static let system = """
    You fill in web forms for the person described in the request, in their own voice: first person, plain \
    and specific, no hype, no exclamation marks, no long dashes. Answer each question the way they would \
    answer it on this page, using the page to know what it is for. Keep to each question's limit, and \
    to one to three sentences unless the question asks for more. Write in the question's language. \
    If the profile has nothing for a question, write a short honest answer from what is there; never \
    invent employers, numbers or facts. Reply with only a JSON array of strings, one per question, in order.
    """

    /// Writes an answer for each step, in order; an empty string where it
    /// couldn't. Hears nothing back when Claude Code can't be had.
    func write(_ steps: [FormStep], profile: Profile, context: [String: Any], site: String, done: @escaping ([String]) -> Void) {
        guard usable, !steps.isEmpty else { return done([]) }
        let questions: [[String: Any]] = steps.map { step in
            var q: [String: Any] = ["question": step.field.label]
            if step.field.maxLength > 0 { q["limit"] = "\(step.field.maxLength) characters" }
            if !step.field.placeholder.isEmpty { q["hint"] = step.field.placeholder }
            return q
        }
        var page: [String: Any] = ["site": site]
        for key in ["title", "heading", "description"] { if let v = context[key] as? String, !v.isEmpty { page[key] = v } }
        if let text = context["text"] as? String { page["text"] = String(text.prefix(1500)) }
        let request: [String: Any] = ["person": profile.said, "page": page, "questions": questions]
        guard let json = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
              let body = String(data: json, encoding: .utf8) else { return done([]) }
        let prompt = "Answer these form questions for me.\n\n" + body
        // ChatGPT, Cursor and Gemini write a form's drafts in one run with no tools.
        if let writer = cli, writer != "claude" {
            codexRunning = true
            codexAsked += 1
            Task { @MainActor in
                let ran = await PlanText.write(prompt, system: FormDraft.system, room: "agent/forms",
                                               codexModel: FormDraft.codexModel, codexEffort: (FormDraft.codexModel != nil ? FormDraft.effort : nil) ?? "low", limit: 45, only: writer)
                self.codexRunning = false
                self.codexSaid = ran.cli == nil ? "no answer" : "wrote"
                let texts = FormDraft.parse(ran.text)
                done(texts.count == steps.count ? texts : [])
            }
            return
        }
        claude.ask(prompt, within: 45) { text in
            let texts = text.map(FormDraft.parse) ?? []
            done(texts.count == steps.count ? texts : [])
        }
    }

    /// Started ahead of the first draft: a page with a question in words
    /// has loaded, and the caret may come into it any moment. Nothing is
    /// asked yet; the ten minutes begin again.
    func warm() {
        guard usable, warms, FormDraft.on else { return }
        claude.warm()
    }

    /// The JSON array in what came back, whatever was said around it.
    nonisolated static func parse(_ text: String) -> [String] {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return list.map { ($0 as? String ?? "").replacingOccurrences(of: "\u{2014}", with: ",").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func stop() { claude.stop() }
}
