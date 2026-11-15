import SwiftUI
import UIKit

/// UIKit owns the source button, menu and their iOS 26 glass transition.
/// Title holds and accessibility More use the very same native interaction.
struct ChatNativeMenu: UIViewRepresentable {
    @Environment(AppModel.self) private var app
    let chat: Chat.ID
    var size: CGFloat = Metrics.Chats.headerSymbol

    func makeUIView(context: Context) -> ChatMenuControl {
        let button = ChatMenuControl(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "chat.more"
        button.accessibilityLabel = "More"
        button.configuration = .glass()
        button.configuration?.cornerStyle = .capsule
        return button
    }

    func updateUIView(_ button: ChatMenuControl, context: Context) {
        let current = app.chats.chat(chat)
        button.owner = chat
        button.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        button.configuration?.image = UIImage(systemName: "ellipsis")
        button.configuration?.baseForegroundColor = .label
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        button.menu = Self.menu(chat: chat, app: app)
        button.isCurrent = { [weak app] in
            guard let app else { return false }
            return Self.isCurrentConversation(chat, app: app)
        }
        button.isEnabled = current != nil && Self.isCurrentConversation(chat, app: app)
        button.onPresented = { [weak app] shown in
            guard let app, Self.isCurrentConversation(chat, app: app) else { return }
            app.chatSheet.moreMenu = shown
        }
        button.requested = app.chatSheet.moreMenu && Self.isCurrentConversation(chat, app: app)
        button.reconcile()
    }

    static func dismantleUIView(_ button: ChatMenuControl, coordinator: ()) { button.retire() }

    @MainActor
    static func isCurrentConversation(_ id: Chat.ID, app: AppModel) -> Bool {
        let sheet = app.chatSheet
        return sheet.shown && !sheet.info
            && sheet.pose.e < 0.99 && sheet.chatID == id && app.chats.chat(id) != nil && app.chats.isVisible(id)
            && !app.privateContentBlocked
    }

    @MainActor
    static func menu(chat id: Chat.ID, app: AppModel) -> UIMenu {
        let chat = app.chats.chat(id)
        func item(_ title: String, _ glyph: MacGlyph, _ pick: AppModel.MorePick) -> UIAction {
            // The Mac's ⌘J menu glyphs (Glyphs.swift), not SF's, at an SF symbol's size.
            let image = UIImage.menuGlyph(glyph)
            return UIAction(title: title, image: image, identifier: UIAction.Identifier("chat.menu.\(pick)")) { [weak app] _ in
                guard let app, Self.isCurrentConversation(id, app: app) else { return }
                app.pickMore(pick)
            }
        }
        var items = [
            item(chat?.pinned == true ? "Unpin Chat" : "Pin Chat", chat?.pinned == true ? .pinSlash : .pin, .pin),
            item("Rename Chat", .pencil, .rename),
            item(chat?.unread == true ? "Mark as Read" : "Mark as Unread", chat?.unread == true ? .yabChat : .yabChatDot, .unread),
            item("Copy Answer", .yabCopyframeText, .copy)
        ]
        if app.canOpenChatOnMac { items.append(item("Open on \(app.macName)", .yabLaptopRight, .mac)) }
        items += [item("Archive Chat", .yabArchive, .archive), item("Chat Info", .infoCircle, .info)]
        guard app.canDelete(id) else { return UIMenu(children: items) }
        let delete = item("Delete Chat\u{2026}", .trash, .delete)
        delete.attributes = .destructive
        return UIMenu(children: items + [UIMenu(options: .displayInline, children: [delete])])
    }
}

final class ChatMenuControl: UIButton {
    var owner: Chat.ID? {
        didSet {
            if oldValue != owner {
                activePresentation = nil; presentations.removeAll()
                contextMenuInteraction?.dismissMenu()
                visible = false; requested = false
            }
        }
    }
    var requested = false
    private(set) var visible = false
    var onPresented: ((Bool) -> Void)?
    var isCurrent: (() -> Bool)?
    private var retired = false
    private struct Presentation {
        let owner: Chat.ID?
        let callback: ((Bool) -> Void)?
        let isCurrent: (() -> Bool)?
    }
    private var presentations: [ObjectIdentifier: Presentation] = [:]
    private var activePresentation: ObjectIdentifier?

    override func didMoveToWindow() { super.didMoveToWindow(); reconcile() }

    func reconcile() {
        guard !retired, window != nil else { return }
        if requested, !visible {
            // updateUIView cannot mutate the observed sheet while laying out.
            // The next main turn still verifies this exact control and owner.
            let expected = owner
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.retired, self.owner == expected, self.requested,
                      !self.visible, self.window != nil, self.isEnabled, self.isCurrent?() == true else { return }
                self.performPrimaryAction()
            }
        } else if !requested, visible { contextMenuInteraction?.dismissMenu() }
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !retired, isCurrent?() == true, let configuration = super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location) else { return nil }
        // Bind before presentation begins. A route change can happen between
        // configuration creation and UIKit's willDisplay callback.
        presentations[ObjectIdentifier(configuration)] = Presentation(owner: owner, callback: onPresented, isCurrent: isCurrent)
        return configuration
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        let id = ObjectIdentifier(configuration)
        guard !retired, let presentation = presentations[id], owner == presentation.owner,
              presentation.isCurrent?() == true else { interaction.dismissMenu(); return }
        activePresentation = id
        visible = true; requested = true
        presentation.callback?(true)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        let id = ObjectIdentifier(configuration)
        guard let presentation = presentations.removeValue(forKey: id), !retired,
              activePresentation == id, owner == presentation.owner else { return }
        activePresentation = nil
        visible = false; requested = false
        presentation.callback?(false)
    }

    func retire() {
        retired = true; requested = false; onPresented = nil; isCurrent = nil
        activePresentation = nil; presentations.removeAll()
        contextMenuInteraction?.dismissMenu()
        menu = nil
    }
}
