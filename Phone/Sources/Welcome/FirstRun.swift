import SwiftUI
import UIKit

/// The first launch as one chain, the accepted "One chain" prototype
/// (design unse3fvhd9 v4; work/design/yab-iphone-onboarding-2026-11-09,
/// proto/sauce.js): every step hands one thing of the screen before to the
/// next. The drop becomes ‹, three drawings of the welcome become the three
/// ways to join, the key opens into the code card and its keycaps fly out,
/// the chosen drawing becomes the shield, the shield's blot swells into the
/// drop on paper (the app icon), and the icon stretches into the search
/// field. The welcome's small sparks and dots stay on every step. Nothing
/// asks for a permission; no Joining or In Sync screen, joining goes on in
/// the background.
@MainActor
@Observable
final class FirstRun {
    static let shared = FirstRun()

    enum Step: Hashable {
        /// The drop grows, the drawings burst, the words come out of blur.
        case welcome
        /// Join Your Mac: looking, found, not found, in sync already.
        case mac
        /// The code on keycaps, to type on a Mac that syncs.
        case code
        /// The Recovery Key, in the same card.
        case recovery
        /// Private by Default: the shield and the trackers it throws back.
        case privacy
        /// Make Yab Default?: the app icon, a link and where it opens.
        case makeDefault
        /// The icon stretches into the search field; the app takes over.
        case end
    }

    /// What looking for a Mac on this Apple ID came to.
    enum MacState: Hashable {
        case looking
        /// Joined through iCloud Keychain on this launch: Join.
        case found
        case none
        /// In sync already (a reinstall that kept the key).
        case insync
    }

    /// The three drawings that leave the welcome's field to stay.
    enum Drawing: Hashable, CaseIterable {
        case tabs, key, globe
    }

    /// Where the drop is: on the welcome, gone into ‹, a blot under the
    /// shield, the app icon, the search field's eyes.
    enum DropPose: Hashable {
        case welcome, back, blot, icon, eyes
    }

    /// A tracker on the privacy step: off screen, at the shield, thrown back.
    enum Tracker: Hashable {
        case away, at, thrown
    }

    struct Burst: Identifiable, Hashable {
        let id: Int
        /// In the drawing's 402 × 874 points.
        let center: CGPoint
        let count: Int
        let radius: CGFloat
        var seed: Int { id }
    }

    private(set) var step: Step = .welcome
    /// The steps behind this one, for ‹.
    private(set) var trail: [Step] = []
    /// The last move went back: the morphs run the other way.
    private(set) var wentBack = false
    /// The flow is on this launch: it stays until its last step, whatever
    /// joining does to the Mac underneath.
    private(set) var started = false

    // The welcome's entrance, in its order.
    private(set) var grown = false
    private(set) var eyeOpen = false
    private(set) var burst = false
    private(set) var worded = false

    private(set) var mac: MacState = .looking
    /// The drawing that goes on to be the shield and the app icon.
    private(set) var hero: Drawing = .tabs
    private(set) var drop: DropPose = .welcome
    /// Taps on Join: the tabs drawing hops.
    private(set) var hops = 0
    /// The key opened into the card on the way in: the keycaps fly out of it.
    private(set) var capsFly = false
    private(set) var keyTurns = 0
    /// The Mac let the code or the Recovery Key in.
    private(set) var accepted = false
    /// New codes since the card opened: the keycaps flip like a board.
    private(set) var flips = 0
    private(set) var codeSince = Date()
    /// "New code. The old one expired." for a moment after a flip.
    private(set) var renewedNote = false
    private(set) var wrongs = 0
    /// Typing the Recovery Key: the keyboard is up.
    var typing = false
    private(set) var pastes = 0
    private(set) var trackers: [Tracker] = Array(repeating: .away, count: 4)
    private(set) var thrownBack = 0
    private(set) var shieldHits = 0
    private(set) var isDefault = false
    private(set) var safariShakes = 0
    private(set) var squashes = 0
    /// iOS Settings was opened to choose the browser: its answer comes back
    /// when Yab is in front again.
    private(set) var awaitsDefault = false
    private(set) var bursts: [Burst] = []
    /// Without a Mac: the way on doesn't join.
    private(set) var withoutMac = false
    /// A named state holds the flow where it put it.
    @ObservationIgnored var holds = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextBurst = 0

    // MARK: - the way through

    /// The welcome is on screen: the drop grows, the drawings burst out, the
    /// words come out of blur, Get Started last.
    func begin(_ app: AppModel) {
        guard !started else { return }
        started = true
        guard !Motion.disabled, !Motion.reduced else {
            change { grown = true; eyeOpen = true; burst = true; worded = true }
            return
        }
        Task { @MainActor in
            await pause(0.12); grown = true
            await pause(0.6); eyeOpen = true
            // The one moment the first run has that no finger made: the
            // drawings leave the drop, and the hand feels them go.
            await pause(0.03); burst = true
            Haptics.play(.soft, reason: Haptics.Reason.welcomeBurst)
            await pause(0.8); worded = true
        }
    }

    /// Get Started: the drop goes into ‹, three drawings fly into the three
    /// ways, the rest of the field leaves as a wave, and Yab looks for a Mac.
    func getStarted(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        mac = .looking
        move(to: .mac)
        let mine = generation
        Task { @MainActor in
            await pause(1.5)
            guard mine == generation, step == .mac, mac == .looking, !holds else { return }
            settle(app)
        }
    }

    /// Looking is over: the Mac's drawing is painted in and sparks burst, or
    /// the tabs go back uncoloured and the key comes forward.
    func settle(_ app: AppModel) {
        let now = Self.macState(app)
        guard step == .mac, now != mac else { return }
        mac = now
        if now != .none {
            Haptics.play(.success, reason: Haptics.Reason.done)
            spark(at: CGPoint(x: 201, y: 245), count: 7, radius: 100, after: 0.14)
        }
    }

    static func macState(_ app: AppModel) -> MacState {
        guard app.sync.phase == .on else { return .none }
        return app.sync.joinedByICloud ? .found : .insync
    }

    /// The found Mac: the drawing hops and goes on to be the shield. Sync is
    /// in already; nothing waits on a Joining screen.
    func join(_ app: AppModel) {
        guard mac == .found || mac == .insync else { return }
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        hops += 1
        hero = .tabs
        later(0.2) { [self] in toPrivacy() }
    }

    /// Another Apple ID: the key opens into the code card. On the same Apple
    /// ID but another person's Mac, the found key is forgotten first.
    func useCode(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        if app.sync.phase == .on, app.sync.setup != nil {
            app.sync.joinAgain()
        } else {
            app.sync.beginJoin()
            if case .joining(.code) = app.sync.phase {} else if app.sync.setup == nil {
                app.sync.pretend(.joining(.code(Self.standInCode)), sheet: false)
            }
        }
        hero = .key
        capsFly = true
        keyTurns += 1
        codeSince = Date()
        move(to: .code)
    }

    /// The code is on screen, so a new one replaces it when it expires.
    var showsCode: Bool { started && (step == .code || step == .recovery) }

    /// A new code came: the keycaps flip, the line says why for a moment.
    func codeRenewed() {
        guard step == .code, !accepted else { return }
        flips += 1
        codeSince = Date()
        renewedNote = true
        later(2.2) { [self] in renewedNote = false }
    }

    func useRecoveryKey(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        app.sync.showRecovery(true)
        capsFly = false
        move(to: .recovery)
    }

    /// Paste from Clipboard: the groups fill in one after another.
    func paste(_ text: String, _ app: AppModel) {
        app.sync.typed = text.uppercased()
        pastes += 1
    }

    /// Join under the Recovery Key: in, or the last group goes red and says why.
    func tryRecovery(_ app: AppModel) {
        guard !accepted, !app.sync.typed.isEmpty else { return }
        if !app.sync.useRecovery(app.sync.typed) {
            wrongs += 1
        }
    }

    /// The Mac let the code in, or the Recovery Key was right: the keycaps
    /// turn black and hop in a wave, sparks, and on to the shield.
    func succeed(_ app: AppModel) {
        guard !accepted, step == .code || step == .recovery else { return }
        accepted = true
        typing = false
        spark(at: CGPoint(x: 201, y: 178), count: 8, radius: 96, after: 0.42)
        hero = .key
        later(1.1) { [self] in
            guard !holds, step == .code || step == .recovery else { return }
            toPrivacy()
        }
    }

    func useWithoutMac(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        withoutMac = true
        // Settings › Sync keeps Join Your Mac; nothing else asks, on this
        // launch or the next, and no code waits on the server. The welcome is
        // answered here and not at the end: somebody who said they have no Mac
        // and then quit must not be asked again (Tests/SettingsStoreTests).
        SettingsStore.shared.withoutMac = true
        SettingsStore.shared.welcomed = true
        app.sync.asksOnFront = false
        app.sync.stopAsking()
        hero = .globe
        toPrivacy()
    }

    private func toPrivacy() {
        move(to: .privacy)
        sendTrackers()
    }

    // MARK: - the shield

    /// Each tracker flies at the shield in turn. Blocking: the shield gives,
    /// the tracker is thrown back with a spark, the count goes up. Not
    /// blocking: they come and stay around a grey shield.
    private func sendTrackers() {
        let mine = generation
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still) { trackers = Array(repeating: .away, count: 4); thrownBack = 0 }
        let blocks = SettingsStore.shared.blocksAds
        // Reduce Motion: nothing flies. The shield is simply standing,
        // blocking (the count says how many) or not (they are around it).
        guard !Motion.reduced || Motion.disabled else {
            withAnimation(FirstRun.motion(Motion.fade)) {
                trackers = Array(repeating: blocks ? .thrown : .at, count: 4)
                thrownBack = blocks ? trackers.count : 0
            }
            return
        }
        for i in trackers.indices {
            if blocks {
                later(0.62 + Double(i) * 0.27) { [self] in
                    guard mine == generation, step == .privacy, SettingsStore.shared.blocksAds else { return }
                    trackers[i] = .at
                    later(0.3) { [self] in throwBack(i, mine) }
                }
            } else {
                later(0.3 + Double(i) * 0.12) { [self] in
                    guard mine == generation, step == .privacy, !SettingsStore.shared.blocksAds else { return }
                    trackers[i] = .at
                }
            }
        }
    }

    private func throwBack(_ i: Int, _ mine: Int) {
        guard mine == generation, step == .privacy, SettingsStore.shared.blocksAds, trackers[i] == .at else { return }
        trackers[i] = .thrown
        thrownBack += 1
        shieldHits += 1
        spark(at: Self.trackerHit(i), count: 3, radius: 26)
    }

    /// Block ads and trackers, switched: on, those around the shield are
    /// thrown back one by one; off, the shield greys and they come and stay.
    func setBlocking(_ on: Bool) {
        SettingsStore.shared.blocksAds = on
        guard !Motion.reduced || Motion.disabled else { return sendTrackers() }
        let mine = generation
        if on {
            for (n, i) in trackers.indices.filter({ trackers[$0] == .at }).enumerated() {
                later(0.08 + Double(n) * 0.14) { [self] in throwBack(i, mine) }
            }
        } else {
            thrownBack = 0
            for i in trackers.indices where trackers[i] != .at {
                later(Double(i) * 0.12) { [self] in
                    guard mine == generation, step == .privacy, !SettingsStore.shared.blocksAds else { return }
                    trackers[i] = .at
                }
            }
        }
    }

    /// Where trackers wait off screen and where they meet the shield.
    static let trackerHomes: [CGPoint] = [CGPoint(x: -40, y: 150), CGPoint(x: 442, y: 130), CGPoint(x: -40, y: 318), CGPoint(x: 442, y: 306)]
    static func trackerHit(_ i: Int) -> CGPoint {
        let home = trackerHomes[i], c = CGPoint(x: 201, y: 245)
        let a = atan2(home.y - c.y, home.x - c.x)
        return CGPoint(x: c.x + cos(a) * 118, y: c.y + sin(a) * 118)
    }

    /// Continue under the shield: the default-browser question, unless Yab
    /// is the default already.
    func afterPrivacy(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        if !Self.asksAboutLinks || SettingsUI.shared.assumeDefaultBrowser || DefaultBrowser.refresh() == true {
            toEnd(app)
        } else {
            move(to: .makeDefault)
        }
    }

    /// On since Apple granted Default Web Browser (2026-10-12).
    static let asksAboutLinks = true

    // MARK: - the default browser

    /// Make Yab Default: the iOS setting itself, where the browser is chosen;
    /// its answer is read when Yab is in front again.
    func makeDefault(_ app: AppModel) {
        guard !isDefault else { return toEnd(app) }
        if let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) {
            UIApplication.shared.open(url)
        }
        awaitsDefault = true
    }

    /// Back from iOS Settings: Yab chosen, the drop squats, sparks, "Opens
    /// in" holds and Safari turns to Yab in place; still Safari, the link
    /// shakes its head.
    func returned() {
        guard awaitsDefault, step == .makeDefault else { return }
        awaitsDefault = false
        if DefaultBrowser.refresh(force: true) == true { becameDefault() } else { safariShakes += 1 }
    }

    private func becameDefault() {
        isDefault = true
        squashes += 1
        Haptics.play(.success, reason: Haptics.Reason.done)
        spark(at: CGPoint(x: 201, y: 245), count: 7, radius: 110)
    }

    /// Where the stage's field stands on screen, told by the view: New Tab's
    /// own field grows from that box when the chain hands over.
    @ObservationIgnored var fieldRect: CGRect = .zero
    /// The chain is handing the screen to New Tab's field: nothing else may
    /// open it. A field opened twice is not fresh the second time, and an
    /// unfresh one never builds its sheet (Field/FieldModel.willOpen). The
    /// empty browser behind watches this one, so it keeps its own hint and
    /// buttons off the screen while the hand-over runs (Tabs/EmptyHomeLayer).
    private(set) var handsOver = false

    /// The last step: the icon stretches into the search field, the drop
    /// becomes its eyes, the small pieces fall. Then the welcome goes and
    /// New Tab's field takes the same box, with the keyboard. The hand-over
    /// is the model's, not the view's: the view is gone by then.
    func toEnd(_ app: AppModel) {
        move(to: .end)
        // A finger on the button is a real move, whatever state put the flow
        // here: a held state must not swallow the hand-over.
        holds = false
        handsOver = true
        // The stretch starts on this frame. Everything heavy waits: building
        // the empty ground behind and the sheet above both take the main
        // thread, and whatever runs before the morph's first frame is
        // committed holds the tile still for as long as it lasts.
        //
        // The search sheet stands from the first frame, with its rows and the
        // keyboard rising under it: the icon stretches into the field it
        // already has, not into a field of ours that is replaced later. It
        // opens one frame after the morph starts: building the sheet and the
        // keyboard takes the main thread for about 200 ms, and a morph begun
        // in the same breath stands still through them.
        // Nothing behind the sheet: a phone that has just joined has opened
        // nothing of its own, and the Mac's tabs belong in the sheet's rows,
        // not in front as a page. One frame later, not now: building that
        // ground takes the main thread, and anything done before the morph's
        // first frame is committed holds the tile still for as long as it
        // lasts. One frame is early enough that the step's own ground, which
        // needs 140 ms to thin, never lets a page show through.
        later(1 / 60) { [self] in app.browser.showNothing() }
        later(0.08) { [self] in
            app.field.openNewTab(privately: false, from: fieldRect == .zero ? nil : fieldRect)
        }
        // The stage is over the sheet only while the tile travels; it goes as
        // the tile lands, so one field is ever on screen.
        later(0.44) { [self] in
            guard step == .end, started else { return }
            done()
            handsOver = false
        }
    }

    /// Gone for good, and the welcome with it.
    func done() {
        Motion.welcomeOut.run {
            SettingsStore.shared.welcomed = true
            SettingsUI.shared.welcomeForced = nil
        }
        started = false
    }

    // MARK: - back

    /// ‹: each morph again, the other way.
    func back(_ app: AppModel) {
        guard let last = trail.last, step != .end, !accepted else { return }
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        switch step {
        case .code:
            // The code is let go: nothing polls the server from the choice.
            app.sync.stopAsking()
            mac = Self.macState(app)
        case .recovery:
            typing = false
            app.sync.showRecovery(false)
        case .privacy where withoutMac:
            withoutMac = false
            SettingsStore.shared.withoutMac = false
            // The answer goes back with the step: the welcome is unanswered
            // again until the chain reaches its end.
            SettingsStore.shared.welcomed = false
            app.sync.asksOnFront = true
            mac = Self.macState(app)
        case .privacy:
            mac = Self.macState(app)
        default:
            break
        }
        move(to: last, back: true)
        if last == .privacy { sendTrackers() }
        if last == .mac, mac == .looking {
            let mine = generation
            later(1.5) { [self] in
                guard mine == generation, step == .mac, mac == .looking else { return }
                settle(app)
            }
        }
    }

    // MARK: - moving

    private func move(to next: Step, back: Bool = false) {
        generation += 1
        change {
            if back { trail.removeLast() } else { trail.append(step) }
            wentBack = back
            if next == .code || next == .recovery { accepted = false }
            step = next
        }
        switch next {
        case .welcome:
            change { drop = .welcome }
        case .mac, .code, .recovery, .privacy:
            change { drop = .back }
        case .makeDefault:
            // The shield's blot is where the drop swells from.
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { drop = .blot }
            later(0.03) { [self] in if step == .makeDefault { change { drop = .icon } } }
        case .end:
            change { drop = .eyes }
        }
    }

    /// Reduce Motion: every change a short cross-fade, nothing travels.
    private func change(_ body: () -> Void) {
        if Motion.reduced, !Motion.disabled { withAnimation(Motion.fade, body) } else { body() }
    }

    private func spark(at point: CGPoint, count: Int, radius: CGFloat, after delay: Double = 0) {
        guard !Motion.disabled, !Motion.reduced else { return }
        later(delay) { [self] in
            nextBurst += 1
            let burst = Burst(id: nextBurst, center: point, count: count, radius: radius)
            bursts.append(burst)
            later(0.7) { [self] in bursts.removeAll { $0.id == burst.id } }
        }
    }

    private func later(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        guard seconds > 0, !Motion.disabled else { return work() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    private func pause(_ seconds: Double) async {
        guard !Motion.disabled else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - named states

    struct Still {
        var mac: MacState = .looking
        var hero: Drawing = .tabs
        var accepted = false
        var wrongs = 0
        var typing = false
        var trackers: Tracker = .away
        var thrownBack = 0
        var isDefault = false
        var withoutMac = false
        var renewed = false
    }

    /// A step as a still, for named states (Testing/States+Welcome.swift):
    /// the trail is the way a person would have come.
    func pretend(_ step: Step, _ still: Still = Still()) {
        reset()
        holds = true
        started = true
        grown = true; eyeOpen = true; burst = true; worded = true
        mac = still.mac
        hero = still.hero
        accepted = still.accepted
        wrongs = still.wrongs
        typing = still.typing
        trackers = Array(repeating: still.trackers, count: 4)
        thrownBack = still.thrownBack
        isDefault = still.isDefault
        withoutMac = still.withoutMac
        renewedNote = still.renewed
        if still.renewed { flips = 1 }
        trail = switch step {
        case .welcome: []
        case .mac: [.welcome]
        case .code: [.welcome, .mac]
        case .recovery: [.welcome, .mac, .code]
        case .privacy: [.welcome, .mac]
        case .makeDefault: [.welcome, .mac, .privacy]
        case .end: [.welcome, .mac, .privacy, .makeDefault]
        }
        self.step = step
        drop = switch step {
        case .welcome: .welcome
        case .mac, .code, .recovery, .privacy: .back
        case .makeDefault: .icon
        case .end: .eyes
        }
    }

    /// Settings, Show Welcome Again: the chain from its first moment, with
    /// Settings out of the way (Settings/SettingsLayer).
    func replay(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        reset()
        app.surfaces.closeSettings()
        Motion.welcomeOut.run { SettingsUI.shared.welcomeForced = true }
    }

    /// Back to the first moment, for a named state that starts the flow.
    func reset() {
        generation += 1
        step = .welcome; trail = []; wentBack = false; started = false; handsOver = false
        grown = false; eyeOpen = false; burst = false; worded = false
        mac = .looking; hero = .tabs; drop = .welcome; hops = 0; capsFly = false; keyTurns = 0
        accepted = false; flips = 0; codeSince = Date(); renewedNote = false; wrongs = 0; typing = false; pastes = 0
        trackers = Array(repeating: .away, count: 4); thrownBack = 0; shieldHits = 0
        isDefault = false; safariShakes = 0; squashes = 0; awaitsDefault = false; bursts = []
        withoutMac = false; holds = false
    }

    // MARK: - words

    static let standInCode = "K7QM-4TZP"

    /// The Mac's own name once sync has heard it, else "Your Mac": never a
    /// stand-in name for somebody else's Mac.
    static func macName(_ app: AppModel, lower: Bool = false) -> String {
        app.sync.macs.first?.name ?? (lower ? "your Mac" : "Your Mac")
    }

    /// A view's animation, or none with motion off (named states, tests).
    static func motion(_ animation: Animation) -> Animation? { Motion.disabled ? nil : animation }
    /// Travel: none with motion off, and none with Reduce Motion, where the
    /// whole stage cross-fades instead.
    static func travel(_ animation: Animation) -> Animation? { Motion.disabled || Motion.reduced ? nil : animation }
}

extension Metrics {
    /// The first run's numbers that other places borrow.
    enum FirstTray {
        static let trayInset: CGFloat = 8
        static let radius: CGFloat = 38
    }
}
