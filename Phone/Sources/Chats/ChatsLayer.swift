import SwiftUI
import UIKit

/// Answers, chats and a task's chat: one sheet over the page
/// (M5), and the Now line while it holds a hidden answer or chat. Every
/// shape the sheet takes comes from its pose (ChatSheet.pose), animated by
/// the flow in ChatFlow.swift.
struct ChatsLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var sheet = app.chatSheet
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                PosedSheet(pose: sheet.pose, flown: sheet.flown, screen: geo.size)
                // Add to Chat, over the chat, out of its field's +. A chat in
                // its cover has the tray in the cover (ChatPageCover).
                if sheet.shown, sheet.drawnHere {
                    let width = app.workspace.expanded ? min(Metrics.Workspace.conversation, geo.size.width) : geo.size.width
                    AttachTrayLayer(screen: CGSize(width: width, height: geo.size.height))
                        .frame(width: width, height: geo.size.height)
                        .offset(x: geo.size.width - width)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { app.surfaces.parkedLineLent = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            keyboardMoved(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardTo(0)
        }
        .onChange(of: app.surfaces.chat) { _, route in adopt(route) }
        // Going into a chat is where notifications start to matter: an
        // agent's answer or an assistant's question comes later.
        .onChange(of: app.chatSheet.shown) { _, shown in
            if shown { app.sync.askForAssistantNotifications() } else { app.chatSheet.attachMenu = false }
        }
        .onChange(of: app.chatSheet.chatID) { _, _ in app.chatSheet.attachMenu = false }
        .onChange(of: app.browser.macAsleep) { _, asleep in
            if asleep { app.chatSheet.macFellAsleep() } else { app.macWoke() }
        }
        // A chat in its cover asks in the cover, above it.
        .renameChatAlert(app: app, when: sheet.page == nil)
        .deleteChatQuestion(app: app, when: sheet.page == nil)
    }

    /// The keyboard's top over the screen's bottom: the chat's foot rides on it.
    private func keyboardMoved(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let height = app.workspaceKeyboardHeight(end)
        keyboardTo(height)
    }

    private func keyboardTo(_ height: CGFloat) {
        let sheet = app.chatSheet
        guard abs(sheet.keyboard - height) > 0.5 else { return }
        if sheet.info {
            // Info's own keyboard (Rename's alert) isn't the chat's: the foot
            // under the cover stays put rather than lay out a long chat on
            // every frame of it. Only the chat's keyboard going away lands, at once.
            if height < sheet.keyboard { sheet.keyboard = height; sheet.pose.k = sheet.shown ? Double(height) : 0 }
            return
        }
        (height > sheet.keyboard ? Motion.keyboardUp : Motion.keyboardDown).run {
            sheet.keyboard = height
            sheet.pose.k = sheet.shown ? Double(height) : 0
        }
    }

    /// Someone else opened the sheet through Surfaces (the Now line's task, the
    /// island): show what they asked for, grown out of their origin.
    private func adopt(_ route: Surfaces.ChatRoute?) {
        guard route != app.sheetRoute else { return }
        let origin = app.surfaces.chatOrigin
        switch route {
        case nil:
            if app.chatSheet.shown { app.hideSheet() }
        case let .answer(question, aboutPage):
            // About Surfaces.chatPage when one was asked about, else the tab in front.
            app.ask(question, page: aboutPage ? (app.surfaces.chatPage ?? app.browser.tab) : nil, from: origin)
        case let .chat(id):
            app.openChat(id, from: origin)
        case .task:
            // A task's chat is drawn by TasksLayer, right over this one.
            break
        case .newChat:
            app.newChat(from: origin, about: app.surfaces.chatPage)
        }
    }
}

/// The sheet in one pose: everything drawn from the pose's numbers, so every
/// in-between frame is the prototype's own.
private struct PosedSheet: View, Animatable {
    @Environment(AppModel.self) private var app
    var pose: SheetPose
    var flown: Double
    let screen: CGSize

    var animatableData: AnimatablePair<SheetPose, Double> {
        get { AnimatablePair(pose, flown) }
        set { pose = newValue.first; flown = newValue.second }
    }

    var body: some View {
        let sheet = app.chatSheet
        let width = app.workspace.expanded ? min(Metrics.Workspace.conversation, screen.width) : screen.width
        let offset = screen.width - width
        let surface = CGSize(width: width, height: screen.height)
        let geometry = SheetGeometry(screen: surface, pose: pose, origin: sheet.origin.map { shifted($0, by: -offset) },
                                     now: shifted(SheetGeometry.nowShape(screen: screen, folded: app.chrome.folded), by: -offset),
                                     still: Motion.reduced && !Motion.disabled,
                                     tray: sheet.mode == .chat,
                                     info: sheet.info, column: app.workspace.expanded)
        ZStack(alignment: .topLeading) {
            ParkedNowLine(geometry: geometry, screen: screen)
            // A chat in its cover is drawn there (ChatPageCover), not here,
            // once the cover stands (a chat handed over to it stays drawn
            // here until then: no frame of the page between).
            if sheet.shown, sheet.drawnHere {
                // The page dimmed, and its chrome with it (the prototype's
                // scrim stands over both): a tap hides the answer or chat
                // into the Now line.
                Color.black
                    .opacity(geometry.scrim)
                    .contentShape(Rectangle())
                    .onTapGesture { tapOutside() }
                    .accessibilityHidden(true)
                SheetFrame(geometry: geometry, screen: surface)
                    .offset(x: offset)
            }
            if let flight = sheet.flight, sheet.drawnHere {
                FlyingWords(flight: flight, progress: flown, target: flightTarget(flight, geometry: geometry).offsetBy(dx: offset, dy: 0))
            }

        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }

    private func shifted(_ shape: SheetShape, by x: CGFloat) -> SheetShape {
        var shape = shape
        shape.rect.origin.x += x
        return shape
    }

    private func tapOutside() {
        let sheet = app.chatSheet
        if sheet.moreMenu { Motion.menuClose.run { sheet.moreMenu = false }; return }
        app.park()
    }

    /// The first question lands where the answer rests; later questions
    /// land in their own laid-out bubble. The interpolated pose carries
    /// their destination along when the height or keyboard is moving.
    private func flightTarget(_ flight: ChatSheet.Flight, geometry: SheetGeometry) -> CGRect {
        let sheet = app.chatSheet
        let box = geometry.current.rect
        if sheet.mode == .answer, flight.bubble == 0 {
            // The prototype sends the first question to the answer at rest.
            // Its height and keyboard still follow this frame's pose.
            var landing = geometry
            landing.pose.o = 0
            landing.pose.p = 0
            landing.pose.e = 0
            landing.pose.drag = 0
            let rest = landing.rest.rect
            let bubble = BubbleLayout(flight.text).size
            let top = rest.minY + Metrics.Column.grabTop + Metrics.Column.grabHeight + landing.headHeight + Metrics.Chat.turnsTop
            return CGRect(x: rest.maxX - landing.restGutter - bubble.width, y: top, width: bubble.width, height: bubble.height)
        }
        guard let bubble = sheet.bubbleFrames[flight.bubble] else { return flight.from }
        return bubble.offsetBy(dx: box.minX, dy: box.minY)
    }
}

/// The sheet: its card (an answer or a chat), laid out in the shape the
/// pose says (the head on its top, the foot on its bottom).
private struct SheetFrame: View {
    @Environment(AppModel.self) private var app
    let geometry: SheetGeometry
    let screen: CGSize

    var body: some View {
        let sheet = app.chatSheet
        let current = geometry.current
        let box = current.rect
        let opaque = geometry.opaque
        let under = geometry.underKeyboard
        ZStack(alignment: .topLeading) {
            if under > 0.5 {
                // Behind the keyboard the sheet goes on: nothing of the page
                // shows through the keyboard's glass under a chat.
                Color.clear
                .background(opaque ? ChatInk.list : .clear)
                .frame(width: box.width, height: under)
                .chatGlass(in: Rectangle(), enabled: !opaque)
                .offset(x: box.minX, y: box.maxY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            ZStack(alignment: .topLeading) {
                if let id = sheet.chatID, let chat = app.chats.chat(id) {
                    // Faded as one, as CSS fades its card: white words on
                    // the ink stay white while the bubble pales.
                    ChatViewport(owner: chat.id) {
                        ChatCardContent(chat: chat, geometry: geometry)
                    }
                    .frame(width: box.width, height: box.height, alignment: .topLeading)
                    .compositingGroup()
                    .opacity(geometry.words)
                }
            }
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            .background(opaque ? ChatInk.list : .clear)
            .clipShape(current.shape)
            .chatGlass(in: current.shape, enabled: !opaque)
            .shadow(color: Ink.shadow.opacity(geometry.isPage ? 0 : (opaque ? 0.35 : 0.16)), radius: 20, y: opaque ? 10 : -10)
            .overlay(current.shape.strokeBorder(Ink.outline.opacity(geometry.isPage ? 0 : 0.06), lineWidth: 0.5).allowsHitTesting(false))
            .offset(x: box.minX, y: box.minY)
        }
        .opacity(geometry.sheetOpacity)
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .background(alignment: .topLeading) { measure }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.sheet")
        .accessibilityAction(.escape) { app.escapeSheet() }
    }

    /// An answer's turns, laid out out of sight where the answer rests: the
    /// answer takes their height whatever shape the sheet has on its way.
    @ViewBuilder
    private var measure: some View {
        let sheet = app.chatSheet
        if sheet.mode == .answer, let id = sheet.chatID, let chat = app.chats.chat(id) {
            TurnsView(chat: chat, full: false, arrival: nil, flyingInto: nil, task: nil, still: true)
                .frame(width: geometry.restTurnsWidth)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { app.turnsMeasured($0) }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The Now line while it holds a hidden answer or chat: the chrome lends it
/// here, where the sheet folds into it, a tap grows the sheet back and a
/// flick aside lets it go.
private struct ParkedNowLine: View {
    @Environment(AppModel.self) private var app
    let geometry: SheetGeometry
    let screen: CGSize

    private typealias R = Metrics.Chats

    var body: some View {
        let sheet = app.chatSheet
        if let item = parkedItem, app.nowItem?.kind == .parked || sheet.shown {
            let layout = ChromeGeometry(size: screen, folded: app.chrome.folded, hasNow: true)
            let rect = layout.now
            let dx = sheet.lineDrag + sheet.lineGone
            let opacity = sheet.shown ? geometry.nowOpacity : 1
            let fade = sheet.lineGone != 0 ? 1 - min(1, abs(sheet.lineGone) / R.letGoFlight) : SheetGeometry.clamp(1 - Double(abs(sheet.lineDrag) / R.letGoFade))
            let covered = app.surfaces.coversChrome || app.surfaces.settings
            NowLineView(item: item, folded: app.chrome.folded) { _ in
                if !sheet.shown { app.restoreParked() }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: dx)
            .opacity(opacity * fade * (covered ? 0 : app.surfaces.chromeOpacity))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(!sheet.shown && !covered)
            .gesture(DragGesture(minimumDistance: 7).onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                var still = Transaction(animation: nil)
                still.disablesAnimations = true
                withTransaction(still) { sheet.lineDrag = value.translation.width }
            }.onEnded { value in
                let dx = value.translation.width
                let vx = value.velocity.width
                if abs(dx) > R.letGoDistance || abs(vx) > R.letGoVelocity {
                    sheet.lineGone = sheet.lineDrag
                    sheet.lineDrag = 0
                    app.letGoParked(direction: dx == 0 ? vx : dx)
                } else {
                    Motion.letGoBack.run { sheet.lineDrag = 0 }
                }
            })
            .accessibilityIdentifier("chats.now")
            .accessibilityAction(named: "Let Go") { app.letGoParked(direction: 1) }
        }
    }

    /// The hidden answer's or chat's line: Sparkle for an answer from this
    /// iPhone, the agent's face for Claude's and for chats.
    private var parkedItem: NowItem? {
        guard var item = app.chats.parkedItem, let parked = app.chats.parked, let chat = app.chats.chat(parked.chat) else { return nil }
        if parked.mode == .answer, chat.by == .claude { item.icon = .face }
        return item
    }
}

/// The words flying from the field into their bubble: one line, as typed,
/// its size, font (17 to 15.5) and padding going to the bubble's own; the
/// bubble's accent comes in over the flight, the words turn white at half,
/// its tail grows out of its foot with it. In the last tenth they take the
/// bubble's own lines, so the bubble takes over where they land.
struct FlyingWords: View {
    let flight: ChatSheet.Flight
    let progress: Double
    let target: CGRect

    private typealias C = Metrics.Chat

    var body: some View {
        let k = progress
        let a = flight.from
        let rect = CGRect(x: SheetGeometry.lerp(a.minX, target.minX, k), y: SheetGeometry.lerp(a.minY, target.minY, k),
                          width: SheetGeometry.lerp(a.width, target.width, k), height: SheetGeometry.lerp(a.height, target.height, k))
        let ink = SheetGeometry.clamp((k - 0.15) / 0.5)
        let size = SheetGeometry.lerp(flight.fontSize, C.text, k)
        // The tail and its room grow with the ink, so the words in the field
        // aren't cut by a room they don't have yet.
        let shape = MessageBubble(mine: true, grown: CGFloat(ink))
        let landing = k > 0.9
        Text(landing ? BubbleLayout(flight.text).text : flight.text)
            .font(.system(size: size))
            .foregroundStyle(ink > 0.5 ? Color.white : Ink.black)
            .cssLineHeight(landing ? C.bubbleLineHeight : 1, size: size)
            // Never cut short with an ellipsis: the bubble's edge clips them.
            .fixedSize()
            .padding(.leading, SheetGeometry.lerp(flight.padding, C.bubblePadding.leading, k))
            .frame(width: rect.width, height: rect.height, alignment: .leading)
            .background(shape.fill(Color.accentColor.opacity(ink)))
            .clipShape(shape)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// ⋯ in a chat: Pin, Rename, Unread, Copy Answer, Open on the Mac, Archive, Delete.
struct ChatMoreMenu: View {
    @Environment(AppModel.self) private var app
    /// Whose menu: a task's chat says its own (Tasks/TasksLayer); nil is the sheet's.
    let chat: Chat.ID?

    init(chat: Chat.ID? = nil) { self.chat = chat }

    var body: some View {
        let kept = (chat ?? app.chatSheet.chatID).flatMap { app.chats.chat($0) }
        let pinned = kept?.pinned ?? false
        VStack(spacing: 0) {
            MenuRow(words: pinned ? "Unpin Chat" : "Pin Chat", glyph: pinned ? .pinSlash : .pin, first: true) { app.pickMore(.pin, chat: chat) }
            MenuRow(words: "Rename Chat", glyph: .pencil) { app.pickMore(.rename, chat: chat) }
            MenuRow(words: kept?.unread == true ? "Mark as Read" : "Mark as Unread", glyph: kept?.unread == true ? .yabChat : .yabChatDot) { app.pickMore(.unread, chat: chat) }
            MenuRow(words: "Copy Answer", glyph: .yabCopyframeText) { app.pickMore(.copy, chat: chat) }
            if app.canOpenChatOnMac { MenuRow(words: "Open on \(app.macName)", glyph: .yabLaptopRight) { app.pickMore(.mac, chat: chat) } }
            MenuRow(words: "Archive Chat", glyph: .yabArchive) { app.pickMore(.archive, chat: chat) }
            if let id = kept?.id, app.canDelete(id) {
                MenuRow(words: "Delete Chat\u{2026}", glyph: .trash) { app.pickMore(.delete, chat: chat) }
            }
            if chat == nil { MenuRow(words: "Chat Info", glyph: .infoCircle) { app.pickMore(.info) } }
        }
        .padding(Metrics.Menu.padding)
        .frame(width: Metrics.Menu.Chat.width)
        .glassPlate(RoundedRectangle(cornerRadius: Metrics.Menu.Chat.radius, style: .continuous), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.menu")
        .accessibilityAction(.escape) { app.escapeSheet() }
    }
}

/// A menu's row: the word left, the glyph right, a hairline between rows.
struct MenuRow: View {
    let words: String
    let glyph: MacGlyph
    var first = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(words)
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ChatGlyph(mac: glyph, size: Metrics.Menu.icon)
            }
            .padding(.horizontal, 12)
            .frame(height: Metrics.Menu.row)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if !first { Rectangle().fill(ChatInk.gray(0.12)).frame(height: 0.5) }
            }
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityIdentifier("menu.\(words)")
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ChatInk.fill(configuration.isPressed ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Delete Chat, asked first: by the layer that stands in front, as Rename.
extension View {
    func deleteChatQuestion(app: AppModel, when active: Bool) -> some View {
        let sheet = app.chatSheet
        let question = sheet.deleting.map { app.deleteQuestion($0) }
        return confirmationDialog(question?.title ?? "",
                                  isPresented: Binding(get: { active && sheet.deleting != nil },
                                                       set: { if !$0 { sheet.deleting = nil } }),
                                  titleVisibility: .visible) {
            Button("Delete Chat", role: .destructive) {
                if let id = sheet.deleting { app.deleteChat(id) }
                sheet.deleting = nil
            }
        } message: {
            if let detail = question?.detail { Text(detail) }
        }
    }
}

/// Rename Chat, asked in words: by the layer that stands in front (the
/// sheet's, or a chat's cover over it), so only one ever asks.
extension View {
    func renameChatAlert(app: AppModel, when active: Bool) -> some View {
        @Bindable var sheet = app.chatSheet
        return alert("Rename Chat", isPresented: Binding(get: { active && sheet.renaming != nil },
                                                         set: { if !$0 { sheet.renaming = nil } })) {
            TextField("Name", text: $sheet.renameText)
            Button("Cancel", role: .cancel) { sheet.renaming = nil }
            Button("Rename") {
                if let id = sheet.renaming { app.rename(id, to: sheet.renameText) }
                sheet.renaming = nil
            }
        }
    }
}
