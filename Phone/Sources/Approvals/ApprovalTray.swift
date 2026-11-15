import SwiftUI
import UIKit
#if canImport(SyncKit)
import SyncKit
#endif

/// What a payment's yes picks on this iPhone: a card and an address the Mac
/// keeps, or ones typed here, which go up as cards and addresses of the
/// account before the answer names them (AssistantWallet).
struct ApprovalPicks {
    struct NewCard: Equatable { var number: String; var csc: String; var name: String; var month: Int; var year: Int }
    struct NewPlace: Equatable { var name: String; var street: String; var city: String; var postal: String }
    var detail: AssistantApprovalRecords.Detail?
    var card: String?
    var place: String?
    var newCard: NewCard?
    var newPlace: NewPlace?
}

enum ApprovalOutcome: Equatable { case sent, cancelled, failed }

/// The approval tray's state and its springs. Every number that moves on
/// screen is a SpringValue here, stepped each frame and read by the view, so
/// any movement can be interrupted, thrown by a finger or turned around
/// without a jump (docs/approvals.md, "On the iPhone").
@MainActor
@Observable
final class ApprovalTray {
    enum Step: Hashable { case root, all, cards, places, newCard, newPlace }
    enum Phase: Equatable { case ready, proving, sending, paying, paid, declined, done, failed }

    // MARK: what is shown

    private(set) var request: AssistantApprovalRecords.Request?
    private(set) var detail: AssistantApprovalRecords.Detail?
    private(set) var content: ApprovalContent?
    private(set) var step: Step = .root
    /// The body going out while the new one comes in.
    private(set) var leaving: Step?
    private(set) var phase: Phase = .ready
    /// What the button's line under it says now: paying, the order, an error.
    private(set) var footLine = ""
    /// What came of it, in the head once the tray has shrunk into it.
    private(set) var receiptWords: String?
    /// It went: the head shows the green tick where × was.
    private(set) var receiptDone = false
    /// Another question waits behind this one.
    var queued = 0

    // MARK: a payment's picks, as the Mac's pay sheet keeps them

    private(set) var card: String?
    private(set) var place: String?
    private(set) var newCard: ApprovalPicks.NewCard?
    private(set) var newPlace: ApprovalPicks.NewPlace?
    /// The row picked just now, lit for a moment.
    private(set) var flash: String?
    var cardForm = CardForm()
    var placeForm = PlaceForm()

    struct CardForm: Equatable {
        var number = "", expires = "", csc = "", name = ""
        var filled: ApprovalPicks.NewCard? {
            let digits = number.filter(\.isNumber)
            let parts = expires.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard AssistantWallet.luhn(digits), parts.count == 2, (1...12).contains(parts[0]) else { return nil }
            let year = parts[1] < 100 ? 2000 + parts[1] : parts[1]
            return .init(number: digits, csc: csc.filter(\.isNumber), name: name.trimmingCharacters(in: .whitespaces), month: parts[0], year: year)
        }
    }

    struct PlaceForm: Equatable {
        var name = "", street = "", apt = "", city = "", postal = ""
        var filled: ApprovalPicks.NewPlace? {
            let street = [self.street, apt].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            guard !self.street.trimmingCharacters(in: .whitespaces).isEmpty, !city.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return .init(name: name.trimmingCharacters(in: .whitespaces), street: street, city: city.trimmingCharacters(in: .whitespaces),
                         postal: postal.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: geometry, frame by frame

    /// How far the tray is below its place: 0 up, its height and more away.
    private(set) var rise: CGFloat = 1000
    /// A finger on the tray.
    private(set) var drag: CGFloat = 0
    /// The tray's height below its head, as it goes from body to body.
    private(set) var height: CGFloat = 0
    /// 0 the old body, 1 the new one.
    private(set) var swap: CGFloat = 1
    /// The keyboard under the tray.
    private(set) var lift: CGFloat = 0
    /// 0 the row, 1 its window.
    private(set) var win: CGFloat = 0
    private(set) var pull: CGFloat = 0
    private(set) var scroll: CGFloat = 0
    /// Which item the window shows, fractional while it pages.
    private(set) var page: CGFloat = 0
    /// 0 the thumbnail, 1 the page full screen.
    private(set) var picture: CGFloat = 0
    private(set) var pictureDrag: CGFloat = 0
    /// Under Reduce Motion nothing moves: the tray, the window and a page
    /// come and go as cross-fades of 0.2 s (Motion.fade), these their shares.
    private(set) var trayFade: Double = 1
    private(set) var windowFade: Double = 1
    private(set) var pictureFade: Double = 1
    /// 0 the tray, 1 shrunk into its head.
    private(set) var fold: CGFloat = 0

    /// The window's item while it is out or on its way.
    private(set) var windowItem: Int?
    private(set) var windowOpen = false
    /// Where the window grows from and folds into: its row's key in
    /// `frames`, resolved each frame where the row is now.
    private(set) var windowFrom = ""
    private(set) var pictureFile: AssistantApprovalRecords.Detail.File?
    private(set) var pictureKey = ""
    private(set) var pictureOpen = false

    /// Rows', thumbnails' and papers' frames by key: "tray:" ones in the
    /// tray's own space, before it moves or steps back; "win:" ones on screen.
    @ObservationIgnored var frames: [String: CGRect] = [:]
    /// Told when the tray has gone and the next question may come.
    @ObservationIgnored var onFree: () -> Void = {}
    /// The card a site declined, its row red until another is picked.
    private(set) var declinedCard: String?
    /// Each body's own height, as laid out.
    @ObservationIgnored private(set) var bodies: [Step: CGFloat] = [:]
    /// The window's words' height, for where scrolling ends.
    @ObservationIgnored var windowContent: CGFloat = 0
    @ObservationIgnored var windowViewport: CGFloat = 0
    /// The footer's height under the body.
    private(set) var footer: CGFloat = 0
    @ObservationIgnored weak var app: AppModel?

    @ObservationIgnored private var riseS: SpringValue!
    @ObservationIgnored private var dragS: SpringValue!
    @ObservationIgnored private var heightS: SpringValue!
    @ObservationIgnored private var swapS: UnitSpring!
    @ObservationIgnored private var liftS: SpringValue!
    @ObservationIgnored private var winS: UnitSpring!
    @ObservationIgnored private var pullS: SpringValue!
    @ObservationIgnored private var scrollS: SpringValue!
    @ObservationIgnored private var pageS: UnitSpring!
    @ObservationIgnored private var pictureS: UnitSpring!
    @ObservationIgnored private var pictureDragS: SpringValue!
    @ObservationIgnored private var foldS: UnitSpring!
    @ObservationIgnored private var dragStart: CGFloat = 0
    @ObservationIgnored private var scrollStart: CGFloat = 0
    @ObservationIgnored private var pageStart: CGFloat = 0
    @ObservationIgnored private var gesture: Gesture?
    @ObservationIgnored private var pendingRise = false
    @ObservationIgnored private var leaveSpeed: CGFloat?
    /// Where a finger's drag was when it was recognized: the piece follows
    /// from there, not from where the finger first came down.
    @ObservationIgnored private var dragBase: CGSize?
    /// The window is laid out (hidden) once the tray has risen, so a tap
    /// opens it without building every page in that frame.
    private(set) var windowReady = false
    /// The step whose swap has finished: forms focus their first field only
    /// then, so the keyboard's first load doesn't fall in the swap.
    private(set) var settledStep: Step = .root
    @ObservationIgnored private var generation = 0

    private enum Gesture { case pull, scroll, page }

    /// The one tray; named states and tests reach it here.
    static let shared = ApprovalTray()

    init() {
        riseS = SpringValue(1000) { [weak self] in self?.rise = $0 }
        dragS = SpringValue(0) { [weak self] in self?.drag = $0 }
        heightS = SpringValue(0) { [weak self] in self?.height = $0 }
        swapS = UnitSpring(1) { [weak self] in self?.swap = $0 }
        liftS = SpringValue(0) { [weak self] in self?.lift = $0 }
        winS = UnitSpring(0) { [weak self] in self?.win = $0 }
        pullS = SpringValue(0) { [weak self] in self?.pull = $0 }
        scrollS = SpringValue(0) { [weak self] in self?.scroll = $0 }
        pageS = UnitSpring(0) { [weak self] in self?.page = $0 }
        pictureS = UnitSpring(0) { [weak self] in self?.picture = $0 }
        pictureDragS = SpringValue(0) { [weak self] in self?.pictureDrag = $0 }
        foldS = UnitSpring(0) { [weak self] in self?.fold = $0 }
        // A stalled frame slows the tray for a moment; it never leaps.
        for spring in [riseS, dragS, heightS, liftS, pullS, scrollS, pictureDragS] { spring?.maxStep = 1.0 / 50 }
        for spring in [swapS, winS, pageS, pictureS, foldS] { spring?.maxStep = 1.0 / 50 }
    }

    var isUp: Bool { request != nil || receiptWords != nil }
    /// The head's words and tick, coming in late in the shrink.
    var receiptShown: Double { Double(min(1, max(0, (fold - 0.55) / 0.35))) }
    /// After a decline, the Mac asked again: a yes can go once more.
    var reAsked: Bool { request.map { r in app?.sync.assistantApprovals.contains { $0.id == r.id } == true } ?? false }
    func bodyHeight(_ step: Step) -> CGFloat? { bodies[step] }

    /// Away without an answer: one already went (declined, failed).
    func dismiss() {
        guard request != nil, phase == .declined || phase == .failed else { return }
        leave()
    }
    var busy: Bool { phase != .ready && phase != .declined && phase != .failed }
    var canChange: Bool { (phase == .ready || phase == .declined) && !departing }
    /// On its way out (a no, a decline closed, done): nothing changes it now.
    private(set) var departing = false
    /// A finger on the tray, the window or a page, for the trace.
    var fingerDown: Bool { dragBase != nil || Date().timeIntervalSince(fingerUp) < 0.05 }
    @ObservationIgnored private var fingerUp = Date.distantPast

    // MARK: arriving and going

    /// The bridge's question now, with its detail: a new one rises, the same
    /// one takes what changed in place.
    func show(_ next: AssistantApprovalRecords.Request?, detail: AssistantApprovalRecords.Detail?) {
        ApprovalTrace.mark("show")
        if let next, let request, next.id == request.id {
            if detail != self.detail { take(detail, for: next) }
            return
        }
        // Asked again after a decline (a new total, another try): the same
        // tray, ready again, with what the person picked kept.
        if let next, let request, phase == .declined, next.tab == request.tab, next.session == request.session {
            self.request = next
            take(detail, for: next)
            return
        }
        guard let next else {
            // Gone while asking: answered on the Mac, or it expired.
            if request != nil, !departing, phase == .ready { leave(receipt: "Answered on Mac") }
            return
        }
        guard request == nil, receiptWords == nil else { return }
        generation += 1
        departing = false
        frozen = false
        request = next
        take(detail, for: next)
        step = .root
        leaving = nil
        phase = .ready
        footLine = ""
        declinedCard = nil
        card = detail?.pay?.card
        place = detail?.pay?.place
        newCard = nil
        newPlace = nil
        cardForm = CardForm()
        placeForm = PlaceForm()
        windowItem = nil
        windowOpen = false
        pictureFile = nil
        pictureOpen = false
        foldS.set(0)
        winS.set(0)
        pictureS.set(0)
        dragS.set(0)
        swapS.set(1)
        windowReady = false
        // Up from the bottom edge, whole: it waits below the screen until its
        // body is laid out, so its first frame is a light one and it rises
        // only its own height.
        riseS.set(1000)
        pendingRise = true
        trayFade = 1
        windowFade = 1
        pictureFade = 1
        Haptics.play(.warning, reason: Haptics.Reason.needsYou)
    }

    private func take(_ detail: AssistantApprovalRecords.Detail?, for request: AssistantApprovalRecords.Request) {
        self.detail = detail
        content = ApprovalContent(request, detail: detail)
        if card == nil || !(detail?.pay?.cards.contains { $0.id == card } ?? false) && newCard == nil { card = detail?.pay?.card }
        if place == nil || !(detail?.pay?.places.contains { $0.id == place } ?? false) && newPlace == nil { place = detail?.pay?.place }
    }

    /// Down and away. With words, the tray first shrinks into its head, which
    /// says what happened for a moment, then goes the way it came.
    private func leave(receipt words: String? = nil, done: Bool = false) {
        departing = true
        receiptDone = done
        if windowOpen { foldWindow() }
        let gen = generation
        let finish = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.request = nil
            self.content = nil
            self.receiptWords = nil
            self.onFree()
        }
        if Motion.reduced && !Motion.disabled {
            receiptWords = words
            if let _ = words { withAnimation(Motion.fade) { foldS.set(1) } }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(words == nil ? 0 : 1300))
                guard let self, self.generation == gen, !self.frozen else { return }
                withAnimation(Motion.fade) { self.trayFade = 0 } completion: { finish() }
            }
            return
        }
        if let words {
            receiptWords = words
            foldS.animate(to: 1, .approvalFold)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Motion.disabled ? 300 : 1450))
                guard let self, self.generation == gen, !self.frozen else { return }
                self.riseS.animate(to: ApprovalMetrics.receipt + ApprovalMetrics.inset + 30, .approvalOut) { done in
                    if done { finish() }
                }
            }
        } else {
            // The finger's offset becomes the rise's, so the throw goes on at its speed.
            let off = (bodies[.root] ?? 400) + footer + ApprovalMetrics.header + ApprovalMetrics.inset + 30
            let speed = leaveSpeed
            leaveSpeed = nil
            riseS.set(rise + drag)
            dragS.set(0)
            riseS.animate(to: max(off, rise + 1), .approvalOut, velocity: speed) { done in
                if done { finish() }
            }
        }
    }

    /// Words alone, no tray before them: a question answered on the Mac that
    /// an old notification opened. A small card up from the bottom and away.
    func sayReceipt(_ words: String) {
        guard request == nil, receiptWords == nil else { return }
        generation += 1
        let gen = generation
        receiptWords = words
        receiptDone = false
        foldS.set(1)
        let off = ApprovalMetrics.receipt + ApprovalMetrics.inset + 30
        let finish = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.receiptWords = nil
            self.onFree()
        }
        let reduced = Motion.reduced && !Motion.disabled
        if reduced {
            riseS.set(0)
            trayFade = 0
            withAnimation(Motion.fade) { trayFade = 1 }
        } else {
            trayFade = 1
            riseS.set(off)
            riseS.animate(to: 0, .approvalIn)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Motion.disabled ? 300 : 1400))
            guard let self, self.generation == gen else { return }
            if reduced {
                withAnimation(Motion.fade) { self.trayFade = 0 } completion: { finish() }
            } else {
                self.riseS.animate(to: off, .approvalOut) { done in
                    if done { finish() }
                }
            }
        }
    }

    // MARK: no and yes

    func no() {
        guard let request, canChange else { return }
        Haptics.play(.light, reason: Haptics.Reason.rowAction)
        app?.sync.answerAssistantApproval(request.id, yes: false)
        leave()
    }

    /// The yes: proven here first, then sent with what was picked.
    func yes(account: String? = nil) {
        guard let request, let content, phase == .ready || phase == .declined else { return }
        if phase == .declined {
            // A decline the Mac hasn't asked about again: nothing to answer.
            if app?.sync.assistantApprovals.contains(where: { $0.id == request.id }) != true { leave(); return }
        }
        phase = .proving
        footLine = ""
        var picks = ApprovalPicks(detail: detail)
        if content.pay != nil {
            // Said even when it is the one the Mac showed: only a card named
            // in the answer is put into the page before the press.
            if let newCard, card == Self.newID { picks.newCard = newCard } else if content.pay?.takesCard == true { picks.card = card }
            if let newPlace, place == Self.newID { picks.newPlace = newPlace } else if content.pay?.takesPlace == true { picks.place = place }
        }
        let gen = generation
        app?.sync.answerAssistantApproval(request.id, yes: true, choice: account, picks: picks) { [weak self] outcome in
            guard let self, self.generation == gen else { return }
            switch outcome {
            case .cancelled:
                self.phase = .ready
            case .failed:
                self.phase = .failed
                Haptics.play(.error, reason: Haptics.Reason.failed)
                self.footLine = "This changed on your Mac. Check it there."
            case .sent:
                Haptics.play(.light, reason: Haptics.Reason.confirm)
                self.phase = .sending
                // A Mac that never says what came of it (asleep, an older Yab,
                // the result lost) doesn't keep the tray up for good.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    guard let self, self.generation == gen, !self.frozen,
                          self.phase == .sending || self.phase == .paying else { return }
                    self.leave(receipt: "Sent to your Mac")
                }
                if content.kind != .pay {
                    // Nothing on this screen would show it went: the head says so.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(Motion.disabled ? 0 : 650))
                        guard let self, self.generation == gen, self.phase == .sending, !self.frozen else { return }
                        self.phase = .done
                        Haptics.play(.success, reason: Haptics.Reason.done)
                        self.leave(receipt: Self.pastWords(content), done: true)
                    }
                }
            }
        }
    }

    /// What the Mac said came of the yes (a payment's site answering).
    func result(_ result: AssistantApprovalRecords.Result?) {
        ApprovalTrace.mark("result")
        guard let result, let content, content.pay != nil else { return }
        switch result.phase {
        case .paying where phase == .sending || phase == .proving:
            phase = .paying
            footLine = "This can take a few seconds"
        case .paid where phase != .paid:
            phase = .paid
            footLine = result.order.map { "Order \($0)" } ?? "On \(content.name)"
            Haptics.play(.success, reason: Haptics.Reason.paid)
            let gen = generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Motion.disabled ? 0 : 1100))
                guard let self, self.generation == gen, !self.frozen else { return }
                self.leave(receipt: "Paid \u{00B7} \(content.pay?.amount ?? "")", done: true)
            }
        case .declined where phase != .declined:
            phase = .declined
            declinedCard = card
            footLine = result.words ?? "Payment not completed"
            Haptics.play(.error, reason: Haptics.Reason.failed)
        case .done where phase == .sending || phase == .paying || phase == .proving:
            // The sheet closed with no word from the site: it went, as far as
            // the Mac knows.
            phase = .done
            let gen = generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Motion.disabled ? 0 : 500))
                guard let self, self.generation == gen, !self.frozen else { return }
                self.leave(receipt: "Approved", done: true)
            }
        case .failed:
            phase = .failed
            footLine = result.words ?? "It didn’t go through on your Mac."
            Haptics.play(.error, reason: Haptics.Reason.failed)
        default:
            break
        }
    }

    static func pastWords(_ content: ApprovalContent) -> String {
        let verb = content.verb.split(separator: " ").first.map(String.init) ?? "Done"
        let past: [String: String] = ["Send": "Sent", "Upload": "Uploaded", "Sign": "Signed In", "Fill": "Filled", "Archive": "Archived",
                                      "Post": "Posted", "Search": "Searching", "Go": "Going", "Save": "Saved", "Keep": "Kept",
                                      "Read": "Reading", "Use": "Using Tab", "Allow": "Allowed", "Approve": "Approved"]
        let word = past[verb] ?? "Approved"
        // The head already names who or where: this says what, when there is more to say.
        let what: String? = switch content.kind {
        case .mail: content.items.first?.mail?.subject
        case .mails: "\(content.items.count) mails"
        case .files: content.files.count == 1 ? content.files.first?.name : "\(content.files.count) files"
        default: nil
        }
        guard let what, !what.isEmpty else { return word }
        return "\(word) \u{00B7} \(what)"
    }

    // MARK: the tray under a finger

    func trayDragChanged(_ raw: CGFloat) {
        guard canChange, windowItem == nil, pictureFile == nil, !pendingRise else { return }
        if dragBase == nil { dragBase = CGSize(width: 0, height: raw - dragS.value) }
        let dy = raw - (dragBase?.height ?? 0)
        // Down follows the finger; up resists.
        dragS.set(dy > 0 ? dy : -ColumnMath.rubber(-dy, 60))
    }

    func trayDragEnded(_ raw: CGFloat, velocity: CGFloat, height: CGFloat) {
        defer { dragBase = nil; fingerUp = Date() }
        guard canChange, windowItem == nil, pictureFile == nil else { return }
        let dy = drag
        if dy > height / 3 || velocity > ApprovalMetrics.pullFlick {
            // A synthesized or wild flick can say anything: a hand's pace at most.
            leaveSpeed = min(max(0, velocity), 4000)
            no()
        } else {
            dragS.animate(to: 0, .approvalBack, velocity: velocity)
        }
    }

    // MARK: steps

    /// One body for another in the same tray.
    func go(_ next: Step) {
        guard next != step, canChange || next == .root else { return }
        leaving = step
        step = next
        settledStep = .root
        if Motion.reduced && !Motion.disabled {
            // A cross-fade in place, the height with it.
            swapS.set(0)
            let h = bodies[next].map { $0 + footerFor(next) }
            withAnimation(Motion.fade) {
                swapS.set(1)
                if let h { heightS.set(h) }
            } completion: { [weak self] in
                guard let self, self.step == next else { return }
                self.leaving = nil
                self.settledStep = next
            }
            return
        }
        swapS.set(0)
        swapS.animate(to: 1, .approvalStep) { [weak self] done in
            guard let self, done else { return }
            self.leaving = nil
            self.settledStep = self.step
        }
        if let h = bodies[next] { heightS.animate(to: h + footerFor(next), .approvalHeight) }
    }

    /// ‹: a form to its list, a list to the tray's first body.
    func back() {
        switch step {
        case .newCard: go(.cards)
        case .newPlace: go(.places)
        case .cards, .places, .all: go(.root)
        case .root: break
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// A body laid out: its height, which the tray follows when it shows.
    func measured(_ step: Step, height h: CGFloat) {
        ApprovalTrace.mark("measured.\(step)")
        let had = bodies[step]
        bodies[step] = h
        if pendingRise, step == .root, request != nil {
            pendingRise = false
            heightS.set(h + footer)
            let gen = generation
            // It rises on calm frames: opened from a notification the app is
            // still launching, and a rise begun in that would stutter.
            CalmFrames.wait { [weak self] in
                guard let self, self.generation == gen else { return }
                if Motion.reduced && !Motion.disabled {
                    self.riseS.set(0)
                    self.trayFade = 0
                    withAnimation(Motion.fade) { self.trayFade = 1 }
                    self.windowReady = true
                    return
                }
                self.riseS.set(ApprovalMetrics.header + h + self.footer + ApprovalMetrics.inset + 24)
                self.riseS.animate(to: 0, .approvalIn) { [weak self] done in
                    guard let self, done, self.generation == gen else { return }
                    // The window is laid out a moment after, on a still frame.
                    CalmFrames.wait { [weak self] in
                        guard let self, self.generation == gen else { return }
                        ApprovalTrace.mark("windowReady")
                        self.windowReady = true
                    }
                }
            }
            return
        }
        guard step == self.step, had != h else { return }
        let target = h + footerFor(step)
        if heightS.target == 0 || self.height == 0 { heightS.set(target) } else { heightS.animate(to: target, .approvalHeight) }
    }

    func measuredFooter(_ h: CGFloat) {
        guard abs(h - footer) > 0.5 else { return }
        footer = h
        if let b = bodies[step] { heightS.animate(to: b + footerFor(step), .approvalHeight) }
    }

    private func footerFor(_ step: Step) -> CGFloat {
        step == .cards || step == .places ? 0 : footer
    }

    func keyboard(_ h: CGFloat) {
        liftS.animate(to: h, .approvalKeyboard)
    }

    // MARK: a payment's picks

    static let newID = "new"

    func pickCard(_ id: String) {
        guard canChange else { return }
        if id != card { flash = "card" }
        card = id
        go(.root)
        unflash()
    }

    func pickPlace(_ id: String) {
        guard canChange else { return }
        if id != place { flash = "place" }
        place = id
        go(.root)
        unflash()
    }

    func saveCard() {
        guard let filled = cardForm.filled else { return }
        newCard = filled
        card = Self.newID
        flash = "card"
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        go(.root)
        unflash()
    }

    func savePlace() {
        guard let filled = placeForm.filled else { return }
        newPlace = filled
        place = Self.newID
        flash = "place"
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        go(.root)
        unflash()
    }

    private func unflash() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.flash = nil
        }
    }

    // MARK: the window

    func openWindow(_ index: Int, key: String) {
        guard let content, content.items.indices.contains(index), windowItem == nil || !windowOpen, pictureFile == nil else { return }
        guard frames[key] != nil else { return }
        Haptics.play(.light, reason: Haptics.Reason.rowAction)
        windowFrom = key
        windowItem = index
        windowOpen = true
        pageS.set(CGFloat(index))
        scrollS.set(0)
        pullS.set(0)
        if Motion.reduced && !Motion.disabled {
            winS.set(1)
            windowFade = 0
            withAnimation(Motion.fade) { windowFade = 1 }
            return
        }
        winS.animate(to: 1, .approvalWindow)
    }

    /// Back into the row of the item open now, from wherever it is.
    func foldWindow(velocity: CGFloat? = nil) {
        guard let content, windowItem != nil, windowOpen else { return }
        let index = Int(pageS.target.rounded())
        windowItem = index
        windowOpen = false
        if let item = content.items[safe: index] {
            windowFrom = ["tray:row.\(item.id)", "tray:more", "tray:paper"].first { frames[$0] != nil } ?? windowFrom
        }
        if Motion.reduced && !Motion.disabled {
            pullS.set(0)
            withAnimation(Motion.fade) { windowFade = 0 } completion: { [weak self] in
                guard let self, !self.windowOpen else { return }
                self.winS.set(0)
                self.windowItem = nil
                self.windowFade = 1
                self.scrollS.set(0)
            }
            return
        }
        pullS.animate(to: 0, .approvalWindow, velocity: velocity)
        winS.animate(to: 0, .approvalWindow) { [weak self] done in
            guard let self, done, !self.windowOpen else { return }
            self.windowItem = nil
            self.scrollS.set(0)
        }
    }

    func windowDragChanged(_ raw: CGSize) {
        guard windowOpen else { return }
        if dragBase == nil { dragBase = raw }
        let translation = CGSize(width: raw.width - (dragBase?.width ?? 0), height: raw.height - (dragBase?.height ?? 0))
        if gesture == nil {
            if abs(translation.width) > abs(translation.height), (content?.items.count ?? 0) > 1 {
                gesture = .page
                pageStart = pageS.value
            } else if translation.height > 0, scrollS.value <= 0.5 {
                gesture = .pull
            } else {
                gesture = .scroll
                scrollStart = scrollS.value
            }
        }
        switch gesture {
        case .pull: pullS.set(max(0, translation.height))
        case .scroll:
            let s = scrollStart - translation.height
            scrollS.set(rubber(s, max: maxScroll))
        case .page:
            let n = CGFloat(max(0, (content?.items.count ?? 1) - 1))
            let width = max(1, windowViewportWidth)
            var p = pageStart - translation.width / width
            if p < 0 { p = -ColumnMath.rubber(-p * width, 120) / width }
            if p > n { p = n + ColumnMath.rubber((p - n) * width, 120) / width }
            pageS.set(p)
        case nil: break
        }
    }

    @ObservationIgnored var windowViewportWidth: CGFloat = 1

    func windowDragEnded(_ translation: CGSize, velocity: CGSize) {
        defer { gesture = nil; dragBase = nil; fingerUp = Date() }
        switch gesture {
        case .pull:
            let d = pullS.value
            if d > ApprovalMetrics.pullClose || (d > 40 && velocity.height > ApprovalMetrics.pullFlick) {
                foldWindow(velocity: velocity.height)
            } else {
                pullS.animate(to: 0, .approvalBack, velocity: velocity.height)
            }
        case .scroll:
            // Coasting as a scroll view does, then inside its ends.
            let coast = scrollS.value - velocity.height * 0.32
            scrollS.animate(to: min(max(0, coast), maxScroll), .approvalScroll, velocity: -velocity.height)
        case .page:
            let n = max(0, (content?.items.count ?? 1) - 1)
            let from = pageStart.rounded()
            let moved = pageS.value - from
            var to = Int(from)
            if moved > ApprovalMetrics.pageCommit || velocity.width < -ApprovalMetrics.pageFlick { to = min(n, Int(from) + 1) }
            else if moved < -ApprovalMetrics.pageCommit || velocity.width > ApprovalMetrics.pageFlick { to = max(0, Int(from) - 1) }
            if to != Int(from) {
                Haptics.play(.selection, reason: Haptics.Reason.swipeThreshold)
                scrollS.set(0)
            }
            pageS.animate(to: CGFloat(to), .approvalPage, velocity: -velocity.width / max(1, windowViewportWidth))
        case nil: break
        }
    }

    func windowScroll(by dy: CGFloat) {
        guard windowOpen else { return }
        scrollS.animate(to: min(max(0, scrollS.target + dy), maxScroll), .approvalScroll)
    }

    func windowGoTo(_ index: Int) {
        guard windowOpen, let n = content?.items.count, (0..<n).contains(index) else { return }
        scrollS.set(0)
        pageS.animate(to: CGFloat(index), .approvalPage)
    }

    var windowPage: Int { Int(pageS.target.rounded()) }

    private var maxScroll: CGFloat { max(0, windowContent - windowViewport) }

    private func rubber(_ s: CGFloat, max m: CGFloat) -> CGFloat {
        if s < 0 { return -ColumnMath.rubber(-s, 300) }
        if s > m { return m + ColumnMath.rubber(s - m, 300) }
        return s
    }

    // MARK: a file's page

    func openPicture(_ file: AssistantApprovalRecords.Detail.File, key: String) {
        guard frames[key] != nil, pictureFile == nil || !pictureOpen else { return }
        Haptics.play(.light, reason: Haptics.Reason.rowAction)
        pictureKey = key
        pictureFile = file
        pictureOpen = true
        pictureDragS.set(0)
        if Motion.reduced && !Motion.disabled {
            pictureS.set(1)
            pictureFade = 0
            withAnimation(Motion.fade) { pictureFade = 1 }
            return
        }
        pictureS.animate(to: 1, .approvalPicture)
    }

    func closePicture(velocity: CGFloat? = nil) {
        guard pictureFile != nil, pictureOpen else { return }
        pictureOpen = false
        if Motion.reduced && !Motion.disabled {
            withAnimation(Motion.fade) { pictureFade = 0 } completion: { [weak self] in
                guard let self, !self.pictureOpen else { return }
                self.pictureS.set(0)
                self.pictureDragS.set(0)
                self.pictureFile = nil
                self.pictureFade = 1
            }
            return
        }
        pictureDragS.animate(to: 0, .approvalPictureBack, velocity: velocity)
        pictureS.animate(to: 0, .approvalPictureBack) { [weak self] done in
            guard let self, done, !self.pictureOpen else { return }
            self.pictureFile = nil
        }
    }

    func pictureDragChanged(_ raw: CGFloat) {
        guard pictureOpen else { return }
        if dragBase == nil { dragBase = CGSize(width: 0, height: raw - pictureDragS.value) }
        pictureDragS.set(raw - (dragBase?.height ?? 0))
    }

    func pictureDragEnded(_ raw: CGFloat, velocity: CGFloat) {
        defer { dragBase = nil; fingerUp = Date() }
        let dy = pictureDrag
        guard pictureOpen else { return }
        if dy > 120 || velocity > ApprovalMetrics.pullFlick { closePicture(velocity: velocity) }
        else { pictureDragS.animate(to: 0, .approvalBack, velocity: velocity) }
    }

    // MARK: Reduce Motion and still pictures

    /// A named state held at a moment: every spring where it would be.
    /// A named state held still: nothing scheduled moves it on.
    private(set) var frozen = false

    /// A named state: the tray shrinking into its head with these words.
    func holdReceipt(_ words: String, fold: CGFloat, done: Bool = true) {
        frozen = true
        departing = true
        receiptWords = words
        receiptDone = done
        phase = .done
        hold(fold: fold)
    }

    func hold(win: CGFloat? = nil, page: CGFloat? = nil, picture: CGFloat? = nil, swap: CGFloat? = nil, fold: CGFloat? = nil,
              rise: CGFloat? = nil, pull: CGFloat? = nil) {
        frozen = true
        if let win { winS.set(win) }
        if let page { pageS.set(page) }
        if let picture { pictureS.set(picture) }
        if let swap { swapS.set(swap) }
        if let fold { foldS.set(fold) }
        if let rise { riseS.set(rise) }
        if let pull { pullS.set(pull) }
    }
}


/// A SpringValue for a share (0 to 1, or a page's index): stepped in
/// thousandths, so it comes to rest at its target and not 0.04 short of it,
/// which for a share is a visible jump at the end.
@MainActor
final class UnitSpring {
    private static let scale: CGFloat = 1000
    private let spring: SpringValue

    init(_ value: CGFloat, onUpdate: @escaping (CGFloat) -> Void) {
        spring = SpringValue(value * Self.scale) { onUpdate($0 / UnitSpring.scale) }
    }

    var value: CGFloat { spring.value / Self.scale }
    var target: CGFloat { spring.target / Self.scale }
    var velocity: CGFloat { spring.velocity / Self.scale }

    func set(_ value: CGFloat) { spring.set(value * Self.scale) }
    var maxStep: CFTimeInterval {
        get { spring.maxStep }
        set { spring.maxStep = newValue }
    }

    func animate(to target: CGFloat, _ motion: Motion, velocity: CGFloat? = nil, completion: ((Bool) -> Void)? = nil) {
        spring.animate(to: target * Self.scale, motion, velocity: velocity.map { $0 * Self.scale }, completion: completion)
    }
}


/// Two display frames in a row on time, or 0.6 s at most: then a movement
/// may start without its first frames falling into someone else's work.
@MainActor
final class CalmFrames: NSObject {
    private static var waiting: [CalmFrames] = []
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var calm = 0
    private let began = CACurrentMediaTime()
    private let done: () -> Void

    private init(_ done: @escaping () -> Void) { self.done = done }

    /// Seconds since this process started.
    private static func age() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return 10 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }

    static func wait(_ done: @escaping () -> Void) {
        guard !Motion.disabled else { return done() }
        let waiter = CalmFrames(done)
        waiting.append(waiter)
        let link = CADisplayLink(target: waiter, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        waiter.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        let expected = max(1.0 / 120, link.targetTimestamp - link.timestamp)
        if last > 0 { calm = link.timestamp - last < expected * 1.4 ? calm + 1 : 0 }
        last = link.timestamp
        // Just launched (opened from a notification), the app's own start
        // comes in bursts for most of a second: wait it out.
        let young = Self.age() < 0.9
        guard (calm >= 4 && !young) || link.timestamp - began > 1.2 else { return }
        link.invalidate()
        self.link = nil
        Self.waiting.removeAll { $0 === self }
        done()
    }
}
