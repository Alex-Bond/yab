import SwiftUI
import UIKit

/// The exact page whose Plus offered the menu, including empty spaces.
struct ChromePlusOwner: Equatable {
    let space: Space.ID
    let tab: Tab.ID?
    let url: URL?
    let isPrivate: Bool

    @MainActor
    init(app: AppModel) {
        space = app.browser.spaceID
        tab = app.browser.tab?.id
        url = app.browser.tab?.navigationURL
        isPrivate = app.browser.space.isPrivate || app.browser.tab?.isPrivate == true
    }
}

/// UIKit owns the real button and menu rows, including their spoken titles.
/// On the page it is the tab stack (Tabs/): the two tabs used last, a tap
/// for All Tabs, a flick up for the previous one, held for New Tab (and New
/// Private Tab, New Chat, Voice Search, Scan QR Code) and the recent tabs;
/// with no other tab it stays +, its hold the same first group.
struct ChromeNativePlus: UIViewRepresentable {
    @Environment(AppModel.self) private var app
    let owner: ChromePlusOwner
    let origin: CGRect
    let isAccessible: Bool
    /// What the stack shows, read where SwiftUI observes it.
    var stack: TabStack.Contents? = nil
    /// Folded with the chrome: the glass dematerializes (ChromePlusControl.setFolded).
    var folded = false

    func makeUIView(context: Context) -> ChromePlusControl { ChromePlusControl(type: .custom) }

    func updateUIView(_ button: ChromePlusControl, context: Context) {
        MainStalls.count("plusMenu")
        UpdateLoops.count(.plusMenu) {
            var inputs = UpdateLoops.Fingerprint(fields: [
                "button": Double(ObjectIdentifier(button).hashValue),
                "folded": folded ? 1 : 0,
                "isAccessible": isAccessible ? 1 : 0,
                "owner.isPrivate": owner.isPrivate ? 1 : 0,
                "owner.hasTab": owner.tab == nil ? 0 : 1,
                "owner.isCurrent": Self.isCurrent(owner, app: app) ? 1 : 0,
                "stack.count": Double(stack?.count ?? -1),
                "stack.pictures": Double(stack?.pictures ?? -1),
                "stack.hasFront": stack?.front == nil ? 0 : 1,
                "stack.hasBack": stack?.back == nil ? 0 : 1,
                "dark": context.environment.colorScheme == .dark ? 1 : 0,
                "transaction.animated": context.transaction.animation == nil ? 0 : 1,
                "transaction.disablesAnimations": context.transaction.disablesAnimations ? 1 : 0,
            ])
            inputs.rect("origin", origin)
            inputs.rect("button.bounds", button.bounds)
            return inputs
        }
        Self.bind(button, app: app, owner: owner, origin: origin,
                  isAccessible: isAccessible, scheme: context.environment.colorScheme, stack: stack)
        button.setFolded(folded, animated: context.transaction.animation != nil && !context.transaction.disablesAnimations)
    }

    static func dismantleUIView(_ button: ChromePlusControl, coordinator: ()) { button.retire() }

    @MainActor
    static func isCurrent(_ owner: ChromePlusOwner, app: AppModel) -> Bool {
        owner == ChromePlusOwner(app: app) && (!app.chrome.folded || app.workspace.verticalControls) && !app.privateContentBlocked
            && !app.surfaces.coversChrome && app.surfaces.chromeOpacity > 0.5
            && !app.surfaces.settings && !app.surfaces.join && app.surfaces.chat == nil
            && app.surfaces.menu == nil
    }

    @MainActor
    static func bind(_ button: ChromePlusControl, app: AppModel, owner: ChromePlusOwner,
                     origin: CGRect, isAccessible: Bool, scheme: ColorScheme, stack contents: TabStack.Contents? = nil) {
        let tabs = TabStack.of(app)
        let stack = contents ?? tabs.contents()
        // The last today's tab (or private one) still needs its card's Close.
        let loneCard = stack.loneCard || (owner.isPrivate && stack.count == 1)
        // The empty page: nothing to stack, the space's emoji takes you to the spaces.
        let spaceMark = owner.tab == nil && !owner.isPrivate && !stack.showsStack ? app.browser.space.emoji : nil
        tabs.control = button
        button.owner = owner
        button.overrideUserInterfaceStyle = owner.isPrivate || scheme == .dark ? .dark : .light
        button.setPrivateAppearance(owner.isPrivate)
        button.tintColor = owner.isPrivate ? .white : UIColor(Ink.primary)
        button.setStack(stack, artwork: app.sync.folderArtwork, picture: tabs.picture)
        button.setSpaceMark(spaceMark)
        button.isCurrent = { [weak app] in
            guard let app else { return false }
            return Self.isCurrent(owner, app: app)
        }
        button.isEnabled = isAccessible && Self.isCurrent(owner, app: app)
        button.isUserInteractionEnabled = button.isEnabled
        button.isAccessibilityElement = button.isEnabled
        button.accessibilityElementsHidden = !button.isEnabled
        button.accessibilityIdentifier = button.isEnabled ? "chrome.plus" : nil
        button.accessibilityValue = owner.isPrivate ? "Private" : "Public"
        if let previous = stack.front {
            button.accessibilityLabel = loneCard ? "All Tabs" : "Previous tab, \(previous.short)"
            button.accessibilityHint = "Shows all tabs"
        } else if spaceMark != nil {
            button.accessibilityLabel = "Spaces"
            button.accessibilityHint = "Shows this space's tabs and the others"
        } else {
            button.accessibilityLabel = "New Tab"
            button.accessibilityHint = owner.isPrivate ? "Opens a new private tab" : "Opens a new tab"
        }
        button.onTap = { [weak app, weak button] in
            guard let app, let button, button.accepts(owner), Self.isCurrent(owner, app: app) else { return }
            if stack.showsStack {
                // A faint tick under the finger: the stack answers before All Tabs has its picture.
                Haptics.play(.selection, reason: Haptics.Reason.stackTap)
                TabStack.of(app).openGallery()
            } else if spaceMark != nil {
                Haptics.play(.light, reason: Haptics.Reason.columnOpened)
                app.field.openSpaces(from: origin)
            } else { app.openNewTab(from: origin) }
        }
        let current: () -> AppModel? = { [weak app, weak button] in
            guard let app, let button, button.accepts(owner), Self.isCurrent(owner, app: app) else { return nil }
            return app
        }
        let showAllTabs: (name: String, perform: () -> Bool) = ("Show All Tabs", {
            guard let app = current() else { return false }
            TabStack.of(app).openGallery()
            return true
        })
        let actions: [(name: String, perform: () -> Bool)] = [
            ("Switch to Previous Tab", {
                guard let app = current(), let previous = TabStack.of(app).previous else { return false }
                TabStack.of(app).switchTo(previous.id)
                return true
            }),
            showAllTabs,
            ("New Tab", {
                guard let app = current() else { return false }
                app.openNewTab(from: origin)
                return true
            }),
        ]
        let spokenActions = loneCard ? [showAllTabs] : stack.showsStack ? actions : []
        button.setStackAccessibility(button.isEnabled ? spokenActions : [])
        // Voice Search where speech is recognized (in Private only on this
        // iPhone), Scan QR Code where the iPhone can scan.
        let voice = app.voice.offers(privately: owner.isPrivate)
        let scan = app.scanner.canScan
        // The stack's menu is made again when the tabs it offers change, or what it can do.
        let offered = [stack.front, stack.back].compactMap { $0.map { "\($0.id) \($0.title) \($0.addressHost)" } }
            + ["\(stack.count)", "voice \(voice)", "scan \(scan)"]
        button.bindMenu(owner: owner, origin: origin, enabled: button.isEnabled, offering: offered) { epoch in
            func item(_ title: String, _ glyph: MacGlyph, _ id: String,
                      action: @escaping @MainActor (AppModel) -> Void) -> UIAction {
                let item = UIAction(title: title, image: UIImage.menuGlyph(glyph),
                                    identifier: UIAction.Identifier(id)) { [weak app, weak button] _ in
                    guard let app, let button, button.accepts(owner, epoch: epoch), Self.isCurrent(owner, app: app) else { return }
                    action(app)
                }
                item.accessibilityIdentifier = id
                return item
            }
            let newTab = item("New Tab", .yabTabPlus, "chrome.menu.newtab") { $0.openNewTab(from: origin) }
            let newPrivate = item("New Private Tab", .incognito, "chrome.menu.newprivate") { $0.openNewTab(privately: true, from: origin) }
            // New Chat stays under the right button in both of its forms:
            // with the column gone, nowhere else offers it from a page.
            let newChat = item("New Chat", .squareAndPencil, "chrome.menu.newchat") { app in
                Motion.chatGrow.run { app.surfaces.openChat(.newChat, from: origin) }
            }
            // New Tab's other ways in, on the +'s hold: the field opens
            // listening, or under the camera.
            var first = [newTab, newPrivate, newChat]
            if !owner.isPrivate {
                let folder = UIAction(title: "New Folder", image: UIImage(systemName: "folder.badge.plus"),
                                      identifier: UIAction.Identifier("chrome.menu.newfolder")) { [weak app, weak button] _ in
                    guard let app, let button, button.accepts(owner, epoch: epoch), Self.isCurrent(owner, app: app) else { return }
                    app.tabEdits.begin(.newFolder(owner.space, nil, nil))
                }
                folder.accessibilityIdentifier = "chrome.menu.newfolder"
                first.append(folder)
            }
            if voice { first.append(item("Voice Search", .mic, "chrome.menu.voice") { $0.openVoiceSearch(from: origin) }) }
            if scan { first.append(item("Scan QR Code", .yabQrcode, "chrome.menu.scan") { $0.openScanner(from: origin) }) }
            guard stack.showsStack || loneCard else {
                return UIMenu(children: first)
            }
            // The stack's (prototype scene 8): new tabs, the two recent tabs, then all of them.
            let recent = (loneCard ? [] : [stack.front, stack.back].compactMap { $0 }).map { tab in
                let id = "chrome.menu.tab.\(tab.id)"
                let row = UIAction(title: tab.title, subtitle: tab.addressHost,
                                   image: TabIcons.menuImage(for: tab, artwork: app.sync.folderArtwork),
                                   identifier: UIAction.Identifier(id)) { [weak app, weak button] _ in
                    guard let app, let button, button.accepts(owner, epoch: epoch), Self.isCurrent(owner, app: app) else { return }
                    TabStack.of(app).switchTo(tab.id)
                }
                row.accessibilityIdentifier = id
                return row
            }
            let all = item("All Tabs · \(stack.count)", .yabTabs, "chrome.menu.alltabs") { TabStack.of($0).openGallery() }
            var groups = [UIMenu(options: .displayInline, children: first)]
            if !recent.isEmpty { groups.append(UIMenu(options: .displayInline, children: recent)) }
            groups.append(UIMenu(options: .displayInline, children: [all]))
            return UIMenu(children: groups)
        }
    }
}

final class ChromePlusControl: UIButton {
    var owner: ChromePlusOwner? {
        didSet { if oldValue != owner { revokeMenu() } }
    }
    var isCurrent: (() -> Bool)?
    var onTap: (() -> Void)?
    private let glass = UIVisualEffectView()
    /// The tab stack, drawn on the glass where + is when there are other tabs.
    let stackView = TabStackView()
    /// While All Tabs is up its layer draws the circle and the stack's cards
    /// (they come out of it and fly into it there, over the cards' ground),
    /// so the button draws nothing of its own.
    var lent = false {
        didSet { if lent != oldValue { show() } }
    }
    private var showsStack = false
    /// The space's emoji on the empty page, where + stands otherwise.
    private let spaceLabel = UILabel()
    private var privateAppearance: Bool?
    private var effect: UIGlassEffect?
    private var folded = false
    private var retired = false
    private var stackActions: [String: () -> Bool] = [:]
    private var stackActionNames: [String] = []
    private struct MenuBinding: Equatable {
        let owner: ChromePlusOwner
        let origin: CGRect
        var offering: [String] = []
    }
    private struct MenuCapture {
        let owner: ChromePlusOwner
        let epoch: UUID
    }
    private var menuBinding: MenuBinding?
    private(set) var menuEpoch: UUID?
    private var configurations: [ObjectIdentifier: MenuCapture] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.isUserInteractionEnabled = false
        glass.accessibilityElementsHidden = true
        glass.clipsToBounds = true
        insertSubview(glass, at: 0)
        insertSubview(stackView, aboveSubview: glass)
        spaceLabel.font = .systemFont(ofSize: Metrics.Chrome.spaceEmoji)
        spaceLabel.textAlignment = .center
        spaceLabel.isUserInteractionEnabled = false
        spaceLabel.isAccessibilityElement = false
        spaceLabel.isHidden = true
        insertSubview(spaceLabel, aboveSubview: stackView)
        setImage(Self.image(.plusMedium, size: Metrics.Chrome.spaceEmoji), for: .normal)
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        showsMenuAsPrimaryAction = false
        preferredMenuElementOrder = .fixed
        isContextMenuInteractionEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Metrics.Chrome.round, height: Metrics.Chrome.round)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        stackView.frame = bounds
        spaceLabel.frame = bounds
        // UIButton may insert its image below custom subviews during layout.
        // Keep the existing native glyph in front of its retained material.
        if let imageView, imageView.superview === self { bringSubviewToFront(imageView) }
        // UIButton sets its image's alpha again as it lays out.
        imageView?.alpha = plusAlpha
    }

    /// The + glyph's share: none while the stack is drawn.
    private var plusAlpha: CGFloat = 1

    /// The stack's two cards on the glass when there are other tabs, else +.
    func setStack(_ contents: TabStack.Contents, artwork: SyncFolderArtwork? = nil, picture: (Tab) -> UIImage?) {
        stackView.show(front: contents.front, back: contents.back, pictures: contents.pictures, artwork: artwork, picture: picture)
        showsStack = contents.showsStack
        show()
    }

    func setSpaceMark(_ emoji: String?) {
        // A space with no emoji of its own keeps +.
        let mark = emoji?.isEmpty == false ? emoji : nil
        spaceLabel.text = mark
        spaceLabel.isHidden = mark == nil
        show()
    }

    private func show() {
        glass.alpha = lent ? 0 : 1
        stackView.alpha = showsStack && !lent && !folded ? 1 : 0
        spaceLabel.alpha = lent || folded ? 0 : 1
        plusAlpha = showsStack || !spaceLabel.isHidden || lent || folded ? 0 : 1
        imageView?.alpha = plusAlpha
    }

    /// Folded, the button melts: its glass dematerializes (the
    /// effect animated away, which an alpha on glass can't do), the stack or + fades.
    func setFolded(_ on: Bool, animated: Bool) {
        guard on != folded else { return }
        folded = on
        let change = {
            self.glass.effect = on ? nil : self.effect
            self.show()
        }
        guard animated, !Motion.disabled else { change(); return }
        UIView.animate(withDuration: Motion.chromeButtons.duration, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut], animations: change)
    }

    /// The stack's VoiceOver actions; their objects stay while their names do.
    func setStackAccessibility(_ actions: [(name: String, perform: () -> Bool)]) {
        stackActions = Dictionary(actions.map { ($0.name, $0.perform) }, uniquingKeysWith: { first, _ in first })
        let names = actions.map(\.name)
        guard names != stackActionNames else { return }
        stackActionNames = names
        accessibilityCustomActions = names.isEmpty ? nil : names.map { name in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let self, !self.retired, self.isEnabled, self.isCurrent?() == true else { return false }
                return self.stackActions[name]?() ?? false
            }
        }
    }

    #if DEBUG
    /// Named states picture the held menu: UIKit's own presentation, as a
    /// finger held on the button would start it.
    func presentMenuForTests() {
        guard let interaction = contextMenuInteraction else { return }
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard interaction.responds(to: selector) else { return }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        let present = unsafeBitCast(interaction.method(for: selector), to: Present.self)
        present(interaction, selector, CGPoint(x: bounds.midX, y: bounds.midY))
    }
    #endif

    func setPrivateAppearance(_ isPrivate: Bool) {
        guard privateAppearance != isPrivate else { return }
        privateAppearance = isPrivate
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        effect.tintColor = isPrivate ? UIColor(Ink.privateGlass.opacity(0.78)) : nil
        self.effect = effect
        if !folded { glass.effect = effect }
    }

    static func image(_ glyph: GlyphName, size: CGFloat) -> UIImage? {
        guard let source = UIImage(named: glyph.asset) else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }.withRenderingMode(.alwaysTemplate)
    }

    func accepts(_ expected: ChromePlusOwner) -> Bool {
        !retired && owner == expected && isEnabled && isUserInteractionEnabled && isCurrent?() == true
            && window != nil && window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
    }

    /// Unchanged SwiftUI updates keep the native menu and its actions alive.
    /// Re-entering an earlier source never revives an already revoked action.
    func bindMenu(owner: ChromePlusOwner, origin: CGRect, enabled: Bool, offering: [String] = [], make: (UUID) -> UIMenu) {
        guard enabled, !retired else { revokeMenu(); return }
        let binding = MenuBinding(owner: owner, origin: origin, offering: offering)
        if menuBinding == binding, menuEpoch != nil, menu != nil { return }
        revokeMenu()
        let epoch = UUID()
        menuBinding = binding; menuEpoch = epoch; menu = make(epoch)
    }

    func accepts(_ expected: ChromePlusOwner, epoch: UUID) -> Bool {
        menuEpoch == epoch && accepts(expected)
    }

    private func revokeMenu() {
        menuEpoch = nil; menuBinding = nil
        dismissOwnedMenu(); menu = nil
    }

    @objc private func pressed() { onTap?() }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let owner, let epoch = menuEpoch, accepts(owner, epoch: epoch),
              let configuration = super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location) else { return nil }
        // Bind before UIKit begins presenting, not in its later willDisplay.
        configurations = [ObjectIdentifier(configuration): MenuCapture(owner: owner, epoch: epoch)]
        return configuration
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        guard let captured = configurations[ObjectIdentifier(configuration)], accepts(captured.owner, epoch: captured.epoch) else {
            interaction.dismissMenu(); return
        }
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willEndFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        configurations.removeValue(forKey: ObjectIdentifier(configuration))
    }

    func dismissOwnedMenu() { configurations.removeAll(); contextMenuInteraction?.dismissMenu() }

    func retire() {
        retired = true; revokeMenu(); onTap = nil; isCurrent = nil
        stackActions = [:]; stackActionNames = []; accessibilityCustomActions = nil
        isEnabled = false; isUserInteractionEnabled = false
    }
}
