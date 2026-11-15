import AppKit

// Bench.agentCommand's verbs (AgentBench). Things an agent makes for you
// rather than explains: a file of its words (save_file, written by `yab
// mcp` into the folder named here) and the clipboard (copy).

extension Bench {
    static let madeVerbs: [String: AgentHandler] = [
        "agent-task-folder": { $0.handleAgentTaskFolder($1) },
        "agent-copy": { $0.handleAgentCopy($1) },
    ]

    /// The task's own folder, ~/Downloads/yab/<task>/, for save_file:
    /// `yab mcp` writes there itself, since five megabytes of words are
    /// more than one bench line takes.
    func handleAgentTaskFolder(_ c: AgentCall) {
        guard let session = c.session else { c.answer(["error": "save_file needs a task"]); return }
        if session != Agents.script, let known = c.agents.session(session), !known.state.live {
            c.answer(["error": "this task has ended or was stopped by the user: stop now"])
            return
        }
        if let name = c.request["name"] as? String, !name.isEmpty { c.agents.touch(session, "save · \(name)") }
        c.answer(["folder": AgentFiles.shared.folder(for: session).path])
    }

    func handleAgentCopy(_ c: AgentCall) {
        let request = c.request
        guard let session = c.session else { c.answer(["error": "copy needs a task"]); return }
        if session != Agents.script, let known = c.agents.session(session), !known.state.live {
            c.answer(["error": "this task has ended or was stopped by the user: stop now"])
            return
        }
        let clip: AgentClip
        do {
            clip = try AgentClip.make(text: request["text"] as? String, url: request["url"] as? String, title: request["title"] as? String,
                                      quote: request["quote"] as? String, file: request["file"] as? String, what: request["what"] as? String,
                                      folder: AgentFiles.shared.folder(for: session))
        } catch {
            c.answer(["error": (error as? AgentClip.Trouble)?.said ?? error.localizedDescription])
            return
        }
        clip.put(on: .general)
        AgentClips.shared.keep(clip)
        clip.remember()
        c.agents.touch(session, "copy · \(clip.what)")
        c.answer(["answer": clip.answer, "what": clip.what, "clip": clip.id])
    }
}
