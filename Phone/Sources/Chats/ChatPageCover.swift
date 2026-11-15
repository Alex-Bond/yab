import SwiftUI
import UIKit

/// A chat opened from its card on New Tab's Chats page, and the navigation
/// that opened it. The cover is UIKit's: its zoom out of the card and back,
/// the pull down anywhere, the edge swipe, the cancel and the rubber band
/// are the system's, as Chat Info's are (ChatInfoPage).
struct ChatPagePresentation: Identifiable, Equatable {
    /// The navigation it belongs to (ChatSheet.navigationGeneration).
    let id: UUID
    let chat: Chat.ID
    /// The matched source it zooms out of and back into: the chat's card
    /// (its id) or New Chat's row (`ChatPagePresentation.newChat`).
    let source: String
    /// The open project it stands over, opened from there; nil over the
    /// Chats page. Each presents its own (ChatsPage, ProjectPage).
    var project: ChatProject.ID? = nil

    static let newChat = "newtab.chats.new"

    @MainActor
    func isCurrent(in app: AppModel) -> Bool {
        let sheet = app.chatSheet
        return sheet.shown && sheet.page == self && sheet.chatID == chat && sheet.mode == .chat
            && app.chats.chat(chat) != nil && app.chats.isVisible(chat)
            && !app.privateContentBlocked && !app.privateLock.presentsPrompt
    }

    /// While UIKit zooms it back into its card (no longer current) it keeps
    /// its words; only privacy blacks it out.
    @MainActor
    func mayShow(in app: AppModel) -> Bool {
        if isCurrent(in: app) { return true }
        return app.chats.chat(chat) != nil && app.chats.isVisible(chat)
            && !app.privateContentBlocked && !app.privateLock.presentsPrompt
    }

    @MainActor
    static func binding(app: AppModel, project: ChatProject.ID? = nil) -> Binding<Self?> {
        let captured = app.chatSheet.page.flatMap { $0.project == project ? $0 : nil }
        return Binding(get: { captured.flatMap { $0.isCurrent(in: app) ? $0 : nil } }, set: { newValue in
            // A cancelled pull writes nothing. A finished old dismissal can't
            // close a newer page, or the sheet's chat.
            if newValue == nil, let captured { app.closeChatPage(captured) }
        })
    }
}

/// The chat as a page in its cover: the sheet's own chat view (ChatCardContent
/// in its ChatViewport, the turns, the foot with its field), laid out as a
/// full page with no pose (SheetGeometry.page), its foot on the keyboard.
/// What the sheet's layer draws over a chat comes along: Add to Chat, the
/// words flying into their bubble, Rename's question, the privacy curtain.
struct ChatPageCover: View {
    @Environment(AppModel.self) private var app
    let presentation: ChatPagePresentation

    var body: some View {
        let sheet = app.chatSheet
        let current = presentation.isCurrent(in: app)
        // A new chat the Mac has named since keeps its cover (same id).
        let id = sheet.page?.id == presentation.id ? sheet.page?.chat ?? presentation.chat : presentation.chat
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if presentation.mayShow(in: app), let chat = app.chats.chat(id) {
                    PageChat(chat: chat, keyboard: Double(sheet.keyboard), screen: geo.size)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("chat.sheet")
                } else if app.privateContentBlocked || app.privateLock.presentsPrompt || app.chats.chat(id).map({ !app.chats.isVisible($0.id) }) == true {
                    // A modal is above RootView: it keeps the same private
                    // boundary itself while UIKit takes a retired cover away.
                    Color.black.accessibilityLabel("Private content hidden")
                }
                if current {
                    AttachTrayLayer(screen: geo.size)
                    if let flight = sheet.flight {
                        FlyingWords(flight: flight, progress: sheet.flown,
                                    target: sheet.bubbleFrames[flight.bubble] ?? flight.from)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(ChatInk.list.ignoresSafeArea())
        .overlay { ChatPagePrivacyCurtain(app: app, chat: presentation.chat).ignoresSafeArea().accessibilityHidden(false) }
        .ignoresSafeArea()
        .renameChatAlert(app: app, when: current)
        .deleteChatQuestion(app: app, when: current)
        .accessibilityAction(.escape) { app.escapeSheet() }
        // Nothing half-done is pulled away: Add to Chat, ⋯, Rename, Delete.
        .interactiveDismissDisabled(!current || sheet.attachMenu || sheet.moreMenu || sheet.renaming != nil || sheet.deleting != nil)
        .onAppear {
            guard sheet.page == presentation else { return }
            sheet.pageOnScreen = true
            // A chat handed over from the sheet goes on into its card.
            if sheet.pageClosesOnAppear {
                sheet.pageClosesOnAppear = false
                // A few frames in, so UIKit has the cover and its source settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if sheet.page == presentation { app.closeChatPage(presentation) }
                }
            }
        }
        .transaction { if !current { $0.animation = nil } }
    }
}

/// The page's chat in one keyboard height: interpolated frame by frame as
/// the keyboard moves (ChatsLayer's own Motion), as the sheet's pose is.
private struct PageChat: View, Animatable {
    let chat: Chat
    var keyboard: Double
    let screen: CGSize

    var animatableData: Double {
        get { keyboard }
        set { keyboard = newValue }
    }

    var body: some View {
        let geometry = SheetGeometry.page(screen: screen, keyboard: keyboard)
        let box = geometry.current.rect
        ChatViewport(owner: chat.id) {
            ChatCardContent(chat: chat, geometry: geometry)
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .background(ChatInk.list)
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }
}

/// RootController's privacy cover is below a modal: this one covers the chat
/// before the system snapshots its window (ChatInfoPrivacyView).
private struct ChatPagePrivacyCurtain: UIViewRepresentable {
    let app: AppModel
    let chat: Chat.ID
    func makeUIView(context: Context) -> ChatInfoPrivacyView { ChatInfoPrivacyView() }
    func updateUIView(_ view: ChatInfoPrivacyView, context: Context) { view.configure(app: app, chat: chat) }
    static func dismantleUIView(_ view: ChatInfoPrivacyView, coordinator: ()) { view.retire() }
}
