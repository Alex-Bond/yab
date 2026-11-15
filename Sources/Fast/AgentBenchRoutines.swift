import AppKit
import WebKit

// Bench.agentCommand's verbs (AgentBench). Routines, watches and the folders
// they keep, and rows put on the new tab.

extension Bench {
    static let routinesVerbs: [String: AgentHandler] = [
        "agent-routine-add": { $0.handleAgentRoutineAdd($1) },
        "agent-routine-folder": { $0.handleAgentRoutineFolder($1) },
        "agent-watch": { $0.handleAgentWatch($1) },
        "agent-routines": { $0.handleAgentRoutines($1) },
        "agent-routine-remove": { $0.handleAgentRoutineRemove($1) },
        "agent-routine-run": { $0.handleAgentRoutineRun($1) },
        "agent-routine-turn": { $0.handleAgentRoutineTurn($1) },
        "agent-routine-duplicate": { $0.handleAgentRoutineDuplicate($1) },
        "agent-routine-tick": { $0.handleAgentRoutineTick($1) },
        "agent-routine-age": { $0.handleAgentRoutineAge($1) },
        "agent-folder-update": { $0.handleAgentFolderUpdate($1) },
        "agent-suggest": { $0.handleAgentSuggest($1) },
        "agent-row-check": { $0.handleAgentRowCheck($1) },
        "agent-repeat-chat": { $0.handleAgentRepeatChat($1) },
        "agent-keep-folder": { $0.handleAgentKeepFolder($1) },
        "agent-row-watch": { $0.handleAgentRowWatch($1) },
        "agent-folder": { $0.handleAgentFolder($1) },
    ]

    func handleAgentRoutineAdd(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        switch Routines.shared.add(when: request["when"] as? String ?? "", prompt: request["prompt"] as? String ?? "",
                                   title: request["title"] as? String) {
        case .success(var made):
            // A test run's routine that keeps a folder, and how it tells.
            if request["folder"] as? Bool == true || request["tell"] != nil || request["project"] != nil {
                // In a chat project, its runs' chat with it (Routine.project).
                if let project = request["project"] as? String { made.project = Projects.shared.project(project)?.id }
                if request["folder"] as? Bool == true {
                    made.folder = true
                    // As Settings' save of one does.
                    c.browser.prefs.usesLiveFolders = true
                }
                if let tell = request["tell"] as? String { made.tell = tell }
                _ = Routines.shared.put(made)
            }
            answer(["id": made.id, "when": made.when])
        case .failure(let trouble): answer(["error": trouble.said])
        }
    }

    func handleAgentRoutineFolder(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        // A routine's folder as the column shows it: its row's words and its tabs'.
        guard let routine = Routines.shared.all.first(where: { $0.id == (request["id"] as? String ?? "") }) else { answer(["error": "no routine"]); return }
        // As the clock would, now: what a run handed it while away.
        LiveFolders.shared.settle()
        if let open = request["open"] as? Bool, let nest = LiveFolders.shared.folder(of: routine, in: browser) { nest.open = open }
        if let look = request["look"] as? String, let tab = browser.tabs.first(where: { $0.label == look }) { browser.select(tab) }
        guard let nest = LiveFolders.shared.folder(of: routine, in: browser) else { answer(["folder": false]); return }
        let tabs = browser.tabs.filter { $0.nest === nest }
        // Every folder of it anywhere, for a check that there is one.
        let all = BrowserWindows.shared.browsers.flatMap { other in
            LiveFolders.nests(in: other).filter { $0.live?.source == "routine" && $0.live?.host == routine.id }.map { found -> String in
                "\(found.id.uuidString.prefix(6))·\(ObjectIdentifier(found).hashValue % 10000)·\(other.tabs.filter { $0.nest === found }.count)·\(other === browser ? "here" : "other")"
            }
        }
        answer(["folders": all, "folder": true, "name": nest.name, "open": nest.open, "checking": LiveFolders.shared.checking(nest),
                "waiting": LiveFolders.waiting(nest, in: browser), "status": Routines.status(routine, live: agents.session(routine.session)?.state.live == true),
                "tabs": tabs.map { tab -> [String: Any] in
                    ["title": tab.label, "url": tab.address?.absoluteString ?? "", "words": tab.live?.said?.text ?? "",
                     "loud": tab.live?.said?.loud == true, "gone": tab.live?.said?.gone == true, "asleep": tab.asleep,
                     "yours": tab.live?.yours == true, "calls": tab.live?.callsOut == true]
                }])
    }

    func handleAgentWatch(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        if let stop = request["stop"] as? String, !stop.isEmpty {
            answer(Routines.shared.remove(stop) ? ["ok": true] : ["error": "no watch \(stop)"])
            return
        }
        switch Routines.shared.watch(url: request["url"] as? String ?? "", who: request["who"] as? String ?? "", days: request["days"] as? Double ?? 3) {
        case .success(let made): answer(["id": made.id, "title": made.title ?? ""])
        case .failure(let trouble): answer(["error": trouble.said])
        }
    }

    func handleAgentRoutines(_ c: AgentCall) {
        let answer = c.answer
        let agents = c.agents
        let stamp = ISO8601DateFormatter()
        answer(["routines": Routines.shared.all.map { routine -> [String: Any] in
            let live = agents.session(routine.session)?.state.live == true
            return ["id": routine.id, "when": routine.when, "prompt": routine.prompt, "said": routine.said ?? "",
                    "last": routine.last.map { stamp.string(from: $0) } ?? "", "name": routine.name, "off": routine.off == true,
                    "status": Routines.status(routine, live: live), "live": live, "session": routine.session ?? "",
                    "chat": routine.chat ?? "", "found": routine.found ?? -1, "ended": routine.ended.map { stamp.string(from: $0) } ?? "",
                    "next": Routines.next(routine, after: Date()).map { stamp.string(from: $0) } ?? "",
                    "here": routine.runsHere, "runsOn": routine.runsOn ?? ""]
        }])
    }

    /// Turned off or on, as its menus do (`yab every pause|resume ID`).
    func handleAgentRoutineTurn(_ c: AgentCall) {
        let request = c.request
        guard let routine = Routines.shared.all.first(where: { $0.id == (request["id"] as? String ?? "") }) else {
            c.answer(["error": "no routine \(request["id"] as? String ?? "")"]); return
        }
        Routines.shared.turn(routine.id, on: request["on"] as? Bool ?? true)
        c.answer(["ok": true, "off": Routines.shared.all.first { $0.id == routine.id }?.off == true])
    }

    /// Duplicate, as its menu does: the copy's id.
    func handleAgentRoutineDuplicate(_ c: AgentCall) {
        let before = Set(Routines.shared.all.map(\.id))
        Routines.shared.duplicate(c.request["id"] as? String ?? "")
        c.answer(["id": Routines.shared.all.first { !before.contains($0.id) }?.id ?? ""])
    }

    /// The minute's look now, rather than on its clock: the sessions it started.
    func handleAgentRoutineTick(_ c: AgentCall) {
        let before = Dictionary(Routines.shared.all.map { ($0.id, $0.session) }, uniquingKeysWith: { a, _ in a })
        Routines.shared.tick()
        c.answer(["started": Routines.shared.all.filter { $0.session != nil && before[$0.id] != $0.session }.map(\.id)])
    }

    /// Time gone by, as a Mac asleep through it would have it: its last
    /// run `seconds` earlier. --test only.
    func handleAgentRoutineAge(_ c: AgentCall) {
        guard Store.testing else { c.answer(["error": "agent-routine-age only works on a --test run"]); return }
        let id = c.request["id"] as? String ?? ""
        let seconds = c.request["seconds"] as? Double ?? 0
        guard Routines.shared.age(id, by: seconds) else { c.answer(["error": "no routine \(id)"]); return }
        c.answer(["ok": true])
    }

    func handleAgentRoutineRemove(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        answer(Routines.shared.remove(request["id"] as? String ?? "") ? ["ok": true] : ["error": "no routine \(request["id"] as? String ?? "")"])
    }

    func handleAgentRoutineRun(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // By its id, or its name (a timed eval's routine, whose id it never saw).
        guard let routine = Routines.shared.all.first(where: { $0.id == (request["id"] as? String ?? "") })
            ?? (request["title"] as? String).flatMap({ title in Routines.shared.all.first { $0.name == title } }) else {
            answer(["error": "no routine \(request["id"] as? String ?? "")"]); return
        }
        if let task = Routines.shared.run(routine) { answer(["session": task.id]) }
        else { answer(["error": Routines.shared.lastProblem ?? "This routine cannot run now."]) }
    }

    func handleAgentFolderUpdate(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let session = c.session
        // A routine's run hands its folder what belongs (Routines.folderWords).
        guard let routine = Routines.shared.running(session), routine.folder == true else {
            answer(["error": "this run keeps no folder: hand findings to suggest"]); return
        }
        let raw = request["items"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        let items = raw.prefix(Routines.folderMost + 10).compactMap { item -> LiveItem? in
            guard let url = (item["url"] as? String).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true,
                  let key = LiveFolder.page(url), seen.insert(key).inserted else { return nil }
            let words = (item["words"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let gone = item["gone"] as? Bool == true
            return LiveItem(key: key, url: url, title: title.isEmpty ? url.host() ?? url.absoluteString : String(title.prefix(120)),
                            group: "", words: nil, updated: nil,
                            said: words.isEmpty && !gone ? nil : LiveSaid(text: words.isEmpty ? "Gone" : String(words.prefix(40)),
                                                                         loud: item["loud"] as? Bool == true && !gone, gone: gone))
        }
        // Gone ones aren't counted against the folder's room.
        let kept = Array(items.filter { $0.said?.gone != true }.prefix(Routines.folderMost)) + items.filter { $0.said?.gone == true }
        guard let diff = LiveFolders.shared.keep(routine, kept, in: browser) else {
            answer(["error": "its folder couldn't be made in this window"]); return
        }
        Routines.shared.suggested(diff.add.count, by: session)
        let changed = diff.said.count
        answer(["text": "Folder «\(routine.name)» updated: \(diff.add.count) came in, \(changed) changed words, \(diff.remove.count) gone."])
    }

    func handleAgentSuggest(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let session = c.session
        let items = request["items"] as? [[String: Any]] ?? []
        let resolved = request["resolved"] as? [String] ?? []
        let quiet = request["quiet"] as? [String] ?? []
        // A routine's run says whose the rows are, and counts them.
        let routine = Routines.shared.finder(of: session)
        // Where the person has been, read off the main thread: a row may
        // lead only there.
        DispatchQueue.global(qos: .userInitiated).async {
            let known = AgentHistory.knownHosts()
            DispatchQueue.main.async {
                // Threads the look read and found waiting on no one.
                MailCenter.shared.quiet(quiet)
                let glance = c.agents.session(session)?.name == "Glancing"
                if let trouble = Hints.shared.keep(items, resolved: resolved, known: known, by: routine?.name, look: !glance) { answer(["error": trouble]); return }
                // Counted as found only what may stand as a row.
                Routines.shared.suggested(Hints.admit(items, known: known).items.count, by: session)
                answer(["ok": true, "kept": min(items.count, 4)])
            }
        }
    }

    func handleAgentRowCheck(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // Observe the same benchOpen + ownership assignment as `open`,
        // before its asynchronous list watcher can repair placement.
        // Interleaved user tabs also exercise gather's synchronous pass.
        guard Store.testing else { answer(["error": "agent-row-check only works on a --test run"]); return }
        guard let owner = agents.session(session),
              let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
            answer(["error": "agent-row-check needs a session and URL"]); return
        }
        let tab = browser.benchOpen(url)
        tab.agent = owner.id
        let root = agents.root(of: owner.id)
        let members = browser.tabs.filter { $0.agent != nil && agents.root(of: $0.agent) == root }
        answer(["id": Bench.short(tab), "members": members.map(Bench.short),
                "loose": members.filter { Folders.shared.place(of: $0) == nil }.map(Bench.short)])
    }

    func handleAgentRepeatChat(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let session = c.session
        guard Store.testing, let chat = Chats.shared.chat(session) else {
            answer(["error": "agent-repeat-chat needs a test chat"]); return
        }
        if request["action"] as? String == "custom" {
            Routines.shared.repeatChatCustom(chat, asked: request["prompt"] as? String ?? "Repeat this task",
                                            folder: request["folder"] as? Bool ?? true, in: browser)
            let draft = RoutineEditing.shared.sheet?.routine
            answer(["id": draft?.id ?? "", "folder": draft?.folder == true, "window": NSApp.keyWindow?.windowNumber ?? 0])
            return
        }
        if request["action"] as? String == "cancel" {
            RoutineEditing.shared.sheet = nil
            SettingsWindow.shared.hide()
            answer(["ok": true])
            return
        }
        if request["action"] as? String == "save", var draft = RoutineEditing.shared.sheet?.routine {
            if let folder = request["folder"] as? Bool { draft.folder = folder ? true : nil }
            switch Routines.shared.put(draft) {
            case .success(let made):
                RoutineEditing.shared.sheet = nil
                SettingsWindow.shared.hide()
                answer(["id": made.id])
            case .failure(let trouble): answer(["error": trouble.said])
            }
            return
        }
        let before = Set(Routines.shared.all.map(\.id))
        Routines.shared.repeatChat(chat, asked: request["prompt"] as? String ?? "Repeat this task",
                                  when: request["when"] as? String ?? "hourly", folder: request["folder"] as? Bool ?? true, in: browser)
        answer(["id": Routines.shared.all.first { !before.contains($0.id) }?.id ?? ""])
    }

    func handleAgentKeepFolder(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        guard Store.testing, let nest = browser.nests.first(where: { $0.name == request["folder"] as? String }) else {
            answer(["error": "agent-keep-folder needs a test folder"]); return
        }
        if request["save"] as? Bool == true, let draft = RoutineEditing.shared.sheet?.routine {
            switch Routines.shared.put(draft) {
            case .success(let made):
                RoutineEditing.shared.sheet = nil
                SettingsWindow.shared.hide()
                answer(["id": made.id])
            case .failure(let trouble): answer(["error": trouble.said])
            }
        } else {
            Routines.shared.keepFolder(nest, in: browser)
            let draft = RoutineEditing.shared.sheet?.routine
            answer(["id": draft?.id ?? "", "title": draft?.title ?? "", "prompt": draft?.prompt ?? "",
                    "folder": draft?.folder == true, "tabs": draft?.tabs ?? [], "window": NSApp.keyWindow?.windowNumber ?? 0])
        }
    }

    func handleAgentRowWatch(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // Every turn, just before it is drawn: an agent's tab that belongs
        // in its task's folder but has no place there, a loose row for
        // that frame. "start", then "stop" for what was seen. --test only.
        guard Store.testing else { answer(["error": "agent-row-watch only works on a --test run"]); return }
        if request["action"] as? String == "stop" {
            RowWatch.stop()
            answer(["turns": RowWatch.turns, "loose": RowWatch.loose])
        } else {
            RowWatch.start(browser)
            answer(["ok": true])
        }
    }

    func handleAgentFolder(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // A task's folder opened or shut, or one of its tabs kept,
        // without a hand, a --test run only; "tap": clicked, as its row
        // or pill is (a sealed one's shows its chat).
        guard Store.testing else { answer(["error": "agent-folder only works on a --test run"]); return }
        let folders = Folders.shared
        if let tab = find(request, in: browser), request["keep"] as? Bool == true {
            folders.keep(tab)
            answer(["ok": true])
            return
        }
        guard let folder = folders.folders.first(where: { $0.id == (request["folder"] as? String ?? $0.id) }) else { answer(["error": "no folder"]); return }
        // "read": only whether it is open, nothing touched.
        if request["read"] as? Bool == true {
            answer(["folder": folder.id, "open": folders.isOpen(folder.id), "tabs": folder.members.count])
            return
        }
        if request["tap"] as? Bool == true { Folders.tapped(folder, in: browser) } else { folders.toggle(folder.id) }
        // Read once the turn has landed: the folder opens on its clock,
        // and asked at once it still said it was shut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            answer(["folder": folder.id, "open": folders.isOpen(folder.id), "tabs": folder.members.count, "sealed": folder.sealed,
                    "title": Folders.title(folder.id), "chat": browser.chatOpen ? browser.chatShown ?? "" : ""])
        }
    }
}
