import SwiftUI
import Translation
import UIKit

/// A held message, as in Messages: the bubble lifts out of the chat over the
/// blurred screen, its menu under it. Copy, Translate and Share for any
/// message; Edit puts a question back in the field to change and send again;
/// Select Text opens an answer's words to pick a part of them; an answer
/// from the Mac adds Ask Again. Its steps are never shown: what the agent
/// does is said only in the head while it works.
struct MessageHold: ViewModifier {
    @Environment(AppModel.self) private var app
    let message: Message
    /// A bubble lifts in its own shape.
    let shape: AnyShape
    /// Words without a bubble lift on a card: what the card shows.
    var lifted: AnyView?
    var enabled = true
    @State private var translating = false
    @State private var width: CGFloat = 0

    private var words: String { AppModel.copyText(message) }

    func body(content: Content) -> some View {
        if enabled { held(content) } else { content }
    }

    @ViewBuilder private func held(_ content: Content) -> some View {
        if let lifted {
            // Bare, the words lifted on a gray haze: they lift on a card.
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .contextMenu { menu } preview: {
                    lifted
                        .environment(app)
                        .frame(width: max(width, 1), alignment: .leading)
                        .padding(.horizontal, Metrics.Chat.bubblePadding.leading)
                        .padding(.vertical, Metrics.Chat.bubblePadding.top + 3)
                        .background(Ink.card)
                }
                .translationPresentation(isPresented: $translating, text: ChatMarkdown.plain(words))
        } else {
            // A bubble lifts as it is, in its own shape.
            content
                .contentShape(.contextMenuPreview, shape)
                .contextMenu { menu }
                .translationPresentation(isPresented: $translating, text: ChatMarkdown.plain(words))
        }
    }

    @ViewBuilder private var menu: some View {
        Section {
            item("Copy", .yabCopyframeText) { copy() }
            if message.role == .answer {
                item("Select Text", .yabText) { SelectText.present(ChatMarkdown.plain(words)) }
            }
            item("Translate", .yabTranslate) { translating = true }
            // Nothing stands under an answer, as in Messages: its turn is here.
            if let work, let question = work.question {
                item("Ask Again", .yabReload) { askAgain(question) }
            }
            if message.role == .you {
                Button { edit() } label: {
                    Label { Text("Edit") } icon: { glyph(.pencil) }
                }
            }
            // Words still waiting for a Mac that is down: taken back.
            if message.role == .you, message.mac?.send != nil {
                item("Don’t Send", .yabSendX) { app.dontSend(message) }
            }
        }
        Section {
            ShareLink(item: words) {
                Label { Text("Share") } icon: { glyph(.yabShare) }
            }
        }
    }

    private func item(_ title: String, _ name: MacGlyph, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { glyph(name) } }
    }

    private func glyph(_ name: MacGlyph) -> Image {
        UIImage.menuGlyph(name).map { Image(uiImage: $0) } ?? Image(systemName: "circle")
    }

    private func copy() {
        UIPasteboard.general.string = words
        Haptics.play(.soft, reason: Haptics.Reason.copied)
        app.say("Copied", glyph: .squareBehindSquare1)
    }

    /// The answer's turn as it was done on the Mac: Ask Again.
    private var work: TurnWork? {
        guard message.role == .answer, let work = message.work, work.kind == .actions else { return nil }
        return work
    }

    /// The turn's words sent again, as typed, once the menu has gone.
    private func askAgain(_ question: String) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        DispatchQueue.main.async { app.send(question) }
    }

    /// The question back in the field, the keyboard up, to change and send.
    private func edit() {
        let sheet = app.chatSheet
        let words = message.text
        // A turn later: the menu gives the first responder back as it goes.
        DispatchQueue.main.async {
            sheet.draft = words
            sheet.focused = true
        }
    }
}

extension View {
    /// Held, a message lifts with its menu; measuring copies don't.
    func messageHold(_ message: Message, shape: some Shape, enabled: Bool) -> some View {
        modifier(MessageHold(message: message, shape: AnyShape(shape), enabled: enabled))
    }

    /// Words without a bubble: held, `lifted` rises on a card.
    func messageHold(_ message: Message, lifted: some View, enabled: Bool) -> some View {
        modifier(MessageHold(message: message, shape: AnyShape(Rectangle()), lifted: AnyView(lifted), enabled: enabled))
    }
}

/// An answer's words in a sheet of their own, where any part of them can be
/// selected, as the system's text views select (a chat's lines select whole).
enum SelectText {
    @MainActor
    static func present(_ text: String) {
        // A turn later, so the menu is gone from under it.
        DispatchQueue.main.async {
            guard let root = AppModel.topController() else { return }
            let words = UITextView()
            words.text = text
            words.isEditable = false
            words.isSelectable = true
            words.font = .preferredFont(forTextStyle: .body)
            words.adjustsFontForContentSizeCategory = true
            words.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
            words.backgroundColor = .systemBackground
            words.accessibilityIdentifier = "chat.selectText"
            let page = UIViewController()
            page.view = words
            page.title = "Select Text"
            let nav = UINavigationController(rootViewController: page)
            page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in
                nav?.dismiss(animated: !Motion.disabled)
            })
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
            root.present(nav, animated: !Motion.disabled)
        }
    }
}
