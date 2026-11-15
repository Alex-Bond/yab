import Foundation
import Observation
import SwiftUI
import UIKit
import os

/// The field over the keyboard: what is typed, what the field shows, the
/// drafts left behind, the eyes, and where it is between the plate and its
/// place over the keyboard. Surfaces says whether the field is up and which
/// one (the plate's or New Tab's); this says everything else.
///
/// Words left without choosing wait at their page: opening the field on the
/// same tab brings them back, cursor at the end; New Tab keeps one draft of
/// its own. Choosing a row forgets the draft. Words typed with the eyes shut,
/// or over a private tab, are never kept.
@MainActor
@Observable
final class FieldModel {
    /// What is typed.
    var text = ""
    /// How often the page in front holds the typed words, counted a moment
    /// after typing stops (AppModel.countOnThisPage): Safari's "On This Page".
    var onThisPage: (words: String, count: Int)?
    @ObservationIgnored private var onThisPageCount: Task<Void, Never>?
    /// The page's address or Google search words, selected before typing.
    private(set) var showsAddress = false
    /// The eyes are shut: Incognito. New Tab has them, and so does the plate's
    /// field once its words are erased.
    private(set) var isPrivate = false
    /// Which field is drawn: the open one, or the one landing back on the plate.
    private(set) var mode: Surfaces.FieldMode?
    /// The tab the plate's field is about.
    private(set) var pageID: Tab.ID?
    /// That tab is private: no history, no agent, nothing kept.
    private(set) var pageIsPrivate = false
    /// That tab is today's, so a page chosen here loads in it. A pin or a
    /// kept tab (a folder's too) stays what it is: the page opens beside it.
    private(set) var pageIsToday = true
    /// Its address as the field showed it, so words that are only the
    /// address again are no draft.
    @ObservationIgnored private var pageAddress: String?

    // MARK: - where it is

    /// Drawn at all: up, or on its way back to the plate.
    private(set) var shown = false
    /// Counted up after each change of whether and which field is drawn,
    /// once `shown`, `mode` and the rest of that change are set. A change
    /// made while SwiftUI still holds an update of another transaction makes
    /// it draw the waiting views inside that property's willSet, with the old
    /// value, and then miss the new one: the field never came for a swipe up
    /// while the chrome gave way to it, a blank screen with nothing to touch
    /// (farm 49ce6fb8b6484bd9, 3dafdd91612f47d9). The views that decide
    /// whether the field is drawn read this too, so they always hear the
    /// last write of the change.
    private(set) var revision = 0
    /// 0 in the frame it grew from (the plate, +), 1 over the keyboard.
    var progress: CGFloat = 0
    /// The body font scale used by the visible field and its flight origin.
    var textScale: CGFloat = 1
    /// A field hosted outside the phone plate supplies its actual input frame.
    var presentationFrame: CGRect?
    /// Where it grew from, and where it lands.
    private(set) var origin: CGRect?
    private(set) var landing: CGRect?
    /// The frosted backdrop, the cards and rows, the pill's own contents.
    var backdrop: Double = 0
    var cards: Double = 0
    var contents: Double = 1
    /// The pill itself: with Reduce Motion it fades in place instead of
    /// growing out of the plate.
    var pill: Double = 1
    /// The cards and rows dragged down by a finger (already at 60 %).
    var drag: CGFloat = 0
    /// The keyboard's height from the screen's foot, as it last said.
    var keyboard: CGFloat = Metrics.Field.keyboard
    /// New Tab opened by a swipe up on the plate: the spaces without the
    /// keyboard, the field at the screen's foot until a tap asks for it.
    var resting = false

    /// This field stands in the search sheet (Field/SearchSheet).
    private(set) var inSheet = false
    /// 0 under the screen's foot, 1 on the keyboard.
    var sheetRise: CGFloat = 0
    /// 0 the low sheet, 1 the spaces over the whole screen.
    var sheetExpand: CGFloat = 0
    /// The height under the sheet's field; it changes with the rows, not in a morph.
    var sheetBody = Metrics.SearchSheet.body(plain: false)
    /// The spaces card may stand under the sheet from now on (built once it has risen).
    var sheetSpacesReady = false
    @ObservationIgnored private(set) var sheetPulling = false
    /// The finger's way from the sheet to the whole screen (FieldGeometry.sheetSpan).
    @ObservationIgnored var sheetSpan: CGFloat = 400
    @ObservationIgnored private var sheetGrab = SheetGrab.none
    @ObservationIgnored private var sheetFrom: CGFloat = 0
    /// A row under a finger that pulled the sheet stays shut until then.
    @ObservationIgnored private var sheetRowsShutUntil = Date.distantPast
    /// A finger is pulling the sheet, or just let go: its release is no tap.
    var sheetSwallowsTap: Bool { sheetGrab != .none || Date() < sheetRowsShutUntil }
    @ObservationIgnored private lazy var sheetTravel = Self.morphSpring { [weak self] v in self?.sheetExpand = v / Self.morphUnits }
    /// What the sheet grows out of as it rises (the plate, +).
    var sheetOrigin: CGRect?
    @ObservationIgnored private lazy var sheetRiseTravel = Self.morphSpring { [weak self] v in self?.sheetRise = v / Self.morphUnits }
    /// 1 at the screen's top, on its way to being the page just chosen.
    var sheetLeave: CGFloat = 0
    @ObservationIgnored private lazy var sheetLeaveTravel = Self.morphSpring { [weak self] v in self?.sheetLeave = v / Self.morphUnits }
    /// The sheet standing at the top lets the page show through.
    var sheetVeil: Double = 1
    /// The choice opens something new, so the sheet leaves upward. Back to what
    /// already stands under it (an open tab, a tap beside it) it falls.
    @ObservationIgnored var sheetGoesUp = false
    /// Tests keep the spaces' card unless a state asks for the sheet.
    @ObservationIgnored static var sheetInTests = ProcessInfo.processInfo.arguments.contains("-YabSearchSheet")

    /// Asks the input to take the keyboard, with the cursor where it belongs.
    private(set) var focusRequest = 0
    /// Asks the input to let the keyboard go.
    private(set) var blurRequest = 0
    func blur() { blurRequest += 1 }

    /// A link on the clipboard: New Tab's Paste and Go.
    var clipboardLink: URL?
    /// The search sheet's rows while the field stays open, and what they were made for.
    @ObservationIgnored var heldPicks: (key: String, items: [NewTabItem])?
    /// A row removed: the rows are made again.
    var picksRevision = 0
    /// Named states: a history to make the rows from.
    @ObservationIgnored var fixturePicks: Suggestions.Input?

    @ObservationIgnored private var drafts: [Tab.ID: String] = [:]
    /// The pages each tab has shown in its own web view, for Back.
    let history = PageHistory()
    /// The private tabs open now: when one goes, its page, picture and draft
    /// go with it; when the last goes, the store they shared.
    @ObservationIgnored private var privateTabs: Set<Tab.ID> = []
    @ObservationIgnored private var newTabDraft = ""
    @ObservationIgnored private var nextNewTabPrivacy: Bool?
    @ObservationIgnored private var nextNewTabResting = false
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private(set) var searchSettings: SettingsStore = .shared
    @ObservationIgnored private var keyboardWatch: [NSObjectProtocol] = []
    /// Landing, or fading under a sheet: told once.
    @ObservationIgnored private var closing = false
    @ObservationIgnored private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "field")

    /// Called once by the app: the field hears of every opening before it is
    /// drawn, and of the keyboard.
    func attach(_ app: AppModel, settings: SettingsStore = .shared) {
        self.app = app
        searchSettings = settings
        app.surfaces.fieldWillOpen = { [weak self] mode in self?.willOpen(mode) }
        app.surfaces.fieldDidClose = { [weak self, weak app] in
            guard let self, let app else { return }
            // A turn later: whatever closed it (an answer, Settings) has said
            // so by then, and the field fades under it instead of flying home.
            DispatchQueue.main.async {
                self.didClose(into: ChromeGeometry(size: app.screenSize, folded: false, hasNow: app.nowItem != nil).plate)
            }
        }
        let center = NotificationCenter.default
        keyboardWatch = [
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated { self?.keyboardMoved(end) }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardWentAway() }
            },
        ]
        if LaunchOptions.current.isTestRun, app.world.name == "mira" {
            // Mira's clipboard has Lumen's link on it (the prototype's New Tab).
            clipboardLink = URL(string: "https://lumen.events/e/design-systems-night")
        }
        watchPrivateTabs()
    }

    // MARK: - private tabs going

    /// Follows the private tabs wherever they close (the column's ×, Clear,
    /// closePrivate): gone, nothing of them stays on this iPhone.
    private func watchPrivateTabs() {
        guard let app else { return }
        let now = withObservationTracking {
            Set(app.browser.allTabs.lazy.filter(\.isPrivate).map(\.id))
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchPrivateTabs() }
        }
        privateTabsNow(now)
    }

    /// The private tabs now: what went is forgotten, and when none is left
    /// the next private tab starts on a store of its own.
    func privateTabsNow(_ now: Set<Tab.ID>) {
        guard let app else { return }
        let gone = privateTabs.subtracting(now)
        for id in gone {
            app.pages.forget(id)
            drafts[id] = nil
            history.forget(id)
        }
        if !gone.isEmpty, now.isEmpty { app.pages.renewPrivateStore() }
        privateTabs = now
    }

    // MARK: - opening and closing

    /// A menu's explicit Private choice is read before any field content is
    /// projected. It never borrows or replaces the ordinary New Tab draft.
    func openNewTab(privately: Bool, from origin: CGRect? = nil) {
        guard let app else { return }
        nextNewTabPrivacy = privately
        defer { nextNewTabPrivacy = nil }
        app.surfaces.openField(.newTab, from: origin)
    }

    /// How much of New Tab's card has risen out of the plate while a finger
    /// lifts it: 0 at the plate, 1 open. Anything else opens it at 1.
    var reveal: CGFloat = 1
    @ObservationIgnored private(set) var lifting = false
    /// The finger's travel for the whole card: from the plate to under the status bar.
    @ObservationIgnored private var liftSpan: CGFloat = 640

    /// The finger's travel from the plate to the top of the screen.
    private var screenLiftSpan: CGFloat {
        let screen = (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen.bounds.height
            ?? Metrics.screen.height
        return max(300, screen - Metrics.NewTab.highest - 110)
    }

    /// A finger on the plate starts upward: the field opens resting, with the
    /// card at 0, and follows it from here.
    func beginLift() {
        guard app != nil, !shown else { return }
        travel.stop()
        lifting = true
        liftSpan = screenLiftSpan
        openSpaces()
        reveal = 0
        progress = 0
        backdrop = 0
        cards = 1
        pill = 1
    }

    /// The pill becomes the field over its first third; the card's top is the finger.
    func liftMoved(_ dy: CGFloat) {
        guard lifting else { return }
        follow(min(max(-dy / liftSpan, 0), 1.06))
    }

    /// The spaces' one move, frame by frame, whatever drives it (a tap, ✕, a
    /// finger let go): a 1000-point travel, so the spring's rest holds.
    @ObservationIgnored private lazy var travel = Self.morphSpring { [weak self] v in self?.follow(v / Self.morphUnits) }

    /// A morph's spring over this many units a whole way: fine enough to rest
    /// under a pixel of the screen, coarse enough not to spend half a second
    /// on motion nobody sees.
    private static let morphUnits: CGFloat = 200

    /// After a stall the morph goes on from where it was, never leaping.
    private static func morphSpring(_ update: @escaping (CGFloat) -> Void) -> SpringValue {
        let spring = SpringValue(0, onUpdate: update)
        spring.maxStep = 0.025
        return spring
    }

    /// Everything of the spaces from one number, as the agreed morph: the
    /// frame out of the plate (LiftFrame), the plate becoming the field from 5
    /// to 50 %, the dark behind it by 60 %. Nothing on a clock of its own.
    private func follow(_ p: CGFloat) {
        reveal = p
        progress = min(1, max(0, (p - 0.05) / 0.45))
        backdrop = Double(min(1, max(0, p) / 0.6))
    }

    /// The spaces travel to the screen (1) or the plate (0) from where they are.
    private func travel(to end: CGFloat, velocity: CGFloat = 0, completion: (@MainActor () -> Void)? = nil) {
        travel.set(reveal * Self.morphUnits)
        travel.animate(to: end * Self.morphUnits, Motion.spacesMorph, velocity: velocity * Self.morphUnits) { done in
            if done { completion?() }
        }
    }

    /// Back into the plate the way they came; gone, with nothing of their own
    /// left to fade, once they are the plate.
    private func fold(velocity: CGFloat = 0) {
        guard let app else { return }
        folding = true
        travel(to: 0, velocity: velocity) { [weak self] in
            guard let self, self.folding else { return }
            app.surfaces.closeField()
        }
    }
    /// Folding into the plate: didClose then only lets go.
    @ObservationIgnored private var folding = false

    /// The spaces over the page (rising, open or folding): how far the plate
    /// and the Now line have given way to them, by the same move, over its
    /// first 15 %; nil for any other field.
    var spacesVeil: Double? {
        _ = revision
        guard shown, mode == .newTab, resting || lifting || folding else { return nil }
        // Beside the page nothing takes the plate's place.
        if app?.surfaces.fieldBeside == true { return nil }
        return Double(min(1, max(0, reveal) / 0.15))
    }

    /// Let go: past a quarter, or flung up, it opens the rest of the way; else
    /// it folds back into the plate.
    func liftEnded(_ dy: CGFloat, velocity: CGFloat) {
        guard lifting else { return }
        lifting = false
        if reveal > 0.25 || velocity < -600 {
            Haptics.play(.light, reason: Haptics.Reason.columnOpened)
            travel(to: 1, velocity: -velocity / liftSpan)
        } else {
            fold(velocity: -velocity / liftSpan)
        }
    }

    /// How far a finger has pulled the open spaces down, in points.
    @ObservationIgnored private var lowered: CGFloat = 0
    /// The spaces are open, resting, and a finger can take them down.
    var canLower: Bool {
        if inSheet { return shown && !closing && resting && sheetExpand >= 1 }
        return shown && !closing && resting && mode == .newTab
    }
    var isLowering: Bool { lifting && shown }

    /// A finger pulls the open spaces down (the top of a page's list, or the
    /// head): the lift run backwards, the screen going into the plate with it.
    func beginLower() {
        guard canLower || folding, !lifting else { return }
        if inSheet {
            sheetTravel.stop()
            sheetPulling = true
            lifting = true
            lowered = 0
            return
        }
        travel.stop()
        folding = false
        lifting = true
        lowered = (1 - reveal) * screenLiftSpan
        liftSpan = screenLiftSpan
    }

    /// The finger moved `dy` points (down positive) since the last call.
    func lowerMoved(by dy: CGFloat) {
        guard lifting else { return }
        lowered = max(0, lowered + dy)
        if inSheet {
            sheetExpand = max(0, 1 - lowered / sheetSpan)
            return
        }
        follow(1 - min(lowered / liftSpan, 1))
    }

    /// Let go at `velocity` (points a second, down positive): back to the
    /// screen unless it went a quarter of the way or was thrown down.
    func lowerEnded(velocity: CGFloat) {
        guard lifting else { return }
        lifting = false
        lowered = 0
        if inSheet {
            sheetPulling = false
            if velocity < -Metrics.SearchSheet.flick || (sheetExpand > 0.75 && velocity < Metrics.SearchSheet.flick) { expandSheet() } else { collapseSheet() }
            return
        }
        if (reveal > 0.75 && velocity < 600) || velocity < -600 {
            travel(to: 1, velocity: -velocity / liftSpan)
        } else {
            fold(velocity: -velocity / liftSpan)
        }
    }

    @ObservationIgnored private var inPlace = false
    /// A chat is growing out of a row of the card: don't fade the card under it.
    @ObservationIgnored var underChat = false

    /// New Tab's spaces already standing, keyboard down: under a chat that
    /// shrinks back into its row on the Chats page.
    func openSpacesInPlace() {
        inPlace = true
        openSpaces()
        progress = 1
        pill = 1
        backdrop = 1
        cards = 1
        reveal = 1
    }

    // MARK: - the search sheet

    /// The spaces at rest, no search going on: an unfolded Duo's column.
    var spacesResting: Bool { shown && !closing && mode == .newTab && resting }
    private var unfolded: Bool { app?.workspace.unfolded == true }

    var sheetAllowed: Bool {
        guard let app, !app.workspace.tabletControls else { return false }
        return LaunchOptions.current.isTestRun ? Self.sheetInTests : true
    }

    var sheetPose: SearchSheetPose? {
        guard inSheetNow else { return nil }
        return SearchSheetPose(expand: sheetExpand, rise: sheetRise, body: sheetBody, leave: sheetLeave, origin: sheetOrigin)
    }

    private enum SheetGrab { case none, up, down, ignored }

    /// What a finger does on the sheet, its field or beside it. Read in the
    /// screen's space: the sheet moves under the finger.
    var sheetDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { [weak self] value in self?.sheetDragged(value.translation.height) }
            .onEnded { [weak self] value in self?.sheetDragEnded(value.translation.height, velocity: value.velocity.height) }
    }

    private func sheetDragged(_ dy: CGFloat) {
        guard inSheet else { return }
        if sheetGrab == .none {
            if resting || sheetExpand > 0.5 { sheetGrab = .ignored }
            else if dy > 0 { sheetGrab = .down }
            else if !isPrivate, text.isEmpty || showsAddress { sheetGrab = .up; beginSheetPull() }
            else { sheetGrab = .ignored }
        }
        switch sheetGrab {
        case .up: sheetExpand = min(max(sheetFrom - dy / sheetSpan, 0), 1)
        case .down: drag = max(0, dy) * Metrics.Field.dragFollow
        default: break
        }
    }

    private func sheetDragEnded(_ dy: CGFloat, velocity: CGFloat) {
        let grab = sheetGrab
        sheetGrab = .none
        sheetRowsShutUntil = Date().addingTimeInterval(0.3)
        switch grab {
        case .up:
            sheetPulling = false
            if velocity < -Metrics.SearchSheet.flick || (sheetExpand > Metrics.SearchSheet.opensAt && velocity < Metrics.SearchSheet.flick) {
                expandSheet()
            } else {
                sheetTravel.set(sheetExpand * Self.morphUnits)
                sheetTravel.animate(to: 0, Motion.spacesMorph) { _ in }
            }
        case .down:
            if dy > Metrics.Field.closeDistance || velocity > Metrics.Field.closeVelocity { close() }
            else { Motion.fieldRows.run { drag = 0 } }
        default: break
        }
    }

    /// The keyboard stands while the finger decides; only opening puts it away.
    private func beginSheetPull() {
        sheetTravel.stop()
        sheetFrom = sheetExpand
        sheetPulling = true
    }

    /// Chats have their own search, so the sheet stands aside over them.
    var inSheetNow: Bool { inSheet && !NewTabPager.shared.onChats }

    /// The sheet's field near the top: the capsule under it takes over.
    var sheetFieldVeil: Double {
        guard inSheetNow else { return 1 }
        return Double((1 - SearchSheetPose.share(sheetExpand, in: Metrics.SearchSheet.fieldOut))
            * (1 - SearchSheetPose.share(sheetLeave, in: Metrics.SearchSheet.leaveWords)))
    }

    /// The field's words give way as it turns into the capsule.
    var sheetWordsVeil: Double {
        guard inSheetNow else { return 1 }
        return Double((1 - SearchSheetPose.share(sheetExpand, in: Metrics.SearchSheet.wordsOut))
            * (sheetPose?.grown(Metrics.SearchSheet.wordsIn) ?? 1))
    }

    /// Chats' own search, on the page: a tap on the list ends it, words and all.
    var chatsSearch: Bool { sheetAllowed && NewTabPager.shared.onChats }

    /// The spaces at rest stand on their foot bar, the field out of sight
    /// until + or Search asks for it. Private keeps its field.
    var spacesBar: Bool {
        sheetAllowed && resting && !isPrivate && !pageIsPrivate && (!inSheetNow || sheetExpand >= 0.999)
    }

    var spacesBarOpacity: Double {
        guard sheetAllowed, !isPrivate, !pageIsPrivate else { return 0 }
        if inSheetNow { return Double(SearchSheetPose.share(sheetExpand, in: Metrics.SearchSheet.barIn)) }
        guard resting else { return 0 }
        return Double(min(max((reveal - 0.5) / 0.5, 0), 1))
    }

    /// The sheet's second height: the spaces, keyboard down.
    func expandSheet() {
        guard inSheet else { return }
        if !resting { blur(); Motion.keyboardFollow.run { resting = true } }
        Haptics.play(.light, reason: Haptics.Reason.columnOpened)
        sheetTravel.set(sheetExpand * Self.morphUnits)
        sheetTravel.animate(to: Self.morphUnits, Motion.spacesMorph) { _ in }
    }

    /// Back to the low sheet on its keyboard.
    func collapseSheet() {
        guard inSheet else { return }
        Motion.keyboardFollow.run { resting = false }
        focusRequest += 1
        sheetTravel.set(sheetExpand * Self.morphUnits)
        sheetTravel.animate(to: 0, Motion.spacesMorph) { _ in }
    }

    /// + on the spaces: the morph back starts at once, with the keyboard.
    func askFromSpaces() {
        guard resting else { return ask() }
        // Unfolded, the column gives way to the omnibox over the page.
        if unfolded {
            resting = false
            revision &+= 1
            return ask()
        }
        if inSheet { collapseSheet() } else { enterSheetFromSpaces() }
        if !inSheet { ask() }
    }

    /// A tap on the spaces' resting field: search is the sheet from here on.
    private func enterSheetFromSpaces() {
        guard sheetAllowed, !unfolded, !inSheet, !pageIsPrivate, !NewTabPager.shared.onChats, !lifting, let app else { return }
        sheetBody = Metrics.SearchSheet.body(plain: app.fieldRows.isEmpty && NewTabContent.make(for: app).sheetRows.isEmpty)
        inSheet = true
        sheetRise = 1
        sheetExpand = 1
        collapseSheet()
    }

    /// New Tab's field already standing, its keyboard asked for at once: Yab
    /// coming to the front (Field/LaunchKeyboard). Opened before the first
    /// frame, it is drawn open in it, and the keyboard rises with the launch.
    func openNewTabInPlace() {
        inPlace = true
        openNewTab(privately: false)
        progress = 1
        pill = 1
        backdrop = 1
        cards = 1
        reveal = 1
    }

    /// The keyboard for a field that waits without it (New Tab paged in past
    /// the last tab stands first, then asks).
    func ask() { focusRequest += 1 }

    /// Chats' search: the field grows out of its button over the foot as the keyboard rises.
    func askFrom(_ button: CGRect) {
        // It searches the chats: the page's address has no place in it.
        if showsAddress {
            text = ""
            showsAddress = false
        }
        origin = button
        landing = nil
        progress = 0
        Motion.keyboardFollow.run { resting = false }
        focusRequest += 1
        Motion.plusToField.run { progress = 1 }
    }

    /// The plate swiped up: New Tab's spaces, keyboard down. It replaces the
    /// column; a tap on the field brings the keyboard and the capsule.
    func openSpaces(from origin: CGRect? = nil) {
        nextNewTabResting = true
        defer { nextNewTabResting = false }
        openNewTab(privately: false, from: origin)
    }

    /// The field is about to open: its words, then a frame later its growth
    /// out of where it was summoned.
    func willOpen(_ mode: Surfaces.FieldMode) {
        if let app { FieldAnswers.shared.capturePage(in: app, mode: mode) }
        guard let app else { return }
        let tab = app.browser.tab
        // Editing a real page must retain its origin. The plate can still
        // show the short address, and fixture states keep their drawn words.
        let address = tab?.navigationURL.flatMap { SearchEngine.googleWords(in: $0) }
            ?? (app.fixturesEnabled ? tab?.address : (tab?.navigationURL?.absoluteString ?? tab?.address))
        log.debug("field opens: \(String(describing: mode), privacy: .public)")
        closing = false
        sheetGoesUp = false
        sheetLeaveTravel.stop()
        sheetLeave = 0
        sheetVeil = 1
        self.mode = mode
        pageID = tab?.id
        pageIsPrivate = mode == .address && tab?.isPrivate == true
        pageIsToday = tab?.place != .pinned && tab?.place != .kept
        pageAddress = mode == .address ? address : nil
        drag = 0
        isPrivate = mode == .newTab && (nextNewTabPrivacy ?? app.browser.space.isPrivate)
        switch mode {
        case .address:
            if let tab, !pageIsPrivate, let draft = drafts[tab.id], !draft.isEmpty {
                text = draft
                showsAddress = false
            } else {
                text = address ?? ""
                showsAddress = tab != nil
            }
        case .newTab:
            text = isPrivate ? "" : newTabDraft
            showsAddress = false
            if !LaunchOptions.current.isTestRun { clipboardLink = UIPasteboard.general.hasURLs ? clipboardLink ?? Self.pasteboardMarker : nil }
        }
        heldPicks = nil
        origin = app.surfaces.fieldOrigin
        landing = nil
        let fresh = !shown
        let still = FieldMotion.reduced && !Motion.disabled
        // The spaces out of the plate: one move (travel), the card whole from
        // its first frame, everything else by how far it has come.
        let spaces = mode == .newTab && nextNewTabResting && !still && !Motion.disabled
        shown = true
        folding = false
        if fresh {
            progress = still ? 1 : 0
            pill = still ? 0 : 1
            backdrop = 0
            cards = spaces ? 1 : 0
            if spaces { reveal = 0 }
        }
        contents = 1
        // Chats opened as such (All Tabs' left button) waits for a tap on its
        // search, as the swipe up does: a page to look through first.
        resting = mode == .newTab && (nextNewTabResting || NewTabPager.shared.startAt == NewTabPager.chatsPage)
        if !resting { focusRequest += 1 }
        if fresh {
            inSheet = !resting && !pageIsPrivate && sheetAllowed && !unfolded
            if inSheet {
                sheetBody = Metrics.SearchSheet.body(plain: app.fieldRows.isEmpty && NewTabContent.make(for: app).sheetRows.isEmpty)
                NewTabPager.shared.spaceID = nil
                progress = 1
                pill = 1
                cards = 1
                // At launch it stands from the first frame, the keyboard rising under it.
                sheetRise = still || Motion.disabled || inPlace ? 1 : 0
                sheetOrigin = sheetRise == 1 ? nil : sheetGrowsOut(of: origin)
                sheetExpand = 0
                sheetTravel.set(0)
            }
        }
        revision &+= 1
        // A finger lifting it from the plate drives it instead, to the end:
        // let go before the next turn (a busy main thread), its fold back into
        // the plate isn't turned into a rise here.
        let lifted = lifting
        // The pill stands in its origin for one frame, then grows: out of
        // the plate, or out of + in the column.
        let grow = mode == .newTab && origin != nil ? Motion.plusToField : Motion.fieldOpen
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode == mode, app.surfaces.field == mode, !lifted, !self.lifting else { return }
            // Opened in place (a chat shrinking back into it), it is already there.
            if self.inPlace { self.inPlace = false; return }
            if self.inSheet, fresh {
                if self.sheetOrigin != nil {
                    Motion.searchSheet.run { self.backdrop = 1 }
                    self.sheetRiseTravel.set(0)
                    self.sheetRiseTravel.animate(to: Self.morphUnits, Motion.searchSheetMorph) { _ in }
                    return
                }
                Motion.searchSheet.run {
                    self.sheetRise = 1
                    self.backdrop = 1
                }
                return
            }
            if spaces, fresh {
                self.travel(to: 1)
                return
            }
            Motion.fieldBackdrop.run { self.backdrop = 1 }
            Motion.fieldRows.run { self.cards = 1 }
            // With Reduce Motion it fades in where it will stand.
            FieldMotion.morph(grow, {
                self.progress = 1
                self.pill = 1
            }, fade: { self.pill = 1 })
        }
    }

    /// Surfaces closed the field (a tap beside it, a choice, another surface
    /// taking the screen): it lands back on the plate, or, when an answer or
    /// settings grows out of it, only fades under them.
    func didClose(into plate: CGRect) {
        guard shown, !closing, let app, app.surfaces.field == nil else { return }
        closing = true
        log.debug("field closes \(app.surfaces.chat != nil || app.surfaces.settings ? "under a sheet" : "onto the plate", privacy: .public)")
        blurRequest += 1
        if mode == .newTab, isPrivate { text = "" }
        isPrivate = false
        // A chat growing out of a row on the Chats page: the card stays as
        // it is under it, and goes once the chat covers the screen.
        if underChat {
            underChat = false
            landing = nil
            app.surfaces.fieldLanding = false
            // The chat has covered it by then.
            DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.disabled ? 0 : 0.8)) { [weak self] in
                guard let self, app.surfaces.field == nil else { return }
                var quiet = Transaction(animation: nil)
                quiet.disablesAnimations = true
                withTransaction(quiet) {
                    self.backdrop = 0; self.cards = 0; self.contents = 0
                    self.closing = false; self.shown = false; self.mode = nil; self.drag = 0; self.reveal = 1
                    self.endSheet()
                    self.revision &+= 1
                }
            }
            return
        }
        // The tablet input is a dialog, with no phone plate to land in.
        if app.workspace.tabletControls || unfolded {
            landing = nil
            app.surfaces.fieldLanding = false
            backdrop = 0; cards = 0; contents = 0; progress = 0
            closing = false; shown = false; mode = nil; drag = 0; reveal = 1
            revision &+= 1
            return
        }
        let replaced = app.surfaces.chat != nil || app.surfaces.settings
        landing = replaced ? nil : plate
        app.surfaces.fieldLanding = !replaced
        // The spaces folded into the plate already: nothing is left to move.
        if folding, !replaced {
            folding = false
            travel.stop()
            var quiet = Transaction(animation: nil)
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                landing = nil
                app.surfaces.fieldLanding = false
                backdrop = 0; cards = 0; contents = 0; progress = 0
                closing = false; shown = false; mode = nil; drag = 0; reveal = 1
                revision &+= 1
            }
            return
        }
        folding = false
        if !inSheet || replaced {
            Motion.fieldBackdropOut.run { backdrop = 0 }
            Motion.fieldRowsOut.run { cards = 0 }
        }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, app.surfaces.field == nil else { return }
            self.closing = false
            self.shown = false
            self.mode = nil
            self.drag = 0
            self.reveal = 1
            self.cards = 0
            self.endSheet()
            app.surfaces.fieldLanding = false
            self.revision &+= 1
        }
        if inSheet, !replaced {
            landing = nil
            // The plate stands under the sheet from now: page loading shows only there.
            app.surfaces.fieldLanding = false
            sheetRiseTravel.stop()
            if sheetRise >= 0.99 { sheetOrigin = nil }
            if sheetGoesUp, !Motion.disabled, !FieldMotion.reduced {
                sheetGoesUp = false
                sheetLeaveTravel.set(0)
                sheetLeaveTravel.animate(to: Self.morphUnits, Motion.searchSheetUp) { _ in }
                // Not at the spring's rest, which comes long after the eye's: no empty sheet to wait on.
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.searchSheetUp.duration * Metrics.SearchSheet.revealAt) { [weak self] in
                    guard let self, self.closing else { return }
                    Motion.searchSheetReveal.run({
                        self.sheetVeil = 0
                        self.backdrop = 0
                    }, completion: finish)
                }
                return
            }
            Motion.searchSheet.run({
                sheetRise = 0
                backdrop = 0
            }, completion: finish)
            return
        }
        if replaced {
            Motion.fieldContentsOut.run({ contents = 0 }, completion: finish)
        } else {
            // With Reduce Motion it fades where it is.
            if !FieldMotion.reduced { Motion.fieldContentsOut.run { contents = 0 } }
            FieldMotion.morph(Motion.fieldClose, { progress = 0 }, fade: { pill = 0 }, completion: finish)
        }
    }

    /// The control the sheet grows out of: the one tapped, else the plate of
    /// the page in front. The page menu carries its own move into the field.
    private func sheetGrowsOut(of control: CGRect?) -> CGRect? {
        guard let app, app.surfaces.menu == nil else { return nil }
        if let control { return control }
        guard app.browser.tab != nil else { return nil }
        return ChromeGeometry(size: app.screenSize, folded: false, hasNow: app.nowItem != nil).plate
    }

    private func endSheet() {
        inSheet = false
        sheetSpacesReady = false
        sheetPulling = false
        sheetGrab = .none
        sheetRise = 0
        sheetExpand = 0
        sheetTravel.stop()
        sheetRiseTravel.stop()
        sheetLeaveTravel.stop()
        sheetOrigin = nil
        sheetLeave = 0
        sheetVeil = 1
        sheetGoesUp = false
    }

    /// Closes the field without choosing: the words stay as the draft.
    func close() {
        guard let app, app.surfaces.field != nil else { return }
        // The spaces at rest go back into the plate the way a finger takes them down.
        if !inSheet, !app.workspace.tabletControls, !unfolded, canLower, !lifting, !Motion.disabled, !FieldMotion.reduced {
            if !folding { fold() }
            return
        }
        Motion.fieldClose.run { app.surfaces.closeField() }
    }

    // MARK: - typing

    /// The words changed in the input.
    func typed(_ new: String) {
        guard new != text || showsAddress else { return }
        text = new
        showsAddress = false
        SearchSuggest.shared.ask(new, engine: searchSettings.searchSelection.engine,
                                 local: FieldAnswerPolicy.keepsLocal(new))
        keep()
        countOnThisPage()
    }

    private func countOnThisPage() {
        onThisPageCount?.cancel()
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app, mode == .address, let id = pageID, words.count >= 2 else { onThisPage = nil; return }
        onThisPageCount = Task { @MainActor [weak self, weak app] in
            try? await Task.sleep(for: .milliseconds(Motion.disabled ? 0 : 150))
            guard !Task.isCancelled, let app else { return }
            let count = await app.pages.matches(of: words, in: id)
            guard !Task.isCancelled, let self, self.text.trimmingCharacters(in: .whitespacesAndNewlines) == words else { return }
            self.onThisPage = count > 0 ? (words, count) : nil
        }
    }

    /// A finger put the cursor inside the selected address: it is words to
    /// edit in place now.
    func editAddress() {
        guard showsAddress else { return }
        showsAddress = false
        keep()
    }

    /// ✕: the words go, the field stays.
    func clear() {
        text = ""
        showsAddress = false
        keep()
        focusRequest += 1
    }

    /// Puts words in the field, as Ask on the page's card does.
    func put(_ words: String) {
        text = words
        showsAddress = false
        keep()
        focusRequest += 1
    }

    /// A choice was made: the draft is forgotten.
    func forget() {
        switch mode {
        case .address: if let pageID { drafts[pageID] = nil }
        case .newTab: newTabDraft = ""
        case nil: break
        }
        text = ""
    }

    private func keep() {
        // Private words are never kept: the eyes shut, or a private tab's own.
        guard !isPrivate, !pageIsPrivate else { return }
        switch mode {
        case .address:
            guard let pageID else { return }
            let words = text.trimmingCharacters(in: .whitespaces)
            drafts[pageID] = words.isEmpty || words == pageAddress ? nil : text
        case .newTab:
            newTabDraft = text
        case nil:
            break
        }
    }

    /// The draft waiting at a tab, for tests and the column.
    func draft(for id: Tab.ID) -> String? { drafts[id] }
    var newTabWords: String { newTabDraft }

    /// Forgets a closed tab's draft.
    func forgetDraft(of id: Tab.ID) { drafts[id] = nil }

    // MARK: - the eyes

    /// The eyes shut (Incognito) or open: the lids, the word, a soft click.
    func setPrivate(_ on: Bool) {
        guard on != isPrivate else { return }
        Haptics.play(.soft, reason: Haptics.Reason.eyes)
        Motion.eyes.run { isPrivate = on }
        focusRequest += 1
    }

    /// The field is gone: the eyes open again for the next New Tab.
    func endPrivate() { isPrivate = false }

    // MARK: - what the field shows

    /// Where the words are typed, for the rows.
    var place: WordsPlace {
        switch mode {
        case .newTab: isPrivate ? .privateTab : .newTab
        // The plate's field with its eyes shut is what + opens with them: a private tab of its own.
        default: isPrivate ? .privateTab : (pageIsPrivate ? .privatePage : .page)
        }
    }

    /// The words the rows read: none while the address shows.
    var words: String { showsAddress ? "" : text }

    // MARK: - the keyboard

    private func keyboardMoved(_ end: CGRect?) {
        // The keyboard of a chat in its cover over the Chats page isn't this
        // field's: the page under the cover stays as it was.
        guard let end, app?.chatSheet.page == nil else { return }
        let height = app?.workspaceKeyboardHeight(end) ?? 0
        // A tap on the resting field: it rides the keyboard from here on.
        if height > 80, resting, !sheetPulling {
            if inSheet { collapseSheet() } else {
                Motion.keyboardFollow.run { resting = false }
                enterSheetFromSpaces()
            }
        }
        // Gone, the field keeps the last height to land from.
        guard height > 80, abs(height - keyboard) > 0.5 else { return }
        Motion.keyboardFollow.run { self.keyboard = height }
    }

    /// The keyboard went with New Tab still up (Settings over the spaces, a
    /// rename asked over them): the field goes back to the foot, the spaces
    /// down to the screen's, or they stand on a keyboard no longer there.
    /// A chat over them owns the keyboard; one out of a card rests the field
    /// itself (`rest()`), and the field closing lands from where it is.
    private func keyboardWentAway() {
        guard let app, app.chatSheet.page == nil, !app.chatSheet.shown else { return }
        rest()
    }

    /// The keyboard put away by the person (Chats' list scrolled, its gaps
    /// tapped, Search pressed, the pages turned to Chats): the words and what
    /// they found stay, the field rests at the foot until it is tapped again.
    func putKeyboardAway() {
        blur()
        rest()
    }

    /// The spaces without the keyboard, from New Tab or the address field:
    /// the input rests at the screen's foot until tapped again.
    func rest() {
        guard let app, shown, !closing, app.surfaces.field == mode, !resting else { return }
        guard mode == .newTab || (mode == .address && app.browser.spaces.contains { !$0.isPrivate }) else { return }
        Motion.keyboardFollow.run { resting = true }
        if chatsSearch, !text.isEmpty { text = "" }
        // Without its keyboard the low sheet has nothing to stand on.
        if inSheet, !sheetPulling { expandSheet() }
    }

    /// Stands for "a link is on the clipboard" until it is read on a tap:
    /// reading it asks the person, so it is read only when they choose it.
    static let pasteboardMarker = URL(string: "yab-clipboard://link")!
}
