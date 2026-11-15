import Foundation
import Observation
import SwiftUI

/// The one sheet over the page that holds a quick answer, a conversation
/// and a task's chat, and everything it is doing: its shape (a pose that
/// animates), the chat in it, the menu, the words flying into their bubble. AppModel keeps one (app.chatSheet); the flow in ChatFlow.swift
/// changes it, the views in this folder draw it.
@MainActor
@Observable
final class ChatSheet {
    enum Mode: Sendable, Equatable {
        /// A quick answer at its own height.
        case answer
        /// A conversation at full height.
        case chat
    }

    // MARK: - what is up

    /// The sheet is on screen (growing, standing, or folding away).
    var shown = false
    /// Native gesture callbacks are scoped to this navigation, even for the same chat.
    var navigationGeneration = UUID()
    /// The chat in the card.
    var chatID: Chat.ID?
    var mode: Mode = .answer
    /// The conversation's own screen, as in the Mac's Cmd+J panel.
    var info = false
    /// Each native Info presentation owns its own dismissal and actions.
    var infoGeneration: UUID?
    var infoReturnFocus = false
    /// The pose: every shape the sheet takes, animated.
    var pose = SheetPose.gone
    /// What it grows out of, in screen points (o).
    var origin: SheetShape?

    // MARK: - chats this session only

    /// New chats nothing has been asked in yet (Chat.ephemeral keeps them,
    /// and quick answers, out of the Chats page).
    var fresh: Set<Chat.ID> = []
    /// The page each chat was asked about, for its pill and the model.
    var pages: [Chat.ID: Tab.ID] = [:]
    /// A chat can be about a page before it becomes a browser tab.
    var pageSources: [Chat.ID: Tab] = [:]
    /// Ideas over a new chat's field, by the tab they are for.
    var ideas: [Tab.ID: [String]] = [:]
    /// Questions waiting for the Mac to wake, by chat.
    var waitingForMac: [Chat.ID: String] = [:]
    /// A real on-device answer owns its question until success or Mac fallback.
    var answeringHere: Set<Chat.ID> = []
    /// Reading page context before a real question is written to sync.
    var sendingToMac: Set<Chat.ID> = []

    /// A new Mac chat gets its real id after the Mac accepts the send.
    func reidentify(_ old: Chat.ID, as new: Chat.ID) {
        if chatID == old { chatID = new }
        if let page = pages.removeValue(forKey: old) { pages[new] = page }
        if let page = pageSources.removeValue(forKey: old) { pageSources[new] = page }
        if fresh.remove(old) != nil { fresh.insert(new) }
        if let question = waitingForMac.removeValue(forKey: old) { waitingForMac[new] = question }
        if let files = attached.removeValue(forKey: old) { attached[new] = files }
        if let pick = picks.removeValue(forKey: old) { picks[new] = pick }
        if sendingToMac.remove(old) != nil { sendingToMac.insert(new) }
        if answeringHere.remove(old) != nil { answeringHere.insert(new) }
        if renaming == old { renaming = new }
        if deleting == old { deleting = new }
        if let frame = rowFrames.removeValue(forKey: old) { rowFrames[new] = frame }
        if let page, page.chat == old { self.page = ChatPagePresentation(id: page.id, chat: new, source: page.source, project: page.project) }
    }

    // MARK: - the field and the keyboard

    var draft = "" {
        didSet { if let chatID { onDraftChange?(chatID, draft) } }
    }
    @ObservationIgnored var onDraftChange: ((Chat.ID, String) -> Void)?
    /// Photos and files waiting in a chat's field (ChatAttachments).
    var attached: [Chat.ID: [ChatAttachment]] = [:]
    /// + opened Add to Chat (AttachTray), on this page of it.
    var attachMenu = false
    var attachPage: AttachPage = .main
    /// Where + stands on screen: the tray grows out of it and goes back.
    @ObservationIgnored var attachOrigin: CGRect = .zero
    /// A new one each time the tray opens, so late camera callbacks from an
    /// earlier tray do nothing.
    var attachGeneration = UUID()
    /// The system's pickers the tray hands over to.
    var attachCamera = false
    var attachFiles = false
    var attachLibrary = false
    /// The model and effort picked for a chat's next words.
    var picks: [Chat.ID: ModelChoice] = [:]
    /// The chat's field has the keyboard.
    var focused = false
    /// The keyboard's top, as a height over the screen's bottom.
    var keyboard: CGFloat = 0

    /// The chat's field on screen: words sent fly from it.
    @ObservationIgnored var fieldFrame: CGRect = .zero

    /// Words flying from a field into their bubble.
    var flight: Flight?
    /// 0 at the field, 1 in the bubble.
    var flown: Double = 1

    struct Flight: Equatable {
        var text: String
        /// Where the words start, in screen points.
        var from: CGRect
        var fontSize: CGFloat
        var padding: CGFloat
        /// The bubble that will hold them, by its index among the questions.
        var bubble: Int
    }

    /// Questions' ink bubbles in the card, by index, in the card's own
    /// points: where words sent in a chat land.
    @ObservationIgnored var bubbleFrames: [Int: CGRect] = [:]
    /// The newest turns coming in (fade and rise 6 points).
    var arrival: Arrival?

    // MARK: - the menus

    /// ⋯ in the chat's head.
    var moreMenu = false

    /// Rename, asked in words.
    var renaming: Chat.ID?
    var renameText = ""
    /// Delete Chat, asked first.
    var deleting: Chat.ID?

    // MARK: - rows on New Tab's Chats page

    /// Rows' frames in screen points, as laid out (only those on screen).
    @ObservationIgnored var rowFrames: [Chat.ID: CGRect] = [:]
    /// A chat opened from its card on New Tab's Chats page: it stands in a
    /// native full-screen cover that zooms out of the card and back into it
    /// (ChatPageCover), over the Chats page, which stays as it was.
    var page: ChatPagePresentation?
    /// The page's cover is on screen (it appeared).
    var pageOnScreen = false
    /// The page was handed a chat from the sheet to take back into its card
    /// (ChatFlow.openHistory): it closes as soon as it stands.
    @ObservationIgnored var pageClosesOnAppear = false
    /// The page's cover is zooming back into its card: the sheet is put
    /// away a moment later, so that change can't take the zoom's animation.
    var pageLeaving = false
    /// The sheet's layer draws the chat (not its cover, standing or leaving).
    /// A chat handed from the sheet to a cover (‹ in a chat from the Now
    /// line): the sheet keeps drawing it until the cover stands in its place.
    var pageHandover = false
    /// The sheet draws the chat itself: never for a page opened from a card,
    /// even the frame before its cover comes (that frame flashed the whole chat).
    var drawnHere: Bool { !pageLeaving && (page == nil || (pageHandover && !pageOnScreen)) }

    // MARK: - the Now line, while it holds this sheet

    /// The line under a finger flicking it away.
    var lineDrag: CGFloat = 0
    /// Flicked away: flying off to this side.
    var lineGone: CGFloat = 0

    // MARK: - who answers

    @ObservationIgnored let answerers: Answerers
    /// The prototype's clock for new chats in test worlds: 18:43, 18:44 …
    @ObservationIgnored private var clock = 42
    @ObservationIgnored private let testClock: Bool

    init(answerers: Answerers? = nil, options: LaunchOptions = .current) {
        self.answerers = answerers ?? Answerers.forLaunch(options, macAsleep: false)
        testClock = options.isTestRun
    }

    /// A new chat's id: unique on every device and across launches, so a
    /// chat kept or synced never meets another with its id.
    func nextID() -> Chat.ID { UUID().uuidString }

    /// When the Mac went to sleep, as a chat waiting for it says: noted when
    /// this iPhone first learns it (until sync brings the Mac's own time),
    /// the prototype's 18:52 in test worlds. Nil again once it wakes.
    @ObservationIgnored private var macAsleepAt: String?

    func macAsleepSince() -> String {
        if let at = macAsleepAt { return at }
        let at = testClock ? "18:52" : Self.hourMinute(Date())
        macAsleepAt = at
        return at
    }

    /// This iPhone just learned the Mac went to sleep.
    func macFellAsleep() { _ = macAsleepSince() }
    func macWoke() { macAsleepAt = nil }

    private static func hourMinute(_ date: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "HH:mm"
        return format.string(from: date)
    }

    /// The time a chat made now shows: the prototype's 18:43, 18:44 … in
    /// test worlds, the clock for people.
    func now() -> String {
        if testClock {
            clock = min(59, clock + 1)
            return String(format: "18:%02d", clock)
        }
        return Self.hourMinute(Date())
    }

    // MARK: - reading

    /// A chat is listed on the Chats page: not archived, not a quick answer.
    func isListed(_ chat: Chat) -> Bool { !chat.archived && !chat.ephemeral }
}
