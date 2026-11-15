import Foundation

// One Claude Code kept running between asks (stream-json in and out), so an
// answer doesn't wait out its start: cold, Claude Code takes five to ten
// seconds before a word comes, nearly all of it its own start; kept warm,
// Haiku says a few words in about a second. Form drafts (FormDraft) and
// the names of ⌘-click folders (LinkFolders) each keep one. It goes after
// `idle` seconds without an ask or a warm, since each holds memory: Haiku's
// 127 MB footprint on adhd (208 MB resident).

@MainActor
final class WarmClaude {
    /// Where it runs and keeps its stderr, under Store.
    let room: String
    let idle: TimeInterval
    /// Answers after which it is started afresh, so a long day's turns
    /// don't make each ask slower; nil keeps one for as long as it runs.
    let turns: Int?
    /// Claude Code's arguments after -p and the stream-json ones: the model,
    /// the system prompt.
    let args: () -> [String]
    /// Set in its environment over the plan's.
    let env: [String: String]

    init(room: String, idle: TimeInterval, turns: Int? = nil, env: [String: String] = [:], args: @escaping () -> [String]) {
        self.room = room
        self.idle = idle
        self.turns = turns
        self.env = env
        self.args = args
        Self.instances.append(Weak(self))
    }

    private final class Weak { weak var value: WarmClaude?; init(_ value: WarmClaude) { self.value = value } }
    private static var instances: [Weak] = []
    static func revoke() { instances.forEach { $0.value?.stop() } }
    private var permission: ProviderLaunchPermit?
    private var process: Process?
    private var input: FileHandle?
    /// A request's place in line. Claude Code answers in the order it is
    /// asked, so one given up on keeps its place, empty, and its late answer
    /// is dropped rather than handed to the next ask.
    private final class Waiter {
        var done: ((String?) -> Void)?
        init(_ done: @escaping (String?) -> Void) { self.done = done }
    }
    private var waiting: [Waiter] = []
    /// Starts asked for while one is on its way: they all hear that one.
    private var starting: [(Bool) -> Void]?
    private var stopping: DispatchWorkItem?
    private var buffer = Data()
    private var answered = 0
    /// Whether it can be had at all: Claude Code found, and not given up on.
    private(set) var usable = true
    /// What happened last, for the bench: "started", "no claude", "ended", "timed out".
    private(set) var said = ""
    var running: Bool { process?.isRunning ?? false }
    var asked: Int { waiting.filter { $0.done != nil }.count }

    /// The answer's text, or nil when it can't be had or takes longer than
    /// `within` seconds.
    func ask(_ text: String, within: TimeInterval, done: @escaping (String?) -> Void) {
        guard usable else { return done(nil) }
        start { [weak self] ok in
            guard let self else { return }
            guard ok else { return done(nil) }
            let waiter = Waiter(done)
            // Too long: this ask hears nothing, and its answer, if it
            // comes, is dropped where it stands in line.
            DispatchQueue.main.asyncAfter(deadline: .now() + within) { [weak self, weak waiter] in
                guard let waiter, let done = waiter.done else { return }
                waiter.done = nil
                self?.said = "timed out"
                done(nil)
            }
            self.waiting.append(waiter)
            self.send(text)
        }
    }

    func ask(_ text: String, within: TimeInterval) async -> String? {
        await withCheckedContinuation { go in ask(text, within: within) { go.resume(returning: $0) } }
    }

    /// Started ahead of the first ask; nothing is asked yet, and the idle
    /// time begins again.
    func warm() {
        guard usable else { return }
        start { _ in }
    }

    private func start(_ ready: @escaping (Bool) -> Void) {
        // Claude Code runs unasked here: only once you connected it (a
        // test world's stand-in aside).
        guard let permit = ProviderConsent.shared.permit("claude") else { return ready(false) }
        stopping?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopping = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idle, execute: work)
        if let process, process.isRunning { return ready(true) }
        // One process at a time: a second start while the first is on its
        // way waits for it, instead of launching another.
        if starting != nil { starting?.append(ready); return }
        starting = [ready]
        let ready: (Bool) -> Void = { [weak self] ok in
            let all = self?.starting ?? []
            self?.starting = nil
            all.forEach { $0(ok) }
        }
        Task { @MainActor [weak self] in
            let found = await Shell.find()
            guard let self else { return }
            guard permit.valid else { return ready(false) }
            guard let claude = found.claude else {
                self.said = "no claude"
                self.usable = false
                return ready(false)
            }
            let process = Process()
            let args = [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--no-session-persistence", "--tools", "", "--strict-mcp-config",
            ] + self.args()
            Agents.throughShell(process, claude, args)
            process.environment = AgentCopies.environment(for: claude,
                base: PlanAccounts.shared.env(PlanAccounts.shared.pick("claude"), base: found.env).merging(self.env) { $1 })
            let room = Store.file(self.room)
            try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
            process.currentDirectoryURL = room
            let out = Pipe(), into = Pipe()
            process.standardOutput = out
            // What it says there, the last run's only, for when answers don't come.
            let log = room.appendingPathComponent("stderr.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            process.standardError = (try? FileHandle(forWritingTo: log)) ?? FileHandle.nullDevice
            process.standardInput = into
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                DispatchQueue.main.async { self?.heard(data) }
            }
            process.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async {
                    // Only the process in use: one stopped earlier has
                    // nothing of the line waiting on it now.
                    guard let self, self.process === ended else { return }
                    self.said = "ended"
                    let left = self.waiting
                    self.waiting = []
                    self.process = nil
                    self.input = nil
                    left.forEach { $0.done?(nil) }
                }
            }
            self.buffer = Data()
            self.answered = 0
            do {
                guard try permit.start(process) else { return ready(false) }
                self.permission = permit
            } catch {
                self.said = "couldn't start \(claude): \(error.localizedDescription)"
                return ready(false)
            }
            self.said = "started \(claude)"
            self.process = process
            self.input = into.fileHandleForWriting
            ready(true)
        }
    }

    private func send(_ text: String) {
        guard permission?.valid == true else { stop(); return }
        ConsentAudit.record("provider.helper-message")
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard var line = try? JSONSerialization.data(withJSONObject: message), let input else { return }
        line.append(0x0A)
        try? input.write(contentsOf: line)
    }

    private func heard(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  event["type"] as? String == "result" else { continue }
            answered += 1
            guard !waiting.isEmpty else { continue }
            waiting.removeFirst().done?(event["result"] as? String ?? "")
        }
        // Enough turns and nothing in line: a fresh one, warm at once.
        if let turns, answered >= turns, waiting.isEmpty {
            stop()
            warm()
        }
    }

    func stop() {
        stopping?.cancel()
        try? input?.close()
        if let process { Shell.end(process, grace: 2) }
        process = nil
        input = nil
        let left = waiting
        waiting = []
        left.forEach { $0.done?(nil) }
    }
}
