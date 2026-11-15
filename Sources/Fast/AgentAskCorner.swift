import AppKit
import Combine
import AudioToolbox
import AVFoundation
import SwiftUI

// Where an agent's question finds you (docs/chat-asks.md, "Finding you").
//
// Every question has a home, the place it can be read whole and answered:
// the chat's field, the foot of the agent's tab, the pay sheet, the Mac's
// window. Seen there, nothing else says it. With Yab in front and the home
// out of sight, the page's top right corner holds it until it is answered:
// the card itself for what can be answered away from home (a chat's mail
// question, a send asked of a tab that isn't the agent's), "needs you" with
// Show for a page you have to go to. With Yab behind, the Mac says it, the
// Dock's icon bouncing until you come. Away from the Mac, the iPhone.

// MARK: - where you are

/// At the Mac or away from it: the screen locked or asleep, or nothing
/// typed or moved for two minutes. Away is when a question goes to the
/// iPhone too; back, it comes off it.
@MainActor
final class AskPresence: ObservableObject {
    static let shared = AskPresence()
    /// Untouched this long is away.
    static let idle: TimeInterval = 120

    @Published private(set) var away = false
    private var locked = false
    private var asleep = false
    private var timer: Timer?
    private var watching: [NSObjectProtocol] = []
    /// What a test world says instead of the Mac.
    var testAway: Bool? { didSet { look() } }

    private init() {}

    /// Watched while a question waits, not all day.
    func watch(_ on: Bool) {
        if on, timer == nil {
            let center = DistributedNotificationCenter.default()
            let workspace = NSWorkspace.shared.notificationCenter
            watching = [
                center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.locked = true; self?.look() }
                },
                center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.locked = false; self?.look() }
                },
                workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.asleep = true; self?.look() }
                },
                workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.asleep = false; self?.look() }
                },
            ]
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
            look()
        } else if !on, let timer, !AgentNotices.shared.waiting, !AssistantApprovals.shared.holdsAtMac {
            timer.invalidate()
            self.timer = nil
            for token in watching {
                DistributedNotificationCenter.default().removeObserver(token)
                NSWorkspace.shared.notificationCenter.removeObserver(token)
            }
            watching = []
            if away { away = false }
        }
    }

    /// Seconds since a key, a click or a move, anywhere on the Mac.
    static var untouched: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func look() {
        let now = testAway ?? (locked || asleep || Self.untouched > Self.idle)
        guard now != away else { return }
        away = now
        AssistantApprovals.shared.presence(away: now)
    }
}

// MARK: - its sound

/// A question's own sound: two soft notes, the second a fourth up, the way
/// a question rises. Made once into ~/Library/Sounds, where the Mac's
/// notifications find it by name, and played from the same file in Yab.
@MainActor
enum AskSound {
    static let name = "Yab Question.aiff"
    private static var sound: SystemSoundID = 0
    private static var played: Set<String> = []

    /// Settings › Agents › Sound for questions.
    static var on: Bool { Agents.shared.browser?.prefs.agentsAskSound ?? true }

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds/\(name)")
    }

    /// The file, written if it isn't there yet. False when it can't be.
    @discardableResult
    static func ready() -> Bool {
        if FileManager.default.fileExists(atPath: file.path) { return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(to: file)
            return true
        } catch {
            return false
        }
    }

    /// The notes: E6 then A6, each a sine with a little of its octave,
    /// struck and let ring down.
    static func samples(rate: Double = 44_100) -> [Float] {
        let notes: [(start: Double, hz: Double, length: Double, gain: Double)] = [
            (0, 1318.5, 0.16, 0.30),
            (0.11, 1760.0, 0.42, 0.34),
        ]
        let total = Int((0.11 + 0.42) * rate)
        var out = [Float](repeating: 0, count: total)
        for note in notes {
            let begin = Int(note.start * rate)
            let count = Int(note.length * rate)
            for i in 0..<count where begin + i < total {
                let t = Double(i) / rate
                let attack = min(1, t / 0.006)
                let decay = exp(-t * 7.5)
                let wave = sin(2 * .pi * note.hz * t) + 0.18 * sin(4 * .pi * note.hz * t)
                out[begin + i] += Float(note.gain * attack * decay * wave)
            }
        }
        return out
    }

    static func write(to url: URL) throws {
        let rate = 44_100.0
        let data = samples(rate: rate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(data.count)
        data.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: data.count) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private static var lastPlayed = Date.distantPast
    /// Questions that come together get one sound, not one each.
    private static let together: TimeInterval = 5

    /// Once a question, in Yab, while it is in front: no sound while you
    /// are in a call.
    static func play(for id: String) {
        guard on, played.insert(id).inserted, !Store.testing, Agents.shared.browser?.call == nil else { return }
        guard Date().timeIntervalSince(lastPlayed) > together else { return }
        guard ready() else { return }
        lastPlayed = Date()
        if sound == 0 { AudioServicesCreateSystemSoundID(file as CFURL, &sound) }
        if sound != 0 { AudioServicesPlayAlertSound(sound) }
    }

    /// Whether this question has had its sound, from Yab or on a banner.
    static func heard(_ id: String) -> Bool { played.contains(id) }

    /// A banner carrying the sound: Yab doesn't play it as well.
    static func said(_ id: String) { played.insert(id) }

    static func forget(_ id: String) { played.remove(id) }
}

// MARK: - what the corner holds

extension Agents {
    /// A question waiting with no place on screen to answer it.
    enum Cornered: Hashable {
        /// A chat's question (mail) while its column isn't out with it.
        case chat(String)
        /// A send or a chat's question asked on a tab of yours that isn't
        /// the agent's: never at the foot of someone else's page.
        case tab(Tab.ID)
    }

    /// A tab's question that stands in the corner, not at its page's foot:
    /// one that is answered away from the page (a send, a mail question)
    /// on a tab the agent doesn't work in.
    ///
    /// Since the card (AgentAskCard), the agent's own tab's questions stand
    /// there too while that tab is in front, the working dock at its foot
    /// stepping aside meanwhile: every question in one place. Off the tab in front, a page's
    /// question waits for you there ("needs you", Show), since it is about
    /// that page.
    static func inCorner(_ tab: Tab) -> Bool {
        guard tab.handoff != nil, let permit = tab.permit, !permit.isPayment, Payments.shared.flow(tab) == nil else { return false }
        if inFront(tab) { return true }
        guard permit.place == .send || permit.place == .chat else { return false }
        return tab.agent != permit.session && tab.guest != permit.session
    }

    /// The tab in front of its window.
    static func inFront(_ tab: Tab) -> Bool { front(of: tab)?.activeID == tab.id }

    /// A question to pick from (the ask tool's choices) on the tab in
    /// front: the card with its choices, in the same place.
    static func choosingInCorner(_ tab: Tab) -> Bool {
        tab.permit == nil && !tab.choices.isEmpty && tab.handoff != nil && inFront(tab)
    }

    /// A send said yes to in the corner, while it goes or after it failed:
    /// its card stays there, saying so, until it has gone.
    static func sendingInCorner(_ tab: Tab) -> Bool {
        guard tab.permit == nil, let sending = tab.sending, !sending.permit.isPayment else { return false }
        if inFront(tab) { return true }
        guard sending.permit.place == .send || sending.permit.place == .chat else { return false }
        return tab.agent != sending.permit.session && tab.guest != sending.permit.session
    }

    /// What the corner of this window holds now, the oldest first: a
    /// chat's question, then a send on a tab of yours. A send whose card
    /// has folded into its Undo toast is the toast's now.
    func cornered(in browser: Browser) -> Cornered? { corneredAll(in: browser).first }

    /// Whether a chat's question is read in the column: Yab's own chats.
    /// Another app's agent (`yab mcp`) and work out of sight have no chat
    /// there, so their question stands in the corner (Agents.showAsk).
    func columnHolds(_ chat: String) -> Bool {
        guard let root = session(root(of: chat)) else { return false }
        return root.agent != .external && !root.quiet && !root.sealed
    }

    /// Every question the corner holds, the oldest first: the one in front
    /// is answered, the rest wait under it.
    func corneredAll(in browser: Browser) -> [Cornered] {
        var held: [Cornered] = []
        for session in sessions where session.permit != nil && root(of: session.id) == session.id {
            // Its home in sight: the column out with this chat, which is
            // only drawn beside a page.
            if browser.chatOpen && browser.chatShown == session.id && browser.active != nil { continue }
            held.append(.chat(session.id))
        }
        let folded = Set(AskStand.shared.toasts.map(\.id))
        for tab in browser.everyTab where (Self.inCorner(tab) || Self.sendingInCorner(tab) || Self.choosingInCorner(tab)) && !AgentDock.askedInColumn(tab) {
            if let key = (tab.permit ?? tab.sending?.permit)?.key, folded.contains(key) { continue }
            held.append(.tab(tab.id))
        }
        return held
    }

    /// The id the notification queue holds this question under, so the
    /// queue and the card coming up are one question to AskSound.
    func noticeID(_ held: Cornered, in browser: Browser) -> String {
        switch held {
        case .chat(let id): return "agent.permit.\(id)"
        case .tab(let id): return browser.everyTab.first { $0.id == id }?.handoffNotice?.id ?? "\(held)"
        }
    }

    /// Return or Escape for the corner's question, from anywhere in the
    /// window nothing is typed into. False when the corner has none.
    func cornerKeyed(_ event: NSEvent, in browser: Browser) -> Bool {
        guard let held = cornered(in: browser) else { return false }
        switch held {
        case .chat(let id):
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard [36, 76, 53].contains(event.keyCode), flags.isEmpty, let permit = session(id)?.permit else { return false }
            answer(chat: id, yes: event.keyCode != 53, key: permit.key)
            return true
        case .tab(let id):
            guard let tab = browser.everyTab.first(where: { $0.id == id }) else { return false }
            return keyed(tab, event: event)
        }
    }
}


// MARK: - the stand at the page's bottom right

/// What the stand shows besides the questions themselves: a sent mail's
/// Undo toast for Mail's Undo send window, and a card's last words for a
/// moment after it was answered elsewhere or its chat stopped.
@MainActor
final class AskStand: ObservableObject {
    static let shared = AskStand()

    /// A mail on its way: what the card folded into.
    struct Toast: Identifiable, Equatable {
        /// The question's key, so the card and the toast are one thing.
        let id: String
        let permit: AgentPermit
        var person: String
        var title: String
        var subject: String
        var until: Date
        /// The drafts Undo takes back (MailAgent.takeBack), account|id.
        var drafts: [String]
        var done: String?
    }

    /// A card kept a moment after its question went, saying what happened.
    struct Ghost: Identifiable, Equatable {
        let id: String
        let permit: AgentPermit
        let content: AskContent
        let words: String
        let good: Bool
    }

    @Published private(set) var toasts: [Toast] = []
    @Published private(set) var ghosts: [Ghost] = []
    /// The windows whose stand is on screen now, by their browser, for a
    /// test world to ask (ask-stand).
    var drawn: [ObjectIdentifier: Int] = [:]
    /// What each card shows, made once a question (ApprovalDetailBuilder
    /// reads the store).
    private var made: [String: AskContent] = [:]

    func content(_ permit: AgentPermit, tab: Tab?) -> AskContent {
        if let hit = made[permit.key + "\u{1}" + permit.session] { return hit }
        let shaped = AskContent.make(permit, tab: tab)
        made[permit.key + "\u{1}" + permit.session] = shaped
        if made.count > 40 { made.removeAll() }
        return shaped
    }

    /// The card stands a moment longer, its buttons given way to `words`.
    /// Only for a question the stand is showing: one never seen here goes
    /// quietly, as before.
    func said(_ permit: AgentPermit, tab: Tab?, words: String, good: Bool) {
        guard let browser = Agents.shared.browser, Agents.shared.cornered(in: browser).map({ held in
            switch held {
            case .chat(let id): return Agents.shared.session(id)?.permit == permit
            case .tab(let id): return browser.everyTab.first(where: { $0.id == id }).map { ($0.permit ?? $0.sending?.permit) == permit } ?? false
            }
        }) == true else { return }
        let ghost = Ghost(id: permit.key, permit: permit, content: content(permit, tab: tab), words: words, good: good)
        ghosts.removeAll { $0.id == ghost.id }
        ghosts.append(ghost)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            withAnimation(AskMotion.leave) { self?.ghosts.removeAll { $0.id == ghost.id } }
        }
    }

    /// A mail sent by an agent waits Mail's Undo send window: its card
    /// folds into a toast saying so, Undo taking it back.
    func sending(_ permit: AgentPermit, outs: [MailAgent.Outgoing], drafts: [String], hold: TimeInterval) {
        guard hold > 0, !drafts.isEmpty, !Headless.hidden || Store.testing else { return }
        let first = outs.first
        let to = first?.draft.to.first.map { $0.name.isEmpty ? $0.address : $0.name } ?? first?.to ?? ""
        let toast = Toast(id: permit.key, permit: permit,
                          person: to,
                          title: outs.count > 1 ? "Sending \(outs.count) mails" : "Sending to \(to.split(separator: " ").first.map(String.init) ?? to)",
                          subject: outs.count > 1 ? outs.compactMap { $0.draft.to.first?.name }.joined(separator: ", ") : first?.draft.subject ?? "",
                          until: Date().addingTimeInterval(hold), drafts: drafts)
        withAnimation(AskMotion.fold) {
            toasts.removeAll { $0.id == toast.id }
            toasts.append(toast)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            self?.finish(toast.id, words: "Sent")
        }
    }

    /// Undo: every mail of it taken back, as mail_send's undo does.
    func undo(_ id: String) {
        guard let toast = toasts.first(where: { $0.id == id }), toast.done == nil else { return }
        var back = 0
        for draft in toast.drafts where MailAgent.takeBack(MailCenter.shared, ["draft": draft])["error"] == nil { back += 1 }
        finish(id, words: back > 0 ? "Not sent" : "Already sent")
    }

    /// The last toast's Undo, for ⌘Z from anywhere not typed into.
    func undoLast() -> Bool {
        guard let last = toasts.last(where: { $0.done == nil }) else { return false }
        undo(last.id)
        return true
    }

    private func finish(_ id: String, words: String) {
        guard let index = toasts.firstIndex(where: { $0.id == id }), toasts[index].done == nil else { return }
        withAnimation(Motion.quick) { toasts[index].done = words }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            withAnimation(AskMotion.leave) { self?.toasts.removeAll { $0.id == id } }
        }
    }
}

/// The page's bottom right: the question in front with the next ones as
/// its edge under it, "1 of N" in its head, and under the questions the
/// Undo toast of a mail on its way. Each card's buttons stand in the
/// corner and never move while it is up: the card grows upward.
struct AskStandView: View {
    let browser: Browser
    @ObservedObject private var agents = Agents.shared
    @ObservedObject private var stand = AskStand.shared
    /// The column's chat: a tab's question it held comes to the corner
    /// once the column goes (AgentDock.askedInColumn), told on its own.
    @ObservedObject private var columnChat = ColumnChat.shared
    @Namespace private var fold
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let _ = (seen, columnChat.id)
        let held = agents.corneredAll(in: browser)
        let ghost = stand.ghosts.last
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(items(held: held, ghost: ghost)) { item in
                card(item, count: held.count > 1 ? "1 of \(held.count)" : nil)
                .background(alignment: .top) {
                    if item.held != nil, held.count > 1 {
                        Color.clear.agentCardFrame()
                            .brightness(-0.16)
                            .scaleEffect(0.95, anchor: .top)
                            .offset(y: -10)
                            .transition(.opacity)
                    }
                }
                .transition(arriving)
            }
        }
        .animation(still ? Motion.quick : AskMotion.arrive, value: held)
        .animation(still ? Motion.quick : AskMotion.arrive, value: held.first.map(cardID))
        .animation(still ? Motion.quick : AskMotion.fold, value: stand.toasts)
        .animation(still ? Motion.quick : AskMotion.leave, value: stand.ghosts)
        .onChange(of: held.first) { _, front in
            // Behind other apps the Mac's banner carries it (AgentNotices.say).
            if let front, NSApp.isActive { AskSound.play(for: agents.noticeID(front, in: browser)) }
        }
        .onAppear { stand.drawn[ObjectIdentifier(browser), default: 0] += 1 }
        .onDisappear { stand.drawn[ObjectIdentifier(browser), default: 1] -= 1 }
        // A tab's question lives on the tab, which SwiftUI doesn't watch:
        // its four fields say when one comes, runs or goes.
        .onReceive(asked) { _ in seen &+= 1 }
    }

    @State private var seen = 0

    /// Any tab's question changing: asked, its words, its choices, a yes
    /// running (Tab.relay), and nothing else a page does.
    private var asked: AnyPublisher<Void, Never> {
        Publishers.MergeMany(browser.everyTab.flatMap { tab -> [AnyPublisher<Void, Never>] in
            [tab.relay.publisher(\.permit, of: tab).map { _ in () }.eraseToAnyPublisher(),
             tab.relay.publisher(\.handoff, of: tab).map { _ in () }.eraseToAnyPublisher(),
             tab.relay.publisher(\.choices, of: tab).map { _ in () }.eraseToAnyPublisher(),
             tab.relay.publisher(\.sending, of: tab).map { _ in () }.eraseToAnyPublisher()]
        })
        .dropFirst(browser.everyTab.count * 4)
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
    }

    private var arriving: AnyTransition {
        still ? .opacity : .asymmetric(
            insertion: .modifier(active: AskCardArrival(part: 0), identity: AskCardArrival(part: 1)).animation(AskMotion.arrive),
            removal: .modifier(active: AskCardDeparture(part: 1), identity: AskCardDeparture(part: 0)).animation(AskMotion.leave))
    }

    private var leaving: AnyTransition {
        still ? .opacity : .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(y: 12)))
    }

    @ViewBuilder private func card(_ item: Item, count: String?) -> some View {
        // One AgentAskCard for the whole life of a permit. Changing to a
        // toast changes its inputs, never its view identity or its footer.
        if let permit = item.permit {
            AgentAskCard(content: item.ghost?.content ?? stand.content(permit, tab: item.tab), permit: permit,
                phase: item.ghost.map { .said($0.words, good: $0.good) } ?? item.phase,
                count: count, keysReach: keysReach, actions: actions(item), fold: fold, toast: item.toast)
        } else if let tab = item.tab {
            ChoiceAskCard(tab: tab, count: count, keysReach: keysReach)
        }
    }

    private func actions(_ item: Item) -> AskActions {
        guard let permit = item.permit, let held = item.held else { return AskActions(no: {}, yes: { _ in }) }
        switch held {
        case .chat(let id):
            return AskActions(no: { agents.answer(chat: id, yes: false, key: permit.key) },
                              yes: { _ in agents.answer(chat: id, yes: true, key: permit.key) })
        case .tab:
            guard let tab = item.tab else { return AskActions(no: {}, yes: { _ in }) }
            return AskActions(
                no: { if tab.sending?.failure != nil { agents.dropSending(tab) } else { agents.answer(tab, yes: false) } },
                yes: { user in if tab.sending?.failure != nil { agents.sendAgain(tab) } else { agents.answer(tab, yes: true, as: user) } },
                always: { agents.always(tab) }, never: { agents.never(tab) },
                stop: { if let session = agents.session(permit.session) { _ = agents.stop(session.id) } })
        }
    }

    private struct Item: Identifiable {
        let id: String
        var held: Agents.Cornered?
        var ghost: AskStand.Ghost?
        var toast: AskStand.Toast?
        var permit: AgentPermit?
        var tab: Tab?
        var phase: AskPhase = .ready
    }

    private func identity(_ permit: AgentPermit) -> String { permit.session + "\u{1}" + permit.key }

    private func items(held: [Agents.Cornered], ghost: AskStand.Ghost?) -> [Item] {
        var shown: [Item] = []
        if let ghost, !stand.toasts.contains(where: { identity($0.permit) == identity(ghost.permit) }) {
            shown.append(Item(id: identity(ghost.permit), ghost: ghost, permit: ghost.permit))
        } else if let front = held.first {
            switch front {
            case .chat(let id):
                shown.append(Item(id: cardID(front), held: front, permit: agents.session(id)?.permit))
            case .tab(let id):
                if let tab = browser.everyTab.first(where: { $0.id == id }) {
                    let phase: AskPhase = tab.permit != nil ? .ready
                        : tab.sending.map { $0.failure.map { AskPhase.failed($0) } ?? .going(since: $0.at) } ?? .ready
                    shown.append(Item(id: cardID(front), held: front, permit: tab.permit ?? tab.sending?.permit, tab: tab, phase: phase))
                }
            }
        }
        shown += stand.toasts.map { Item(id: identity($0.permit), toast: $0, permit: $0.permit) }
        return shown
    }

    private func cardID(_ held: Agents.Cornered) -> String {
        let permit: AgentPermit?
        switch held {
        case .chat(let id): permit = agents.session(id)?.permit
        case .tab(let id):
            let tab = browser.everyTab.first { $0.id == id }
            permit = tab?.permit ?? tab?.sending?.permit
        }
        return permit.map(identity) ?? "choices.\(held)"
    }

    private var keysReach: Bool {
        browser.active?.typing != true && !browser.fieldShowing && !browser.finding && browser.editingTab == nil && !browser.welcoming
    }
}

private struct AskCardArrival: ViewModifier, Animatable {
    var part: Double
    var animatableData: Double { get { part } set { part = newValue } }
    func body(content: Content) -> some View {
        content.opacity(min(1, max(0, part) * 1.6))
            .blur(radius: 6 * max(0, 1 - part))
            .scaleEffect(0.97 + 0.03 * part, anchor: .bottomTrailing)
            .offset(y: 16 * (1 - part))
    }
}

private struct AskCardDeparture: ViewModifier, Animatable {
    var part: Double
    var animatableData: Double { get { part } set { part = newValue } }
    func body(content: Content) -> some View {
        content.opacity(max(0, 1 - part)).blur(radius: 3 * max(0, part)).offset(y: 12 * part)
    }
}

/// A chat's own question (its mail) as the card: answered for the chat.
struct ChatAskCard: View {
    let chat: String
    var count: String?
    var width: CGFloat = AgentAskCard.width
    var keysReach = true
    @ObservedObject private var agents = Agents.shared

    var body: some View {
        if let root = agents.session(chat), let permit = root.permit {
            AgentAskCard(content: AskStand.shared.content(permit, tab: nil), permit: permit, count: count, width: width, keysReach: keysReach,
                    actions: AskActions(no: { agents.answer(chat: chat, yes: false, key: permit.key) },
                                        yes: { _ in agents.answer(chat: chat, yes: true, key: permit.key) }))
        }
    }
}

/// A question asked on a tab as the card, through its yes: the ring and
/// Sending while what it sends goes, the reason in red if it didn't.
struct TabAskCard: View {
    @ObservedObject var tab: Tab
    var count: String?
    var width: CGFloat = AgentAskCard.width
    var keysReach = true
    var fold: Namespace.ID?
    @ObservedObject private var agents = Agents.shared

    var body: some View {
        if let permit = tab.permit ?? tab.sending?.permit {
            let phase: AskPhase = tab.permit != nil ? .ready
                : tab.sending.map { $0.failure.map { AskPhase.failed($0) } ?? .going(since: $0.at) } ?? .ready
            AgentAskCard(content: AskStand.shared.content(permit, tab: tab), permit: permit, phase: phase, count: count, width: width, keysReach: keysReach,
                    actions: AskActions(
                        no: { if tab.sending?.failure != nil { agents.dropSending(tab) } else { agents.answer(tab, yes: false) } },
                        yes: { user in if tab.sending?.failure != nil { agents.sendAgain(tab) } else { agents.answer(tab, yes: true, as: user) } },
                        always: { agents.always(tab) },
                        never: { agents.never(tab) },
                        stop: { if let session = agents.session(permit.session) { _ = agents.stop(session.id) } }),
                    fold: fold)
        }
    }
}

/// A question to pick from (the ask tool): the card's head, the question,
/// its choices by number, Something else in your own words, and Skip or
/// Stop. The digits pick from the page as they did at its foot.
struct ChoiceAskCard: View {
    @ObservedObject var tab: Tab
    var count: String?
    var width: CGFloat = AgentAskCard.width
    var keysReach = true
    var surface = true
    @ObservedObject private var agents = Agents.shared
    @State private var writing = false
    @State private var other = ""
    @FocusState private var typing: Bool

    private var session: Agents.Session? { agents.session(tab.askedBy) }

    private var who: String {
        guard let asker = session else { return "" }
        let root = agents.session(agents.root(of: asker.id)) ?? asker
        let chat = root.title ?? root.name
        return [root.planName, chat == root.planName ? "" : chat].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        let host = ChatComposer.host(tab)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AskMark(mark: .site(host))
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.isEmpty ? "This page" : host)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(who)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let count {
                    Text(count)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text([tab.handoff, tab.handoffDetail].compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(tab.choices.enumerated()), id: \.offset) { index, choice in
                        Button { agents.choose(tab, choice) } label: {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                    .frame(width: 18, height: 18)
                                    .background(Palette.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                                Text(choice)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(AskRowPress())
                    }
                    if writing {
                        TextField("Something else", text: $other)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                            .padding(.horizontal, 8)
                            .frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.faint, lineWidth: 1))
                            .focused($typing)
                            .onSubmit {
                                let said = other.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !said.isEmpty { agents.choose(tab, said) }
                            }
                            .onAppear { typing = true }
                    } else {
                        Button { writing = true } label: {
                            HStack(spacing: 8) {
                                Text("\(tab.choices.count + 1)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 18, height: 18)
                                Text("Something else\u{2026}")
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Palette.muted)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(AskRowPress())
                    }
                }
                .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .padding(.top, 10)
            HStack(spacing: 6) {
                Text("Pick with 1\u{2013}\(tab.choices.count)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                if Agents.optional.contains(tab.id) {
                    Button { agents.skip(tab) } label: { labeled("Skip", key: "esc") }
                        .buttonStyle(.yab(.secondary, .regular))
                } else if let session, session.agent != .external {
                    Button("Stop") { _ = agents.stop(session.id) }
                        .buttonStyle(.yab(.secondary, .regular))
                }
            }
            .padding(.top, 12)
        }
        .frame(width: width - 2 * CardFrame.inset, alignment: .leading)
        .agentCardFrame(surface: surface)
        .animation(AskMotion.height, value: writing)
        .onChange(of: tab.handoff) { _, _ in writing = false; other = "" }
    }

    private func labeled(_ title: String, key: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if keysReach {
                KeyGlyphs(keys: key, size: ButtonSize.regular.wordSize, tint: nil, rest: 0.6)
                    .transaction { $0.animation = nil }
            }
        }
    }
}
