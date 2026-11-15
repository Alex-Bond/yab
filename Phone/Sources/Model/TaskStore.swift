import Foundation
import Observation

/// Tasks the Mac does for this iPhone: what each is, how far it got, and
/// what the Now line says about them. Until sync (M7) the runs come from the
/// world and the named states; the virtual Mac moves them later.
@MainActor
@Observable
final class TaskStore {
    private(set) var definitions: [TaskDefinition.ID: TaskDefinition]
    private(set) var runs: [TaskRun]
    /// The tab in front on the Mac, offered on the Now line for a minute after it.
    var handoff: Tab?
    /// A page a Mac sent this iPhone (Send to iPhone), waiting in Today:
    /// its card on the Now line, "From <Mac>: <title>" with Open.
    var arrived: ArrivedPage?
    /// Actual authored requests and checked observations, apart from demo runs.
    private(set) var live: [LiveTaskSnapshot] = []
    private(set) var liveAccount: String?
    private var liveSeenStore: LiveTaskSeenStore?
    @ObservationIgnored private var liveFingerprints: [String: (snapshot: LiveTaskSnapshot, value: LiveTaskSeenStore.Fingerprint)] = [:]
    #if DEBUG
    private(set) var liveResultFingerprintComputations = 0
    #endif
    private var liveSeenRevision = 0
    private(set) var liveSeenPersistenceFailed = false

    func replaceLive(account: String?, snapshots: [LiveTaskSnapshot], seenScope: LiveTaskSeenStore.Scope? = nil) {
        if liveAccount != account || liveSeenStore?.scope != seenScope {
            liveSeenStore = seenScope.map { LiveTaskSeenStore(scope: $0) }
            liveSeenPersistenceFailed = liveSeenStore?.readable == false
            liveFingerprints = [:]
        }
        liveAccount = account
        var retained: [String: (snapshot: LiveTaskSnapshot, value: LiveTaskSeenStore.Fingerprint)] = [:]
        for snapshot in snapshots where snapshot.dismissibleNotice {
            if let cached = liveFingerprints[snapshot.id], cached.snapshot.sameRecord(as: snapshot) {
                retained[snapshot.id] = cached
            } else if let value = fingerprint(snapshot) {
                retained[snapshot.id] = (snapshot, value)
            }
        }
        liveFingerprints = retained
        live = snapshots
    }

    @discardableResult
    func markLiveSeen(_ snapshot: LiveTaskSnapshot) -> Bool {
        guard liveAccount == snapshot.request.account,
              snapshot.dismissibleNotice,
              live.first(where: { $0.id == snapshot.id })?.sameRecord(as: snapshot) == true else { return false }
        let value: LiveTaskSeenStore.Fingerprint?
        if let cached = liveFingerprints[snapshot.id], cached.snapshot.sameRecord(as: snapshot) { value = cached.value }
        else {
            value = fingerprint(snapshot)
            if let value { liveFingerprints[snapshot.id] = (snapshot, value) }
        }
        let stored = value.map { liveSeenStore?.mark($0) == true } == true
        liveSeenPersistenceFailed = !stored
        if stored { liveSeenRevision += 1 }
        return stored
    }

    func liveNow(in snapshots: [LiveTaskSnapshot]) -> NowItem? {
        _ = liveSeenRevision
        let unseen = snapshots.filter { snapshot in
            guard snapshot.observation?.status != .stopped else { return false }
            guard snapshot.dismissibleNotice,
                  let cached = liveFingerprints[snapshot.id], cached.snapshot.sameRecord(as: snapshot) else { return true }
            return liveSeenStore?.contains(cached.value) != true
        }
        let top = unseen.sorted {
            if $0.nowPriority != $1.nowPriority { return $0.nowPriority < $1.nowPriority }
            return ($0.request.created, $0.id) > ($1.request.created, $1.id)
        }.first
        guard let top else { return nil }
        var item = NowItem.live(top)
        let others = unseen.filter { $0.id != top.id }
        if !others.isEmpty { item.more = others.allSatisfy { $0.observation?.status == .done }
            ? "+\(others.count) done" : "+\(others.count)" }
        return item
    }

    private func fingerprint(_ snapshot: LiveTaskSnapshot) -> LiveTaskSeenStore.Fingerprint? {
        guard let liveSeenStore else { return nil }
        #if DEBUG
        liveResultFingerprintComputations += 1
        #endif
        return liveSeenStore.fingerprint(snapshot)
    }

    init(world: World) {
        definitions = Dictionary(world.taskDefinitions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        runs = world.tasks
        handoff = nil
    }

    func definition(_ id: TaskRun.ID) -> TaskDefinition? { definitions[id] }
    func run(_ id: TaskRun.ID) -> TaskRun? { runs.first { $0.id == id } }

    /// Sends a task to the Mac; already running, it stays as it is.
    @discardableResult
    func start(_ id: TaskDefinition.ID, macAsleep: Bool = false) -> TaskRun? {
        guard definitions[id] != nil else { return nil }
        if let run = run(id) { return run }
        let run = TaskRun(id: id, status: macAsleep ? .waits : .sending)
        runs.append(run)
        handoff = nil
        return run
    }

    /// Where a task is now: its state and its step.
    func set(_ id: TaskRun.ID, status: TaskStatus, step: Int? = nil) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].status = status
        if let step { runs[i].step = step }
    }

    /// Any other change to a run (what the Mac said about it: a code given,
    /// a yes given, what stopped it), in one place.
    func update(_ id: TaskRun.ID, _ change: (inout TaskRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[i])
    }

    /// Its result opened: Done stops being said.
    func markSeen(_ id: TaskRun.ID) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].seen = true
    }

    func remove(_ id: TaskRun.ID) { runs.removeAll { $0.id == id } }
    func removeAll() { runs.removeAll() }

    // MARK: - the Now line

    /// The task the Now line speaks for, in the prototype's order: needs a yes,
    /// needs a code, stopped, paying, running (the latest), waits for the Mac,
    /// done and not opened (the latest).
    var top: TaskRun? {
        func first(_ status: TaskStatus) -> TaskRun? { runs.first { $0.status == status } }
        return first(.yes) ?? first(.code) ?? first(.failed) ?? first(.paying)
            ?? runs.filter(\.isLive).last
            ?? first(.waits)
            ?? runs.filter { $0.status == .done && !$0.seen }.last
    }

    /// The rest, said as a number: "+1", or "+2 done" when all of them are.
    func more(than top: TaskRun?) -> String? {
        let others = runs.filter { $0.id != top?.id && !($0.status == .done && $0.seen) && $0.status != .stopped }
        guard !others.isEmpty else { return nil }
        return others.allSatisfy { $0.status == .done } ? "+\(others.count) done" : "+\(others.count)"
    }
}

/// What the Now line says, put together: a task first, then something put
/// away (an answer or a chat), then the Mac's tab. Nothing: no line.
enum NowLine {
    @MainActor
    static func item(tasks: TaskStore, parked: NowItem?) -> NowItem? {
        if let run = tasks.top, let def = tasks.definition(run.id) {
            var item = NowItem.task(run, def)
            item.more = tasks.more(than: run)
            return item
        }
        if let parked { return parked }
        if let page = tasks.arrived { return NowItem.arrived(page) }
        if let tab = tasks.handoff { return NowItem.handoff(tab) }
        return nil
    }
}
