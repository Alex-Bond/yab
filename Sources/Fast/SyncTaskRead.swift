import AppKit
import SyncKit
import WebKit

// Tasks sent from the iPhone, read-only (docs/sync.md, "Tasks from the
// iPhone"). SyncCenter takes each `taskcommand` record addressed to this
// Mac, reserves it once in the journal (TaskLaunch) and starts its agent
// with the read-only MCP server; every call that agent makes comes here
// (Bench.remoteTaskReader) and nowhere else. It may open, read and close
// pages of its own, behind the tabs, in its space's website store, and
// nothing else: no clicks, typing, forms, downloads, sign-ins, other tabs,
// other spaces or native tools. What the session does goes back to the
// iPhone as the task's `task` record (TaskObservation), checked against the
// journal's own checkpoint, so a late callback can't rewrite a result.
// Approvals signed on the iPhone (TaskApproval) are not taken yet.

@MainActor
final class SyncTaskRead {
    struct Context {
        let client: SyncClient
        let phones: [SyncClient.Listed]
        let browser: Browser
    }

    static let verbs: Set<String> = ["agent-caps", "agent-tabs", "open", "agent-go", "nav", "snapshot", "text", "settle", "wait",
                                     "close", "agent-name", "agent-file"]
    static let tools: Set<String> = ["tabs", "open", "navigate", "snapshot", "text", "wait", "close", "name"]
    /// At most this many pages of its own at once.
    static let pages = 8

    private final class Entry {
        let mapping: TaskLaunch.Mapping
        let request: TaskRecords.Request
        weak var client: SyncClient?
        weak var browser: Browser?
        let store: WKWebsiteDataStore
        var pages: [UUID: RemoteReadPage] = [:]
        var last: AgentTaskObservation?
        var blocked: String?
        var storageFailed = false

        init(mapping: TaskLaunch.Mapping, request: TaskRecords.Request, client: SyncClient, browser: Browser, store: WKWebsiteDataStore) {
            self.mapping = mapping; self.request = request; self.client = client; self.browser = browser; self.store = store
        }
    }

    private let current: () -> Context?
    private let agents: Agents
    private var observer: UUID?
    private var entries: [String: Entry] = [:]
    private var stopped = false
    private(set) var checkpointFailed = false

    init(agents: Agents, current: @escaping () -> Context?) {
        self.agents = agents; self.current = current
        observer = agents.observeRemoteTasks { [weak self] in self?.observed($0) }
    }

    isolated deinit {
        if let observer { agents.stopObservingRemoteTasks(observer) }
        stop()
    }

    /// The task's own space here, found by the id sync gives it in either case.
    private static func space(_ id: String, in browser: Browser) -> Space? {
        browser.spaces.first { ContinuePage.sameSpace($0.id.uuidString, id) }
    }

    /// Whether this Mac has the space a request names, and can read in it.
    static func has(space id: String, in browser: Browser) -> Bool { space(id, in: browser) != nil }

    private static func phone(_ id: String, among phones: [SyncClient.Listed]) -> Bool {
        phones.contains { $0.id == id && !$0.revoked && $0.isMobile }
    }

    /// Takes the calls of a prepared session from now on. Everything is
    /// checked again on each call: the line, the account, the phone, the
    /// journal's reservation and the space's website store.
    func register(_ mapping: TaskLaunch.Mapping) throws {
        guard !stopped, let context = current(), context.client.state == .live,
              let space = Self.space(mapping.space, in: context.browser),
              Self.phone(mapping.phone, among: context.phones),
              context.client.device.id == mapping.mac, context.client.seal.account == mapping.account,
              try context.client.journal.taskMapping(request: mapping.request, account: mapping.account, device: mapping.mac) == mapping,
              agents.session(mapping.session)?.remoteTask?.mapping == mapping,
              let original = context.client.journal.record(.init(collection: TaskRecords.requestCollection, id: mapping.request)) else {
            throw TaskLaunch.Failure.context
        }
        let request = try TaskRecords.Request.read(original, account: mapping.account, phone: mapping.phone, mac: mapping.mac)
        guard try request.digest() == mapping.digest,
              !context.browser.tabs.contains(where: { $0.id.uuidString.lowercased() == request.tab?.lowercased() && $0.shy }) else {
            throw TaskLaunch.Failure.context
        }
        if let had = entries[mapping.session] {
            guard had.mapping == mapping, had.client === context.client else { throw TaskLaunch.Failure.context }
            return
        }
        entries[mapping.session] = Entry(mapping: mapping, request: request, client: context.client, browser: context.browser,
                                         store: Spaces.store(for: space.id))
    }

    /// Sync off, or another account: every page of every task goes, and
    /// tasks still at work are stopped. Nothing is registered after.
    func stop() {
        if let observer { agents.stopObservingRemoteTasks(observer); self.observer = nil }
        stopped = true
        for entry in entries.values {
            for page in entry.pages.values {
                page.retire()
                if let browser = entry.browser, let tab = page.tab { browser.closeRemoteReadTab(tab, session: entry.mapping.session) }
            }
            if agents.session(entry.mapping.session)?.state.live == true { _ = agents.stop(entry.mapping.session) }
        }
        entries = [:]
    }

    /// Whether a task's session is one this reader answers for.
    func owns(_ session: String) -> Bool { entries[session] != nil }

    /// The line came back: what each session did meanwhile goes up now.
    func resume() {
        for entry in entries.values {
            guard let session = agents.session(entry.mapping.session) else { continue }
            observed(session)
        }
    }

    /// The source, the active client and the captured website store are
    /// checked on every call and again before a page's words are handed back.
    private func valid(_ entry: Entry, browser: Browser? = nil) -> Context? {
        guard !stopped, entries[entry.mapping.session] === entry, !entry.storageFailed,
              let context = current(), context.client === entry.client,
              context.client.state == .live, context.client.seal.account == entry.mapping.account,
              context.client.device.id == entry.mapping.mac,
              entry.browser === context.browser, browser.map({ $0 === context.browser }) ?? true,
              Self.phone(entry.mapping.phone, among: context.phones),
              let space = Self.space(entry.mapping.space, in: context.browser),
              Spaces.store(for: space.id) === entry.store,
              (try? context.client.journal.taskMapping(request: entry.mapping.request,
                                                      account: entry.mapping.account, device: entry.mapping.mac)) == entry.mapping,
              agents.session(entry.mapping.session)?.remoteTask?.mapping == entry.mapping else { return nil }
        return context
    }

    private func observed(_ session: Agents.Session) {
        guard let entry = entries[session.id], !stopped, !entry.storageFailed else { return }
        // Off the line for a moment: said when it comes back (resume).
        guard let context = current(), context.client === entry.client, context.client.state == .live else { return }
        guard valid(entry) != nil else { return }
        let snapshot = AgentTaskObservation(session)
        guard snapshot != entry.last else { return }
        do {
            let previous = try context.client.journal.taskObservation(mapping: entry.mapping,
                                                                       account: entry.mapping.account, device: entry.mapping.mac)
            if let previous, [TaskRecords.Status.done, .failed, .stopped].contains(previous.status) { return }
            guard previous?.revision != UInt64.max else { throw TaskObservation.Failure.stale }
            let revision = (previous?.revision ?? 0) + 1
            let observation: TaskRecords.Observation
            if let blocked = entry.blocked, ![TaskRecords.Status.failed, .stopped, .done].contains(snapshot.status) {
                observation = try TaskRecords.Observation(request: entry.request, revision: revision, session: session.id,
                                                           status: .needsYou, title: snapshot.title, progress: blocked)
            } else { observation = try snapshot.record(request: entry.request, mapping: entry.mapping, revision: revision) }
            _ = try TaskObservation.checkpoint(observation, mapping: entry.mapping, client: context.client, knownPhones: context.phones)
            entry.last = snapshot
        } catch {
            entry.storageFailed = true
            checkpointFailed = true
            entry.pages.values.forEach { $0.retire() }
            if session.state.live { _ = agents.stop(session.id) }
        }
    }

    private func block(_ entry: Entry, _ message: String) {
        entry.blocked = message
        entry.last = nil
        if let session = agents.session(entry.mapping.session) {
            agents.note(session, message)
        }
    }

    /// True for every call from a task from the iPhone, unknown verbs too:
    /// nothing refused here falls through to the browser's ordinary rules.
    func handle(_ request: [String: Any], browser: Browser, bench: Bench, answer: @escaping ([String: Any]) -> Void) -> Bool {
        let sourceIDs = RemoteTaskBoundary.sourceIDs(request)
        guard sourceIDs.contains(where: { agents.remoteTaskOrigin($0) != nil }) else { return false }
        guard let id = (request["callerSession"] as? String) ?? (request["session"] as? String),
              let entry = entries[id], sourceIDs.allSatisfy({ $0 == id }), request["resume"] == nil,
              valid(entry, browser: browser) != nil, let session = agents.session(id),
              session.state.live, !session.full, session.parent == nil else {
            answer(["error": RemoteTaskBoundary.unavailable]); return true
        }
        let verb = request["do"] as? String ?? ""
        guard Self.verbs.contains(verb), request["body"] == nil, request["headers"] == nil,
              request["method"] == nil || request["method"] as? String == "GET",
              request["space"] == nil else {
            let message = "A task from iPhone can only read pages of its own. This needs the person on their Mac."
            block(entry, message); answer(["error": message]); return true
        }
        func rows() -> [Tab] {
            browser.tabs.filter { entry.pages[$0.id]?.tab === $0 && $0.bench && !$0.shy && $0.agent == id && $0.id != browser.activeID }
        }
        func describe(_ tab: Tab) -> [String: Any] {
            ["id": tab.id.uuidString.lowercased(), "title": tab.title, "url": tab.address?.absoluteString ?? "", "bench": true, "whose": "yours"]
        }
        func target() -> Tab? {
            guard let raw = request["id"] as? String, !raw.isEmpty else { return nil }
            // Full ids only: no prefix, no "all".
            return rows().first { $0.id.uuidString.lowercased() == raw.lowercased() }
        }
        func safeAnswer(_ result: [String: Any]) {
            guard self.valid(entry, browser: browser) != nil, session.state.live else {
                answer(["error": RemoteTaskBoundary.unavailable]); return
            }
            answer(Wallet.hide(result) as? [String: Any] ?? result)
        }
        switch verb {
        case "agent-caps":
            safeAnswer(["readOnly": true, "canWrite": false, "tabs": true, "native": false, "computer": false, "mail": false, "messages": false])
        case "agent-tabs": safeAnswer(["tabs": rows().map(describe)])
        case "agent-name":
            session.title = String((request["name"] as? String ?? session.name).prefix(80))
            session.progress = String((request["progress"] as? String ?? session.now).prefix(160))
            agents.note(session, session.progress ?? session.now)
            safeAnswer(["ok": true])
        case "agent-file":
            // Its pages are behind the tabs, in no folder of the person's.
            guard target() != nil else { safeAnswer(["error": "No owned read page."]); return true }
            safeAnswer(["ok": true, "unnamed": false])
        case "open":
            guard rows().count < Self.pages, let raw = request["url"] as? String, let url = URL(string: raw),
                  RemoteReadPage.permits(URLRequest(url: url)) else {
                safeAnswer(["error": "Only an HTTP(S) page can be opened, at most \(Self.pages) at once."]); return true
            }
            let policy = RemoteReadPage(current: { [weak self, weak entry, weak browser] in
                guard let self, let entry, let browser, let owner = self.agents.session(entry.mapping.session) else { return false }
                return self.valid(entry, browser: browser) != nil && owner.state.live && !owner.full && owner.parent == nil
            }, refused: { [weak self, weak entry] message in
                guard let self, let entry else { return }
                self.block(entry, message)
            })
            let tab = browser.makeRemoteReadTab(url: url, store: entry.store, session: id, policy: policy)
            policy.tab = tab
            entry.pages[tab.id] = policy
            bench.house(tab)
            safeAnswer(describe(tab))
        case "agent-go":
            guard let tab = target(), let raw = request["url"] as? String, let url = URL(string: raw),
                  RemoteReadPage.permits(URLRequest(url: url)) else { safeAnswer(["error": "No owned read page or HTTP(S) address."]); return true }
            tab.go(to: url)
            safeAnswer(describe(tab))
        case "nav":
            guard let tab = target() else { safeAnswer(["error": "No owned read page."]); return true }
            switch request["how"] as? String {
            case "back": tab.page.navigateBack()
            case "forward": tab.page.navigateForward()
            case "reload": tab.page.reload(fromOrigin: false)
            default: safeAnswer(["error": "Only back, forward or reload."]); return true
            }
            safeAnswer(describe(tab))
        case "close":
            guard let tab = target() else { safeAnswer(["error": "No owned read page."]); return true }
            browser.closeRemoteReadTab(tab, session: id)
            entry.pages[tab.id] = nil
            safeAnswer(["ok": true])
        case "snapshot", "text":
            guard let tab = target() else { safeAnswer(["error": "No owned read page."]); return true }
            bench.house(tab)
            if verb == "snapshot" {
                AgentPage.read(tab, interactive: request["interactive"] as? Bool ?? true, ref: nil, since: false,
                               takeMemoryNotice: {
                                   guard target() === tab else { return nil }
                                   return StuckWatch.notices.removeValue(forKey: tab.id)
                               }) { result in
                    guard target() === tab else { answer(["error": "The owned read page changed."]); return }
                    safeAnswer(result)
                }
            } else {
                AgentPage.run(tab, AgentPage.readable) { result in
                    guard target() === tab else { answer(["error": "The owned read page changed."]); return }
                    if case let .success(value) = result, let body = value as? [String: Any] { safeAnswer(body) }
                    else { safeAnswer(["error": "The page could not be read."]) }
                }
            }
        case "settle", "wait":
            guard let tab = target() else { safeAnswer(["error": "No owned read page."]); return true }
            let seconds = (request["seconds"] as? NSNumber)?.doubleValue ?? 10
            guard seconds.isFinite, (0...20).contains(seconds) else { safeAnswer(["error": "Wait must be between zero and twenty seconds."]); return true }
            let deadline = Date().addingTimeInterval(seconds)
            func poll() {
                guard self.valid(entry, browser: browser) != nil, target() === tab, session.state.live else {
                    answer(["error": RemoteTaskBoundary.unavailable]); return
                }
                if !tab.loading || Date() >= deadline { safeAnswer(describe(tab).merging(["timeout": tab.loading]) { $1 }); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
            poll()
        default: answer(["error": RemoteTaskBoundary.unavailable])
        }
        return true
    }
}
