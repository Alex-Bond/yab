import Foundation

/// Who says a page may be replaced by the other engine. In production that is
/// the page's own leave question and, for typed text, the person
/// (EngineSwitchAsking). Reservation stays a seam for the controller's tests.
@MainActor
protocol EngineSwitchAuthority {
    /// Throw only when no owned native reservation remains. If an RPC outcome
    /// is uncertain, return its owner-bound lease so cancellation can reconcile.
    func reserve(_ originals: [EngineSwitchTransaction.Original]) async throws -> any EngineSwitchLease
}

@MainActor
protocol EngineSwitchLease {
    func approveAll() async throws -> Bool
    func seal() async throws
    func validate() async throws -> Bool
    /// Released means ALL exact originals were committed by one authority.
    /// Retained means NONE has run destructive unload or been disposed.
    /// Commit never throws: cancellation, timeout or transport loss after a
    /// possibly irreversible dispatch must return unknown until reconciled.
    /// A canceled caller still consumes the exact terminal native receipt.
    func commit() async -> EngineSwitchCommit
    /// Must consume native owned-release ACK despite caller cancellation.
    /// Retained means no destructive unload and no owned seal/reservation left.
    /// Unknown must never resume a replacement or masquerade as retained.
    func cancel() async -> EngineSwitchCancellation
}

enum EngineSwitchCommit: Equatable, Sendable { case released, retained, unknown }
enum EngineSwitchCancellation: Equatable, Sendable { case retained, unknown }

/// Ephemeral diagnostic only, NOT a durable crash-recovery journal or a native
/// group receipt. The hold keeps exact originals, captures and lease in memory.
struct EngineSwitchRecovery: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case commitUncertain, cancellationUncertain, releasedIdentityChanged }
    let id: UUID
    let phase: Phase
    let tabs: [UUID]
}
enum EngineSwitchTransactionError: Error {
    case overlapping, changed, declined, captureUnavailable
    /// The page has typed text and nobody could be asked about it.
    case typedTextKept
    case atomicCommitRetained
    case recoveryRequired(EngineSwitchRecovery)
}

@MainActor
protocol EngineSwitchTransfer {
    func capture(_ original: EngineSwitchTransaction.Original) async throws -> EngineSwitchDocument
    func synchronize(_ original: EngineSwitchTransaction.Original) async throws
}

@MainActor
private struct EngineSwitchProfileTransfer: EngineSwitchTransfer {
    func capture(_ original: EngineSwitchTransaction.Original) async throws -> EngineSwitchDocument {
        guard let page = original.page, let sourceURL = original.pageURL,
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
              original.change.tab.untrusted == nil, original.change.tab.failure == nil,
              let transfer = try await EngineSwitchDocument.capture(from: page, at: sourceURL) else {
            throw EngineSwitchTransactionError.captureUnavailable
        }
        return transfer
    }
    func synchronize(_ original: EngineSwitchTransaction.Original) async throws {
        let bridge = try ChromiumDRMCookies.of(original.change.tab)
        if let source = original.pageURL { bridge.include(source) }
        if let target = original.change.request?.url { bridge.include(target) }
        try await bridge.synchronizeForSwitching()
    }
}

/// No preference write, capture, cookie bridge or old-page retirement precedes
/// reservation of the complete group. Destination installs form one synchronous
/// main-actor turn after a verified all-originals native commit.
@MainActor
enum EngineSwitchTransaction {
    struct Change {
        let tab: Tab
        let engine: PageEngineKind
        let request: URLRequest?
        /// Exact routing intent must remain current through every native await.
        /// This is a source-owner veto, never native approval to retire a page.
        let isCurrent: @MainActor () -> Bool
        /// Written in the same turn, just before the destination is built: its
        /// first navigation reads the rules, so a new rule or hold must be there.
        let installing: (@MainActor () -> Void)?
        init(tab: Tab, engine: PageEngineKind, request: URLRequest?,
             isCurrent: @escaping @MainActor () -> Bool = { true }, installing: (@MainActor () -> Void)? = nil) {
            self.tab = tab; self.engine = engine; self.request = request
            self.isCurrent = isCurrent; self.installing = installing
        }
    }
    @MainActor final class Original {
        let change: Change
        let page: (any PageHandle)?
        let address: URL?
        let pageURL: URL?
        let profile: String
        let owner: ObjectIdentifier?
        let placement: UUID?
        let navigation: Int
        /// Moved to the page's latest input once it is approved: the question
        /// itself takes time and keys, and only what comes after it counts.
        var input: TimeInterval?
        let engine: PageEngineKind
        let turn: Int
        var transfer: EngineSwitchDocument?
        var changing: Bool { change.request != nil && change.engine != engine }
        init(_ change: Change) {
            self.change = change
            let tab = change.tab
            let existing = tab.builtPage
            page = existing; address = tab.address; pageURL = existing?.url; engine = tab.engineKind
            profile = tab.chromiumProfile
            owner = tab.delegate.map { ObjectIdentifier($0) }
            placement = (tab.delegate as? Browser)?.spaceHolding(tab) ?? (tab.delegate as? Browser)?.spaceID
            navigation = tab.engineNavigationRevision; input = existing?.lastInput
            tab.siteEngineTurn &+= 1; turn = tab.siteEngineTurn
        }
        var current: Bool {
            let tab = change.tab
            return change.isCurrent() && !tab.gone && tab.builtPage === page && page?.url?.documentAddress == pageURL?.documentAddress &&
                tab.address?.documentAddress == address?.documentAddress &&
                tab.chromiumProfile == profile && tab.engineNavigationRevision == navigation &&
                tab.siteEngineTurn == turn && tab.engineKind == engine && tab.delegate.map({ ObjectIdentifier($0) }) == owner &&
                ((tab.delegate as? Browser)?.spaceHolding(tab) ?? (tab.delegate as? Browser)?.spaceID) == placement
        }
        var unchangedInput: Bool { !changing || page?.lastInput == input }
    }
    private static var active: [ObjectIdentifier: UUID] = [:]
    @MainActor private final class RecoveryHold {
        let descriptor: EngineSwitchRecovery
        let originals: [Original]
        let lease: any EngineSwitchLease
        init(_ descriptor: EngineSwitchRecovery, originals: [Original], lease: any EngineSwitchLease) {
            self.descriptor = descriptor; self.originals = originals; self.lease = lease
        }
    }
    private static var recoveries: [UUID: RecoveryHold] = [:]

    /// Observation only. No reset/replay API exists: an uncertain native group
    /// cannot be unlocked by elapsed time, helper reconnection or a new choice.
    static func recovery(for tab: Tab) -> EngineSwitchRecovery? {
        active[ObjectIdentifier(tab)].flatMap { recoveries[$0]?.descriptor }
    }

    private static func quarantine(_ id: UUID, _ phase: EngineSwitchRecovery.Phase,
                                   originals: [Original], lease: any EngineSwitchLease) -> EngineSwitchTransactionError {
        let descriptor = EngineSwitchRecovery(id: id, phase: phase, tabs: originals.map { $0.change.tab.id })
        recoveries[id] = RecoveryHold(descriptor, originals: originals, lease: lease)
        return .recoveryRequired(descriptor)
    }

    static func execute(_ changes: [Change], authority: (any EngineSwitchAuthority)? = nil,
                        transfer: (any EngineSwitchTransfer)? = nil, persist: () -> Void = {}) async throws {
        let id = UUID()
        var seen = Set<ObjectIdentifier>()
        let changes = changes.filter { seen.insert(ObjectIdentifier($0.tab)).inserted }
        // Check the whole group before taking even one reservation.
        guard changes.allSatisfy({ active[ObjectIdentifier($0.tab)] == nil }) else {
            throw EngineSwitchTransactionError.overlapping
        }
        guard changes.allSatisfy({ !$0.tab.gone && $0.tab.engineFactory.kinds.contains($0.engine) &&
            ($0.tab.builtPage == nil || $0.tab.engineProfileMatches) }) else { throw SiteEngineError.profileChanged }
        for change in changes { active[ObjectIdentifier(change.tab)] = id }
        defer {
            // Unknown outcomes retain the whole local group and exact source
            // captures/lease. This memory fence is not persistent crash recovery.
            if recoveries[id] == nil {
                for change in changes where active[ObjectIdentifier(change.tab)] == id { active[ObjectIdentifier(change.tab)] = nil }
            }
        }
        let originals = changes.map(Original.init)
        guard originals.allSatisfy(\.current) else { throw EngineSwitchTransactionError.changed }
        let live = originals.filter { $0.changing && $0.page != nil }
        var lease: (any EngineSwitchLease)?
        var released = false
        do {
            if !live.isEmpty {
                let source = authority ?? EngineSwitchAsking()
                lease = try await source.reserve(live)
                guard let lease, try await lease.approveAll() else { throw EngineSwitchTransactionError.declined }
                guard !Task.isCancelled, originals.allSatisfy(\.current) else { throw EngineSwitchTransactionError.changed }
                for original in live { original.input = original.page?.lastInput }
                try await lease.seal()
                guard !Task.isCancelled, originals.allSatisfy({ $0.current && $0.unchangedInput }) else { throw EngineSwitchTransactionError.changed }
                let transfer = transfer ?? EngineSwitchProfileTransfer()
                for original in live {
                    // A page approved by _tryClose, showing an error or not
                    // answering gives no document: the URL loads afresh.
                    do { original.transfer = try await transfer.capture(original) }
                    catch { DebugLog.note("engine-switch-capture", ["error": String(describing: error)]) }
                    guard !Task.isCancelled, originals.allSatisfy({ $0.current && $0.unchangedInput }) else { throw EngineSwitchTransactionError.changed }
                }
                for original in live {
                    try await transfer.synchronize(original)
                    guard !Task.isCancelled, originals.allSatisfy({ $0.current && $0.unchangedInput }) else { throw EngineSwitchTransactionError.changed }
                }
                guard !Task.isCancelled, try await lease.validate(), originals.allSatisfy({ $0.current && $0.unchangedInput }) else {
                    throw EngineSwitchTransactionError.changed
                }
                switch await lease.commit() {
                case .released: released = true
                case .retained: throw EngineSwitchTransactionError.atomicCommitRetained
                case .unknown: throw quarantine(id, .commitUncertain, originals: originals, lease: lease)
                }
            }
            // A newer selection may cancel this task while the native group is
            // committing. A positive terminal release must still install its
            // destinations before that next selection starts.
            guard released || !Task.isCancelled, originals.allSatisfy({ $0.current && $0.unchangedInput }) else {
                if released, let lease {
                    // Source release is irreversible. A new same-URL handle,
                    // owner, input or intent cannot be canceled or overwritten.
                    throw quarantine(id, .releasedIdentityChanged, originals: originals, lease: lease)
                }
                throw EngineSwitchTransactionError.changed
            }
            // No await or preference observer can see a sequential partial batch.
            for original in originals {
                let change = original.change
                change.installing?()
                if original.changing {
                    change.tab.engineSwitchDocument = original.transfer
                    if let request = change.request { change.tab.applySiteEngineChoice(change.engine, at: request) }
                }
            }
            persist()
        } catch {
            if recoveries[id] == nil, !released, let lease {
                if await lease.cancel() == .unknown {
                    throw quarantine(id, .cancellationUncertain, originals: originals, lease: lease)
                }
            }
            throw error
        }
    }
}

/// What the page and the person said about replacing it.
enum EngineSwitchApproval {
    enum Page: Equatable, Sendable {
        case leave
        case stay
        /// No answer could be had: Chromium's close preflight is missing from
        /// this SDK, or its helper is gone.
        case unavailable
    }
    enum Next: Equatable, Sendable { case go, keep, askPerson }

    /// Stay keeps the page. Typed text the page's own question has not put to
    /// the person goes to the person: a page with no beforeunload handler says
    /// nothing, and a transfer does not carry an editor's text.
    static func next(page: Page, asked: Bool, typed: Bool, agentPage: Bool) -> Next {
        if page == .stay { return .keep }
        return typed && !asked && !agentPage ? .askPerson : .go
    }
}

/// The questions behind the real authority, a seam for its tests.
@MainActor
protocol EngineSwitchQuestions {
    func typed(_ tab: Tab) async -> Bool
    /// The page's verdict, and whether a question went up for it.
    func page(_ tab: Tab) async -> (verdict: EngineSwitchApproval.Page, asked: Bool)
    /// Nil when nobody can be asked.
    func person(_ tab: Tab) async -> Bool?
}

@MainActor
private struct EngineSwitchLiveQuestions: EngineSwitchQuestions {
    func typed(_ tab: Tab) async -> Bool {
        await withCheckedContinuation { done in
            tab.unsaved(within: 1) { [weak tab] typed in done.resume(returning: typed ?? tab?.draft ?? false) }
        }
    }
    func page(_ tab: Tab) async -> (verdict: EngineSwitchApproval.Page, asked: Bool) {
        let before = Leaving.shown
        let verdict = await Leaving.askForSwitch(tab)
        return (verdict, Leaving.shown != before)
    }
    func person(_ tab: Tab) async -> Bool? { await Leaving.askPerson(tab) }
}

/// A person asked for this tab in the other engine: the page's own leave
/// question first, Stay leaving it untouched. Nothing here closes a page, and
/// the old page goes only when the destination replaces it (Tab.replaceEngine).
@MainActor
struct EngineSwitchAsking: EngineSwitchAuthority {
    var questions: any EngineSwitchQuestions = EngineSwitchLiveQuestions()

    func reserve(_ originals: [EngineSwitchTransaction.Original]) async throws -> any EngineSwitchLease {
        Lease(tabs: originals.map(\.change.tab), questions: questions)
    }

    @MainActor private final class Lease: EngineSwitchLease {
        let tabs: [Tab]
        let questions: any EngineSwitchQuestions
        init(tabs: [Tab], questions: any EngineSwitchQuestions) { self.tabs = tabs; self.questions = questions }

        func approveAll() async throws -> Bool {
            for tab in tabs {
                let typed = await questions.typed(tab)
                let said = await questions.page(tab)
                switch EngineSwitchApproval.next(page: said.verdict, asked: said.asked, typed: typed,
                                                 agentPage: AgentPage.answers(tab)) {
                case .go: continue
                case .keep: return false
                case .askPerson:
                    guard let leave = await questions.person(tab) else { throw EngineSwitchTransactionError.typedTextKept }
                    if !leave { return false }
                }
            }
            return true
        }
        func seal() async throws {}
        func validate() async throws -> Bool { true }
        func commit() async -> EngineSwitchCommit { .released }
        func cancel() async -> EngineSwitchCancellation { .retained }
    }
}

/// What the person hears when a switch they asked for did not happen. Stay,
/// and a second press while the question is up, say nothing: the card shows it.
enum EngineSwitchWords {
    static func failure(_ error: any Error, to kind: PageEngineKind) -> String? {
        if error is CancellationError { return nil }
        if let error = error as? EngineSwitchTransactionError {
            switch error {
            case .declined, .overlapping: return nil
            case .typedTextKept: return "Kept this page, it has typed text"
            default: break
            }
        }
        return "Couldn\u{2019}t open this page in \(SiteEngineWords.name(kind))"
    }
}

extension URL {
    /// Where the document is: a page rewriting its own #fragment while a
    /// switch waits (Shaka's demo keeps its settings there) is the same page.
    var documentAddress: URL {
        guard fragment != nil, var parts = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        parts.fragment = nil
        return parts.url ?? self
    }
}

@MainActor
extension Tab {
    func engineSwitchFailed(_ error: any Error, to kind: PageEngineKind) {
        NSLog("Engine switch to %@: %@", kind.rawValue, String(describing: error))
        guard let words = EngineSwitchWords.failure(error, to: kind) else { return }
        (delegate as? Browser)?.announce(words, mark: "exclamationmark.triangle")
    }
}
