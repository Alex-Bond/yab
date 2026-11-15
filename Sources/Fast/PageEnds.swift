import Foundation

// Why a page's process ended, and which endings make a page that keeps
// crashing.
//
// WebKit tells the browser a page's process went with a public callback
// that says nothing more, and a private one that says why: too much
// memory, too much CPU, asked for, or a crash (Dialogs.swift). The word
// goes into the feedback diagnostics, and a page that keeps ending says
// which: running out of memory is not the same trouble as crashing.

/// Why WebKit ended a page's process: its private _WKProcessTerminationReason,
/// told to `_webView:webContentProcessDidTerminateWithReason:`.
enum PageEnd: Int, Codable, Sendable {
    case memory = 0
    case cpu = 1
    /// Asked for: the browser's own, or WebKit's when it swaps a process.
    case requested = 2
    case crash = 3
    /// Too many crashes of a process several sites share.
    case crashLimit = 4

    /// The word kept in the feedback diagnostics, never anything else.
    var word: String {
        switch self {
        case .memory: "memory"
        case .cpu: "cpu"
        case .requested: "requested"
        case .crash: "crash"
        case .crashLimit: "crash-limit"
        }
    }

    /// What the page says when it keeps ending this way.
    var again: String {
        switch self {
        case .memory: "This page keeps running out of memory"
        default: "This page keeps crashing"
        }
    }
}

/// Pages ending, gathered for a tenth of a second. Tabs whose pages end
/// together went for something they share, WebKit's GPU or network
/// process, or memory running out for all of them, and none of them is a
/// page that keeps crashing. One page alone, three times in a minute, is.
@MainActor
final class PageEnds {
    struct Ended {
        weak var tab: Tab?
        let id: UUID
        let reason: PageEnd?
    }

    static let together: TimeInterval = 0.1
    static let window: TimeInterval = 60
    static let limit = 3

    private var pending: [Ended] = []
    /// Ends heard and not yet settled (their tenth of a second not over).
    var gathering: Bool { !pending.isEmpty }
    private var crashes: [UUID: [TimeInterval]] = [:]
    private let clock: () -> TimeInterval
    private let later: (TimeInterval, @escaping () -> Void) -> Void

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         later: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
         }) {
        self.clock = clock
        self.later = later
    }

    /// Hears, once the moment is over, every page that ended in it, each
    /// with whether it now keeps ending: three times in a minute, alone
    /// each time.
    var heard: (([(end: Ended, again: Bool)]) -> Void)?

    /// A page's process ended.
    func ended(_ tab: Tab, reason: PageEnd?) {
        ended(Ended(tab: tab, id: tab.id, reason: reason))
    }

    func ended(_ end: Ended) {
        let first = pending.isEmpty
        pending.append(end)
        guard first else { return }
        later(Self.together) { [weak self] in
            guard let self else { return }
            let batch = pending
            pending = []
            heard?(settle(batch))
        }
    }

    /// Which of the pages that ended together keep ending. Asked for is
    /// never counted, nor anything that ended in company.
    func settle(_ batch: [Ended]) -> [(end: Ended, again: Bool)] {
        let now = clock()
        let alone = Set(batch.map(\.id)).count == 1
        return batch.map { end in
            guard alone, end.reason != .requested else { return (end: end, again: false) }
            let recent = (crashes[end.id] ?? []).filter { now - $0 < Self.window } + [now]
            crashes[end.id] = recent
            return (end: end, again: recent.count >= Self.limit)
        }
    }
}
