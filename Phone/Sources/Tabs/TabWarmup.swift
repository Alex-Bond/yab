import SwiftUI
import UIKit

/// All Tabs' warm-up, so no card stays a stand-in: cards with no picture at
/// all (tabs from the Mac never loaded on this iPhone, ones let go before
/// they were pictured) load quietly, one or two at a time, out of sight
/// under the cards (TabWarmupStage), are pictured and let go, and their
/// cards cross-fade from the icon to the page. It runs only while All Tabs
/// is up, and starts no page while a finger moves the cards; closing All
/// Tabs stops it and lets its pages go at once (TabStack).
@MainActor
final class TabWarmup {
    /// What warming one tab came to.
    enum Outcome: Equatable {
        case pictured
        /// Nothing to picture: a failed page, a blank, or it was stopped.
        case failed
        /// The pool had no room for another page now (WebPool.borrow): the
        /// tab waits for one that is warming to end.
        case noRoom
    }

    /// Pages loading at once, at most (the pool's limit may allow fewer).
    let width: Int
    /// A page loaded out of sight gets this long to say it drew; a slower
    /// one is pictured as far as it got.
    static let paintTimeout: Duration = .seconds(8)
    /// While a finger is on the cards, the next page waits this long and asks again.
    static let pause: Duration = .milliseconds(250)

    /// May the next page start loading now (no finger on the cards)?
    var mayStart: () -> Bool = { true }
    private let warm: (Tab) async -> Outcome
    private let letGo: (Tab.ID, Bool) -> Void

    private(set) var isOn = false
    private var waiting: [Tab] = []
    private var running: [Tab.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Tried since All Tabs opened: each tab once.
    private var tried: Set<Tab.ID> = []
    private var again: Task<Void, Never>?
    /// The most pages that warmed at once, and every tab started (tests, measures).
    private(set) var mostAtOnce = 0
    private(set) var started: [Tab.ID] = []

    /// `warm` loads, pictures and lets go of one tab; `letGo` lets go of a
    /// tab's page at once when the warm-up stops before it is done (or keeps
    /// it alive, the card tapped).
    init(width: Int = 2, warm: @escaping (Tab) async -> Outcome, letGo: @escaping (Tab.ID, Bool) -> Void) {
        self.width = max(1, width)
        self.warm = warm
        self.letGo = letGo
    }

    var runningCount: Int { running.count }
    var waitingIDs: [Tab.ID] { waiting.map(\.id) }

    /// The cards that need a picture, the most needed first (nearest the
    /// focus): what isn't warming or tried yet waits, in this order.
    func start(_ tabs: [Tab]) {
        isOn = true
        waiting = tabs.filter { running[$0.id] == nil && !tried.contains($0.id) }
        pump()
    }

    /// All Tabs closed: nothing more starts, and every page still warming
    /// is let go now (its card's picture isn't needed any more), but the
    /// one `keeping`, the card tapped, whose page comes in front.
    func stop(keeping: Tab.ID? = nil) {
        isOn = false
        waiting = []
        again?.cancel()
        again = nil
        let going = running
        running = [:]
        tried = []
        for (id, run) in going {
            run.task.cancel()
            letGo(id, id == keeping)
        }
    }

    private func pump() {
        guard isOn else { return }
        while running.count < width, let tab = waiting.first {
            guard mayStart() else { later(); return }
            waiting.removeFirst()
            tried.insert(tab.id)
            started.append(tab.id)
            let token = UUID()
            let task = Task { @MainActor [weak self, warm] in
                let outcome = await warm(tab)
                self?.ended(tab, token: token, outcome)
            }
            running[tab.id] = (token, task)
            mostAtOnce = max(mostAtOnce, running.count)
        }
    }

    private func later() {
        guard again == nil else { return }
        again = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled, let self else { return }
            self.again = nil
            self.pump()
        }
    }

    private func ended(_ tab: Tab, token: UUID, _ outcome: Outcome) {
        guard running[tab.id]?.token == token else { return }
        running[tab.id] = nil
        guard isOn else { return }
        if outcome == .noRoom {
            // Tried again once another page has gone; with none warming, no room comes.
            tried.remove(tab.id)
            guard !running.isEmpty else { return }
            waiting.insert(tab, at: 0)
            return
        }
        pump()
    }
}

/// Where the warm-up's pages load: a view at the very back of All Tabs,
/// under its opaque ground, so WebKit draws them (a page on no window
/// neither draws nor can be pictured) while nobody sees them. Hidden from
/// VoiceOver and touches; gone with All Tabs.
final class TabWarmupStage: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// A page laid out as it would be in front: the whole screen.
    func show(_ view: UIView) {
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }

    /// Lets a page go, if it is still here (a card tapped took it in front).
    func remove(_ view: UIView?) {
        guard let view, view.superview === self else { return }
        view.removeFromSuperview()
    }
}

/// The stage in All Tabs, its view handed to the tab stack.
struct TabWarmupStageView: UIViewRepresentable {
    let stack: TabStack

    func makeUIView(context: Context) -> TabWarmupStage {
        let stage = TabWarmupStage()
        stack.stage = stage
        return stage
    }

    func updateUIView(_ stage: TabWarmupStage, context: Context) {
        if stack.stage !== stage { stack.stage = stage }
    }

    static func dismantleUIView(_ stage: TabWarmupStage, coordinator: ()) {
        for view in stage.subviews { view.removeFromSuperview() }
    }
}
