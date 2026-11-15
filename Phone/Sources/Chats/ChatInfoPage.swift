import SwiftUI
import UIKit

/// A native cover carries the chat and generation that opened it. UIKit's zoom
/// transition owns the interactive shrink, cancellation and reverse animation.
struct ChatInfoPresentation: Identifiable, Equatable {
    let id: UUID
    let chat: Chat.ID

    @MainActor
    func isCurrent(in app: AppModel) -> Bool {
        let sheet = app.chatSheet
        return sheet.shown && sheet.info && sheet.chatID == chat
            && sheet.infoGeneration == id && sheet.pose.e < 0.99
            && app.chats.chat(chat) != nil && app.chats.isVisible(chat)
            && !app.privateContentBlocked && !app.privateLock.presentsPrompt
    }

    /// While UIKit zooms it back into the face (no longer current) it keeps
    /// its words; only privacy blacks it out.
    @MainActor
    func mayShow(in app: AppModel) -> Bool {
        if isCurrent(in: app) { return true }
        return app.chats.chat(chat) != nil && app.chats.isVisible(chat)
            && !app.privateContentBlocked && !app.privateLock.presentsPrompt
    }

    @MainActor
    static func binding(app: AppModel, chat: Chat.ID) -> Binding<Self?> {
        let captured = app.chatSheet.infoGeneration.map { Self(id: $0, chat: chat) }
        return Binding(get: { captured.flatMap { $0.isCurrent(in: app) ? $0 : nil } }, set: { newValue in
            // A cancelled zoom does not write nil. A completed old zoom must
            // not change a new owner, a reopened Info page, or the Chats list.
            if newValue == nil, let captured { app.closeChatInfo(captured) }
        })
    }
}

struct ChatInfoPage: View {
    @Environment(AppModel.self) private var app
    let presentation: ChatInfoPresentation

    var body: some View {
        Group {
            if presentation.mayShow(in: app), let chat = app.chats.chat(presentation.chat) {
                ChatDetails(chat: chat, presentation: presentation)
                    .accessibilityAction(.escape) { app.closeChatInfo(presentation) }
            } else {
                // A modal is above RootView. It enforces the same immediate
                // private/owner boundary while UIKit dismisses a retired cover.
                Color.black.accessibilityLabel("Private content hidden")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatDetails.page.ignoresSafeArea())
        .overlay { ChatInfoPrivacyCurtain(app: app, presentation: presentation).ignoresSafeArea().accessibilityHidden(false) }
        .ignoresSafeArea()
        .interactiveDismissDisabled(!presentation.isCurrent(in: app))
        .transaction { if !presentation.isCurrent(in: app) { $0.animation = nil } }
    }
}

/// RootController's cover is below a modal. This modal's own UIKit view covers
/// synchronously before the system snapshots its window on resign-active.
private struct ChatInfoPrivacyCurtain: UIViewRepresentable {
    let app: AppModel
    let presentation: ChatInfoPresentation
    func makeUIView(context: Context) -> ChatInfoPrivacyView { ChatInfoPrivacyView() }
    func updateUIView(_ view: ChatInfoPrivacyView, context: Context) { view.configure(app: app, presentation: presentation) }
    static func dismantleUIView(_ view: ChatInfoPrivacyView, coordinator: ()) { view.retire() }
}

final class ChatInfoPrivacyView: UIView {
    private weak var app: AppModel?
    private var retired = false
    private var privateOrigin = false
    private let windowCover = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        windowCover.backgroundColor = .black
        windowCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        windowCover.accessibilityIdentifier = "chat.info.privateWindowCurtain"
        windowCover.accessibilityLabel = "Private content hidden"
        windowCover.isAccessibilityElement = true
        accessibilityIdentifier = "chat.info.privateCurtain"
        accessibilityLabel = "Private content hidden"
        NotificationCenter.default.addObserver(self, selector: #selector(resigned),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { return nil }

    func configure(app: AppModel, presentation: ChatInfoPresentation? = nil) {
        configure(app: app, chat: presentation?.chat)
    }

    /// A modal showing `chat` (Chat Info, a chat's own cover).
    func configure(app: AppModel, chat: Chat.ID?) {
        guard !retired else { return }
        self.app = app
        privateOrigin = chat.map { app.chats.isPrivate($0) || app.chatSheet.pageSources[$0]?.isPrivate == true } ?? app.hasPrivateForeground
        setCovered((!app.privateLock.isActive && app.hasPrivateForeground)
                   || app.privateContentBlocked || app.privateLock.presentsPrompt)
    }

    @objc private func resigned() { coverBeforeSnapshot() }

    func coverBeforeSnapshot() {
        guard !retired, let app, privateOrigin || app.hasPrivateForeground || app.privateLock.presentsPrompt else { return }
        setCovered(true)
    }

    private func setCovered(_ covered: Bool) {
        isHidden = !covered
        isUserInteractionEnabled = covered
        isAccessibilityElement = covered && window == nil
        if covered, let window {
            // This owned subview also covers a native Rename alert above Info.
            windowCover.frame = window.bounds
            if windowCover.superview !== window { window.addSubview(windowCover) }
            window.bringSubviewToFront(windowCover)
        } else { windowCover.removeFromSuperview() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if !retired { setCovered(!isHidden) }
    }

    func retire() {
        retired = true; app = nil; windowCover.removeFromSuperview()
        NotificationCenter.default.removeObserver(self)
    }
    isolated deinit { windowCover.removeFromSuperview(); NotificationCenter.default.removeObserver(self) }
}
