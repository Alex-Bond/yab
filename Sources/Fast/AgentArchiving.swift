import Foundation

extension Agents {
    /// Only work Yab launched out of sight, never a person's provider chat
    /// attached from a terminal or a normal agent conversation.
    static func archivesProvider(_ session: Session) -> Bool {
        ["claude", "codex"].contains(session.cli) && (session.providerBackground || session.quiet || session.sealed || session.parent != nil)
    }

    /// Also a chat Yab itself began (a task from the field or a page, a
    /// routine): it lives in Yab's chats, so the provider's own app need
    /// not list it. Carrying it on unarchives it first (CodexServer). So is
    /// one a command line began (`yab "…"`, a script's or another agent's
    /// watcher every few minutes): its answer went back to whoever ran it.
    static func archivesAfterAnswer(_ session: Session) -> Bool {
        archivesProvider(session) || ["claude", "codex"].contains(session.cli)
            && (session.task || session.routine != nil || session.origin == .newTabs || session.origin == .here || session.person != "app")
    }

    /// The answer is already kept in Yab. Retain this process's stdin until
    /// Codex acknowledges the archive; a resumed task waits for retirement.
    func archiveProvider(_ session: Session) {
        guard !session.state.live, Self.archivesAfterAnswer(session), session.archiveTask == nil,
              let thread = session.thread, !thread.isEmpty else { return }
        // Old Codex exec cannot fork: fork_self resumes the parent's exact
        // provider thread. That history still belongs to the parent.
        if let parent = self.session(session.parent), parent.cli == session.cli, parent.thread == thread { return }
        let cli = session.cli, binary = session.binary
        let env = session.providerEnvironment.isEmpty ? session.env : session.providerEnvironment
        let args = session.providerArchiveArgs
        let process = session.process, server = session.server, input = session.input
        session.retiringProcess = process
        session.input = nil
        let folder = process?.currentDirectoryURL ?? Self.workingFolder(cli: cli, id: session.id, full: session.full, folder: session.folder)
        // A probe must not write Claude Desktop's real records either.
        let user = Store.testing ? Store.file("provider-user") : AgentSetup.home
        session.archiveTask = Task { @MainActor in
            guard session.providerPermit?.valid == true else { return }
            var error: String?
            var archived = false
            if cli == "codex", let server {
                error = await withCheckedContinuation { done in
                    server.archive { done.resume(returning: $0) }
                }
                archived = error == nil
            }
            try? input?.close()
            // Claude can still save after its result; archive the final record.
            // Also let a failed/interrupted Codex process unload before retrying
            // its archive through a fresh server in the exact same home.
            let until = ProcessInfo.processInfo.systemUptime + 10
            while process?.isRunning == true, ProcessInfo.processInfo.systemUptime < until {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process?.isRunning == true {
                if !archived { error = "The background agent has not exited; its history was left alone." }
            } else if cli == "codex", !archived {
                guard let permit = session.providerPermit, permit.valid else { return }
                error = await AgentArchive.codex(thread: thread, binary: binary, env: env, folder: folder, args: args, permit: permit)
            } else if cli == "claude" {
                guard session.providerPermit?.valid == true else { return }
                do { _ = try await Task.detached { try AgentArchive.claude(thread: thread, user: user) }.value }
                catch let failure { error = failure.localizedDescription }
            }
            // Cleanup can fail without changing the answer or terminal state.
            session.archiveError = error
        }
    }
}

extension AgentArchive {
    /// Older `exec --json` sessions and interrupted servers have already
    /// exited. Archive by exact id through the provider, without a model turn
    /// or resuming/unarchiving the conversation first.
    static func codex(thread: String, binary: String, env: [String: String], folder: URL, args: [String] = [], permit: ProviderLaunchPermit) async -> String? {
        let reply = await Shell.talk(binary, ["app-server"] + args, env: env, in: folder, saying: [
            ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "yab", "version": "0"], "capabilities": NSNull()]],
            ["method": "initialized", "params": [:]],
            ["id": 2, "method": "thread/archive", "params": ["threadId": thread]],
        ], limit: 10, permit: permit) { $0["id"] as? Int == 2 }
        guard let reply else { return "ChatGPT did not acknowledge the background archive." }
        if let failure = reply["error"] as? [String: Any] {
            return failure["message"] as? String ?? "ChatGPT could not archive the background conversation."
        }
        guard reply["result"] as? [String: Any] != nil else { return "ChatGPT returned an invalid archive acknowledgement." }
        return nil
    }
}
