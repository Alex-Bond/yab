import SwiftUI
import UIKit

/// Where the bottom toolbar's three controls stand on the page: the
/// chrome's own geometry, folded or not. All three retain their identity;
/// only their frames and foreground state change.
struct BottomToolbarGeometry: Equatable {
    let back: CGRect
    let plate: CGRect
    let plus: CGRect
    let sideOpacity: CGFloat

    init(size: CGSize, folded: Bool, hasNow: Bool, words: CGFloat? = nil, verticalControls: Bool? = nil, leadingRail: Bool = false) {
        let source = ChromeGeometry(size: size, folded: folded, hasNow: hasNow, words: words, verticalControls: verticalControls, leadingRail: leadingRail)
        back = source.back
        plus = source.space
        plate = source.plate
        sideOpacity = CGFloat(source.buttonOpacity)
    }
}

/// One material and one native center button retain their foreground
/// while the chrome folds, pages and gives way to a sheet.
struct SharedBottomToolbar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let size: CGSize
    let sourceFolded: Bool
    let reduced: Bool
    let isAccessible: Bool
    let glassNamespace: Namespace.ID?

    var body: some View {
        let folded = sourceFolded
        let geometry = BottomToolbarGeometry(size: size, folded: folded, hasNow: app.nowItem != nil, words: app.plateWordsWidth, verticalControls: app.workspace.verticalControls, leadingRail: app.workspace.leadingRail)
        // One frame folded or not: each piece moves inside it by its own frame.
        let open = BottomToolbarGeometry(size: size, folded: false, hasNow: app.nowItem != nil, verticalControls: app.workspace.verticalControls, leadingRail: app.workspace.leadingRail)
        let group = open.back.union(open.plate).union(open.plus).union(geometry.plate).insetBy(dx: -16, dy: -16)
        // Safari's fold (Motion.chromeFold): ‹ and the stack slide in toward
        // the capsule, smaller, as their glass melts (natively, below).
        let sideFolded = folded && !app.workspace.verticalControls
        let fold: CGFloat = sideFolded ? 1 : 0
        let slide = Metrics.Chrome.foldSlide * fold
        let shrink = 1 - (1 - Metrics.Chrome.foldButtonScale) * fold
        // The page's plate is dark on a private page.
        let isPrivate = app.browser.space.isPrivate || app.browser.tab?.isPrivate == true
        let menu = app.surfaces.menu
        let enabled = isAccessible && menu == nil
        // The page menu: the plate is its address row (hidden here while the
        // menu draws it), Back and + step aside along the menu's own spring.
        // An action that drops the menu leaves the plate where it was.
        let pageMenu = menu == .plate
        let plateLent = pageMenu
        let sides: CGFloat = pageMenu && app.pageMenu.shown ? 1 : 0
        let finding = app.pageMenu.finding
        // A swipe across: ‹ and + stay; the plate's own pill
        // and the neighbor's go and come between them (BottomPagingPills,
        // over the glass container), the plate itself bare meanwhile.
        let swiping = !folded && app.surfaces.pageSwiping
        // Paging past the last tab into New Tab: ‹ goes, + becomes its ✕
        // (drawn with the pills), as the field takes the whole foot.
        let toNewTab = swiping && app.surfaces.pageSwipePastLast ? PagingPills.toNewTab(app.surfaces.pageSwipe, app: app) : 0
        ZStack(alignment: .topLeading) {
            // Folded, its glass dematerializes natively (ToolbarLeftButton):
            // a SwiftUI opacity leaves a pale disc of glass behind.
            // The empty page has nothing to go back from.
            let hasPage = app.browser.tab != nil
            ToolbarLeftControl(isAccessible: enabled && !sideFolded && hasPage, folded: sideFolded)
                .frame(width: geometry.back.width, height: geometry.back.height)
                .scaleEffect(shrink)
                .position(x: geometry.back.midX + slide - group.minX, y: geometry.back.midY - group.minY)
                .animation(reduced ? nil : Motion.chromeFold.current, value: folded)
                .opacity(hasPage ? 1 - toNewTab : 0)
                .scaleEffect(CGFloat(1 - 0.4 * toNewTab))
                .allowsHitTesting(enabled && !sideFolded && hasPage)
                .modifier(PageMenuSide(progress: sides, direction: -1))

            PlateGlass(size: geometry.plate.size, isPrivate: isPrivate, glassNamespace: glassNamespace,
                       bare: swiping || plateLent) {
                // Read here so the native plate is told the moment the page
                // owns it again: its own update doesn't observe the surfaces.
                let sourceReady = enabled && !app.surfaces.pageSwiping && app.surfaces.chromeOpacity > 0.5
                PlateView(tab: app.browser.tab, tint: app.browser.space.tint, folded: folded,
                          origin: geometry.plate, isAccessible: sourceReady, showsGlass: false)
                    .frame(width: geometry.plate.width, height: max(Metrics.touch, geometry.plate.height))
            }
            .frame(height: max(Metrics.touch, geometry.plate.height))
            // The page menu borrows the plate: it is its address row while the
            // menu is up, landing here alone. Bare, not faded: glass in the
            // container ignores opacity, and the plate showed through the menu.
            .position(x: geometry.plate.midX - group.minX, y: geometry.plate.midY - group.minY)
            .animation(reduced ? nil : Motion.chromeFold.current, value: folded)

            // The tab stack, or + with no other tab (Tabs/).
            ChromeNativePlus(owner: ChromePlusOwner(app: app), origin: geometry.plus,
                             isAccessible: enabled && !sideFolded, stack: TabStack.of(app).contents(), folded: sideFolded)
                .frame(width: geometry.plus.width, height: geometry.plus.height)
                .scaleEffect(shrink)
                .position(x: geometry.plus.midX - slide - group.minX, y: geometry.plus.midY - group.minY)
                .animation(reduced ? nil : Motion.chromeFold.current, value: folded)
                .opacity(1 - toNewTab)
                .allowsHitTesting(enabled && !sideFolded)
                .modifier(PageMenuSide(progress: sides, direction: 1))
        }
        .frame(width: group.width, height: group.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chrome.toolbar")
        .position(x: group.midX, y: group.midY)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Find on Page: iOS's find bar has the bottom; all three step aside.
        .opacity(finding ? 0 : 1)
        .offset(y: finding ? Metrics.Chrome.height : 0)
        .allowsHitTesting(!finding)
        .environment(\.colorScheme, isPrivate ? .dark : colorScheme)
    }
}

/// The plate's one material, its native address inside it: the page's
/// glass (Private's dark one), bare while a swipe's pills stand in for it.
private struct PlateGlass<Address: View>: View {
    let size: CGSize
    let isPrivate: Bool
    let glassNamespace: Namespace.ID?
    /// A swipe pages through the tabs: no glass and no words here, its pills stand in.
    var bare = false
    @ViewBuilder let address: () -> Address

    var body: some View {
        let w = size.width, h = size.height
        // A capsule of the view's own bounds, so the glass follows the frame
        // as it folds. A fixed rect drew the end size at the frame's left
        // edge while the frame still moved: the glass slid off its words.
        let shape = Capsule(style: .continuous)
        let tint = isPrivate ? Ink.privateGlass.opacity(0.78) : Color.white.opacity(0)
        let material = bare ? Glass.identity : Glass.regular.tint(tint).interactive(true)
        // The plate keeps its own (44-point) target, centered on the glass,
        // mounted throughout so its native button stays the same. No SwiftUI
        // blur here: it would rehost the native button in a container that
        // takes its accessibility hit test.
        ZStack {
            address().opacity(bare ? 0 : 1)
        }
        .frame(width: w, height: h)
        .modifier(PlateGlassEffect(shape: shape, material: material, namespace: glassNamespace))
        .frame(width: w, height: h)
        .accessibilityElement(children: .contain)
    }
}

private struct PlateGlassEffect: ViewModifier {
    let shape: Capsule
    let material: Glass
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content
                .glassEffect(material, in: shape)
                .glassEffectID("page-controls", in: namespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            content
                .glassEffect(material, in: shape)
                .glassEffectTransition(.identity)
        }
    }
}

/// The pills of a swipe across the plate, over the chrome's glass container
/// (glass inside it ignores its views' opacity): the page's plate and toolbar
/// geometry, as SharedBottomToolbar lays them out on the page.
struct BottomPagingPills: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let size: CGSize
    let folded: Bool

    var body: some View {
        if let swipe = app.surfaces.pageSwipe, !folded {
            let geometry = BottomToolbarGeometry(size: size, folded: folded, hasNow: app.nowItem != nil,
                                                  verticalControls: app.workspace.verticalControls, leadingRail: app.workspace.leadingRail)
            let isPrivate = app.browser.space.isPrivate || app.browser.tab?.isPrivate == true
            let field = FieldGeometry(size: size, keyboard: 0, mode: .newTab, resting: true)
            let n = CGFloat(PagingPills.toNewTab(swipe, app: app))
            ZStack(alignment: .topLeading) {
                PagingPills(swipe: swipe, tab: app.browser.tab, isPrivate: isPrivate, slot: max(1, Pager.of(app).slot),
                            plate: geometry.plate,
                            lower: app.workspace.verticalControls ? Metrics.Edge.bar : geometry.back.maxX,
                            upper: app.workspace.verticalControls ? size.width - Metrics.Edge.bar : geometry.plus.minX,
                            field: PagingLayer.slidesSpaces(app) ? field.field : nil)
                // + turning into the field's ✕ on the way to New Tab.
                if n > 0 {
                    let from = geometry.plus, to = field.close
                    let mix = { (a: CGFloat, b: CGFloat) in a + (b - a) * n }
                    let rect = CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                                      width: mix(from.width, to.width), height: mix(from.height, to.height))
                    Image(systemName: "xmark")
                        .font(.system(size: Metrics.Field.clearGlyph, weight: .medium))
                        .foregroundStyle(Ink.clearGlyph)
                        .frame(width: rect.width, height: rect.height)
                        .glassEffect(.regular, in: Circle())
                        .opacity(Double(n))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
                .environment(\.colorScheme, isPrivate ? .dark : colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The pills while a swipe pages through the tabs (measured frame by
/// frame, 2026-10-08), by how far the pages have turned (0 to 1):
/// the one going loses ≡ and ↻ at once (the plate fades), shrinks to its
/// words by 15 %, against the side it leaves for, its words gone by 40 % and
/// the glass shrinking and gone by 72 %; the one coming shows at once, out of
/// the other side as an empty sliver from 10 % (the one going is its words by
/// then, so they never meet), its words sliding in from 30 % to 55 %, and from
/// 90 % it opens to the whole plate. Both stay between ‹ and +, touching them at
/// most. With no tab to come (the first), the one going keeps its words.
private struct PagingPills: View {
    let swipe: PageSwipe
    let tab: Tab?
    let isPrivate: Bool
    let slot: CGFloat
    let plate: CGRect
    let lower: CGFloat
    let upper: CGFloat
    /// New Tab's field, where a pill coming in past the last tab lands
    /// (nil: a private space keeps the plate's pill and "New Tab").
    var field: CGRect? = nil
    @State private var words: [String: CGFloat] = [:]

    /// How far a swipe past the last tab has turned into New Tab: ‹ and +
    /// give way to the field and its ✕ between 30 % and 70 % of the page.
    @MainActor static func toNewTab(_ swipe: PageSwipe?, app: AppModel) -> Double {
        guard let swipe, swipe.newTab, swipe.offset < 0, PagingLayer.slidesSpaces(app) else { return 0 }
        return seg(min(-swipe.offset / max(1, Pager.of(app).slot), 1), 0.3, 0.7)
    }

    static func seg(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Double { Double(min(max((t - a) / (b - a), 0), 1)) }
    private static func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    var body: some View {
        let o = swipe.offset
        let d: CGFloat = o >= 0 ? 1 : -1
        let q = min(abs(o) / slot, 1)
        let coming: Tab? = d > 0 ? swipe.before : swipe.after
        let comes = d > 0 ? swipe.before != nil : (swipe.after != nil || swipe.newTab)
        let full = plate.width
        let seg = Self.seg, mix = Self.mix
        // Into New Tab: the coming pill is the field, landing in its place,
        // and may spread as far as ‹ and + leave room for it.
        let into = d < 0 && swipe.newTab ? field : nil
        let n = into == nil ? 0 : seg(q, 0.3, 0.7)
        let low = into.map { mix(lower, $0.minX, n) } ?? lower
        let high = into.map { mix(upper, $0.maxX, n) } ?? upper
        // The one going.
        let goShort = short(tab)
        let goW = q < 0.32 ? mix(full, goShort, seg(q, 0.02, 0.15)) : mix(goShort, 64, seg(q, 0.32, 0.55))
        let push = (d > 0 ? upper - plate.maxX : plate.minX - lower) * CGFloat(seg(q, 0.05, 0.3))
        let goX = d > 0 ? plate.maxX + push - goW : plate.minX - push
        // The one coming.
        let comeShort = short(coming)
        let land = seg(q, 0.9, 1)
        let comeW = q < 0.3 ? mix(40, 64, seg(q, 0.1, 0.3))
            : q < 0.9 ? mix(64, comeShort, seg(q, 0.3, 0.7)) : mix(comeShort, into?.width ?? full, land)
        let comeX = d > 0 ? plate.minX : mix(plate.maxX, into?.maxX ?? plate.maxX, land) - comeW
        let comeY = mix(plate.midY, into?.midY ?? plate.midY, land)
        ZStack(alignment: .topLeading) {
            // Each pill's words, measured once, for its short width.
            ForEach(measured, id: \.key) { item in
                label(item.tab).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { words[item.key] = $0 }
            }
            pill(tab, x: goX, width: goW, glass: comes ? 1 - seg(q, 0.5, 0.72) : 1,
                 words: comes ? 1 - seg(q, 0.22, 0.4) : 1, shift: 0, low: low, high: high)
            if comes {
                pill(coming, x: comeX, width: comeW, glass: seg(q, 0.1, 0.18), words: seg(q, 0.3, 0.55),
                     shift: -d * CGFloat(1 - seg(q, 0.3, 0.55)) * 28, low: low, high: high,
                     y: comeY, leading: into != nil)
            }
        }
    }

    private var measured: [(key: String, tab: Tab?)] {
        [(key(tab), tab), (key(swipe.before), swipe.before), (key(swipe.after), swipe.after)]
            .reduce(into: []) { out, item in if !out.contains(where: { $0.key == item.0 }) { out.append((item.0, item.1)) } }
    }

    private func key(_ tab: Tab?) -> String { tab?.id ?? "new-tab" }

    /// The field's words are long: its pill comes in short and shows their start.
    private func short(_ tab: Tab?) -> CGFloat {
        let w = max(64, (words[key(tab)] ?? 120) + 24)
        return tab == nil && field != nil ? min(w, 150) : w
    }

    @ViewBuilder private func label(_ tab: Tab?) -> some View {
        if let tab { PlateLabel(tab: tab, folded: false, onDark: isPrivate) }
        else if field != nil { NewTabFieldLabel() }
        else { NewTabLabel(onDark: isPrivate) }
    }

    private func pill(_ tab: Tab?, x: CGFloat, width: CGFloat, glass: Double, words: Double, shift: CGFloat,
                      low: CGFloat, high: CGFloat, y: CGFloat? = nil, leading: Bool = false) -> some View {
        let left = max(low, x), right = min(high, x + width)
        let w = max(0, right - left)
        return label(tab)
            .fixedSize()
            .offset(x: shift)
            .opacity(words)
            .frame(width: w, height: plate.height, alignment: leading ? .leading : .center)
            .clipShape(Capsule(style: .continuous))
            .glassEffect(isPrivate ? GlassTone.privateTab.glass(for: .dark) : .regular, in: Capsule(style: .continuous))
            .opacity(glass)
            .position(x: left + w / 2, y: y ?? plate.midY)
    }
}

/// One actual UIButton and one UIGlassEffectView: Back.
struct ToolbarLeftControl: UIViewRepresentable {
    @Environment(AppModel.self) private var app
    let isAccessible: Bool
    var folded = false

    func makeUIView(context: Context) -> ToolbarLeftButton { ToolbarLeftButton(type: .custom) }

    func updateUIView(_ button: ToolbarLeftButton, context: Context) {
        let owner = ChromePlusOwner(app: app)
        let isPrivate = owner.isPrivate
        // Where ‹ leads (Back/BackStack): the page's Back, the tab that
        // opened this one, or nowhere, its chevron dimmed.
        let route = app.backStack.route(for: app.browser.tab)
        var opener: String?
        if case let .opener(id) = route, let tab = app.browser.tab(id) { opener = BackStack.host(of: tab) }
        button.overrideUserInterfaceStyle = isPrivate || context.environment.colorScheme == .dark ? .dark : .light
        button.setAppearance(isPrivate: isPrivate, dimmed: route == .nowhere)
        button.setFolded(folded, animated: context.transaction.animation != nil && !context.transaction.disablesAnimations)
        button.isAccessibilityElement = isAccessible
        button.accessibilityElementsHidden = !isAccessible
        button.accessibilityIdentifier = isAccessible ? "chrome.back" : nil
        button.accessibilityLabel = "Back"
        button.accessibilityHint = opener.map { "Closes this tab and goes back to \($0)" }
        button.accessibilityValue = ""
        button.isEnabled = isAccessible && route != .nowhere
        button.isUserInteractionEnabled = button.isEnabled
        // VoiceOver's way to the opener, by its name.
        button.setOpenerAction(isAccessible ? opener : nil) { [weak app] in
            guard let app, case .opener = app.backStack.route(for: app.browser.tab) else { return false }
            app.backStack.backToOpener()
            return true
        }
        // Held: the tab's way back as iOS's menu (Back/BackHistoryMenu).
        let history = route == .history ? app.browser.tab?.id : nil
        button.bindHistory(history.flatMap { app.pages.backList($0).isEmpty ? nil : $0 }) { [weak app] id in
            app?.backHistoryMenu(for: id) ?? []
        }
        button.onTap = { [weak app, weak button] in
            guard let app, let button, owner == ChromePlusOwner(app: app),
                  button.isEnabled, button.window?.windowScene?.activationState == .foregroundActive,
                  UIApplication.shared.applicationState == .active, !app.privateContentBlocked,
                  !app.surfaces.coversChrome, !app.surfaces.settings, !app.surfaces.join,
                  app.surfaces.chat == nil, app.surfaces.menu == nil,
                  (!app.chrome.folded || app.workspace.verticalControls), app.surfaces.chromeOpacity > 0.5 else { return }
            app.goBack()
        }
    }

    static func dismantleUIView(_ button: ToolbarLeftButton, coordinator: ()) {
        button.onTap = nil
        button.isEnabled = false
        button.bindHistory(nil) { _ in [] }
        button.setOpenerAction(nil) { false }
    }
}

final class ToolbarLeftButton: UIButton {
    let glass = UIVisualEffectView()
    let foreground = UIImageView()
    private var imageMade = false
    private var privateAppearance: Bool?
    private var effect: UIGlassEffect?
    private var dimmed = false
    private var folded = false
    var onTap: (() -> Void)?
    /// The tab whose way back the held menu shows; nil, no menu.
    private var historyTab: Tab.ID?
    private var openerActionName: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [glass, foreground] {
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            addSubview(view)
        }
        foreground.contentMode = .center
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        showsMenuAsPrimaryAction = false
        preferredMenuElementOrder = .fixed
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The held menu for a tab, its rows made each time it opens, so they
    /// are the tab's pages then. The same tab keeps the menu it has.
    func bindHistory(_ tab: Tab.ID?, rows: @escaping (Tab.ID) -> [UIMenuElement]) {
        guard tab != historyTab || (tab != nil) != (menu != nil) else { return }
        historyTab = tab
        isContextMenuInteractionEnabled = tab != nil
        guard let tab else { contextMenuInteraction?.dismissMenu(); menu = nil; return }
        menu = UIMenu(children: [UIDeferredMenuElement.uncached { completion in completion(rows(tab)) }])
    }

    /// "Back to google.com" among VoiceOver's actions while ‹ goes there.
    func setOpenerAction(_ host: String?, action: @escaping () -> Bool) {
        let name = host.map { "Back to \($0)" }
        guard name != openerActionName else { return }
        openerActionName = name
        accessibilityCustomActions = name.map { name in
            [UIAccessibilityCustomAction(name: name) { _ in action() }]
        }
    }

    func setAppearance(isPrivate: Bool, dimmed: Bool = false) {
        if privateAppearance != isPrivate {
            privateAppearance = isPrivate
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            effect.tintColor = isPrivate ? UIColor(Ink.privateGlass.opacity(0.78)) : nil
            self.effect = effect
            if !folded { glass.effect = effect }
        }
        tintColor = isPrivate ? .white : .label
        if !imageMade {
            imageMade = true
            foreground.image = ChromePlusControl.image(.chevronLeft, size: Metrics.Chrome.backIcon)
        }
        self.dimmed = dimmed
        foreground.alpha = folded ? 0 : dimmed ? Metrics.Back.dimmed : 1
        setNeedsLayout()
    }

    /// Folded, the button melts: its glass dematerializes (the
    /// effect animated away, which an alpha on glass can't do) and ‹ fades.
    func setFolded(_ on: Bool, animated: Bool) {
        guard on != folded else { return }
        folded = on
        let change = {
            self.glass.effect = on ? nil : self.effect
            self.foreground.alpha = on ? 0 : self.dimmed ? Metrics.Back.dimmed : 1
        }
        guard animated, !Motion.disabled else { change(); return }
        UIView.animate(withDuration: Motion.chromeButtons.duration, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut], animations: change)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        foreground.frame = bounds
        bringSubviewToFront(foreground)
    }

    @objc private func pressed() { onTap?() }
}

/// The page address uses one UIButton and one UILabel. Its meaning changes
/// without removing, dimming or cross-fading foreground.
struct ToolbarPlateControl: UIViewRepresentable {
    @Environment(AppModel.self) private var app
    let owner: ChromePlusOwner
    let readerAvailable: Bool
    let readerEnabled: Bool
    /// Translate's word for the page ("Translating…", "Translated"), if any.
    var translation: String? = nil
    let pagingActive: Bool
    let tab: Tab?
    let folded: Bool
    /// The fold as it moves (PlateFolding): 0 open, 1 folded. The words'
    /// size and their room beside ≡ and ↻ follow it with the plate.
    var fold: CGFloat = 0
    let sourceAccessible: Bool
    let origin: CGRect

    func makeUIView(context: Context) -> ToolbarPlateButton { ToolbarPlateButton(type: .custom) }

    func updateUIView(_ button: ToolbarPlateButton, context: Context) {
        let privateInk = owner.isPrivate
        let size = Metrics.Chrome.labelFont + (Metrics.Chrome.minLabelFont - Metrics.Chrome.labelFont) * fold
        let font = PlateWords.font(pointSize: size,
                                   weight: Metrics.Chrome.labelWeight, dynamicType: context.environment.dynamicTypeSize)
        let ink = UIColor(privateInk ? Ink.onDark : Ink.primary)
        button.overrideUserInterfaceStyle = privateInk || context.environment.colorScheme == .dark ? .dark : .light
        button.words.font = font
        button.words.textColor = ink
        let words = NSMutableAttributedString(string: tab.map(PlateLabel.address) ?? "New Tab",
            attributes: [.font: font, .foregroundColor: ink, .kern: -0.02 * font.pointSize])
        // The empty page: "+ New Tab", the plate is the way out of it.
        if tab == nil, let plus = ChromePlusControl.image(.plusMedium, size: Metrics.Chrome.emptyPlus)?.withTintColor(ink, renderingMode: .alwaysOriginal) {
            let mark = NSTextAttachment(image: plus)
            mark.bounds = CGRect(x: 0, y: (font.capHeight - plus.size.height) / 2, width: plus.size.width, height: plus.size.height)
            words.insert(NSAttributedString(string: " "), at: 0)
            words.insert(NSAttributedString(attachment: mark), at: 0)
        }
        button.words.attributedText = words
        button.words.isHidden = pagingActive
        // Translate's word ("Translating…", "Translated") stands where
        // Reader's does, Reader on first.
        let translated = pagingActive ? nil : translation
        let hint = !folded && (readerAvailable || readerEnabled || translated != nil)
        button.reader.text = readerEnabled ? "Reader" : translated ?? "Reader Available"
        button.reader.font = PlateWords.font(pointSize: Metrics.Chrome.readerHintFont, weight: .regular,
                                             dynamicType: context.environment.dynamicTypeSize)
        button.reader.textColor = UIColor(privateInk ? Ink.onDark : Ink.secondary)
        // Reader comes or goes on a page at rest: the address rises and the
        // line comes in under it, on the fold's own curve.
        button.setReaderShare(hint ? 1 : 0, animated: !Motion.disabled)
        button.sourcePadding = Metrics.touch * (1 - fold)
        button.setNeedsLayout()
        // Action authority only at a committed, uncovered page.
        let committed = !app.surfaces.pageSwiping && app.surfaces.chromeOpacity > 0.5
        let accessible = committed && sourceAccessible
        button.isEnabled = accessible
        button.isUserInteractionEnabled = accessible
        button.isAccessibilityElement = accessible
        button.accessibilityElementsHidden = !accessible
        button.accessibilityIdentifier = accessible ? "chrome.plate" : nil
        button.accessibilityLabel = tab.map { "\($0.site), \($0.short)" } ?? "New Tab"
        button.accessibilityValue = folded ? "folded" : "open"
        button.accessibilityHint = tab == nil ? "Opens a new tab" : "Shows the address and asks about this page"
        let role: ToolbarPlateButton.Role = accessible ? (folded ? .foldedPage : .page) : .inactive
        let epoch = button.bind(owner: owner, role: role)
        func current(_ app: AppModel, _ button: ToolbarPlateButton) -> Bool {
            guard button.isEnabled, button.accepts(epoch), owner == ChromePlusOwner(app: app),
                  button.window?.windowScene?.activationState == .foregroundActive,
                  UIApplication.shared.applicationState == .active, !app.privateContentBlocked,
                  !app.surfaces.coversChrome, !app.surfaces.settings, !app.surfaces.join,
                  app.surfaces.chat == nil, app.surfaces.menu == nil else { return false }
            return !app.surfaces.pageSwiping && app.surfaces.chromeOpacity > 0.5
        }
        button.onTap = { [weak app, weak button] in
            guard let app, let button, current(app, button) else { return }
            if folded { app.chrome.fold(false) }
            guard app.browser.tab != nil else { return app.openNewTab(from: origin) }
            Motion.fieldOpen.run { app.surfaces.openField(.address, from: origin) }
        }
        button.setHold(!folded && accessible && tab != nil ? { [weak app, weak button] in
            guard let app, let button, current(app, button) else { return }
            app.openPageMenu()
        } : nil)
        button.accessibilityCustomActions = accessible ? [
            UIAccessibilityCustomAction(name: "Show Tabs") { [weak app, weak button] _ in
                guard let app, let button, current(app, button) else { return false }
                Haptics.play(.light, reason: Haptics.Reason.columnOpened)
                app.field.openSpaces(); return true
            },
            UIAccessibilityCustomAction(name: "Next Tab") { [weak app, weak button] _ in
                guard let app, let button, current(app, button) else { return false }
                app.surfaces.paging?.step(1); return app.surfaces.paging != nil
            },
            UIAccessibilityCustomAction(name: "Previous Tab") { [weak app, weak button] _ in
                guard let app, let button, current(app, button) else { return false }
                app.surfaces.paging?.step(-1); return app.surfaces.paging != nil
            }
        ] : nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ToolbarPlateButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? origin.width, height: max(Metrics.touch, proposal.height ?? origin.height))
    }

    static func dismantleUIView(_ button: ToolbarPlateButton, coordinator: ()) { button.retire() }
}

final class ToolbarPlateButton: UIButton {
    private let wordsBox = HeadFadeLabel()
    var words: UILabel { wordsBox.label }
    let reader = UILabel()
    private let hold = UILongPressGestureRecognizer()
    private var onHold: (() -> Void)?
    private var heldAt: Date?
    enum Role: Equatable { case page, foldedPage, inactive }
    private struct Binding: Equatable {
        let owner: ChromePlusOwner
        let role: Role
    }
    private var binding: Binding?
    private var epoch = UUID()
    private var retired = false
    var onTap: (() -> Void)?
    var sourcePadding: CGFloat = 0
    private(set) var readerShare: CGFloat = 0

    func setReaderShare(_ share: CGFloat, animated: Bool) {
        guard share != readerShare else { return }
        let jump = abs(share - readerShare) > 0.5
        readerShare = share
        guard animated, jump, window != nil else {
            reader.alpha = share
            setNeedsLayout()
            return
        }
        UIView.animate(withDuration: Motion.chromeFold.duration, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
            self.reader.alpha = share
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        reader.numberOfLines = 1; reader.lineBreakMode = .byTruncatingTail; reader.textAlignment = .center
        reader.adjustsFontForContentSizeCategory = true
        for view in [wordsBox, reader] {
            view.isAccessibilityElement = false; view.accessibilityElementsHidden = true
            view.isUserInteractionEnabled = false; addSubview(view)
        }
        reader.clipsToBounds = true
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        hold.minimumPressDuration = 0.46; hold.allowableMovement = 7
        hold.addTarget(self, action: #selector(held(_:))); addGestureRecognizer(hold)
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width - sourcePadding * 2)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let wordsHeight = ceil(words.font.lineHeight)
        let naturalHint = ceil(reader.font.lineHeight)
        // Preserve ViewThatFits' single-line fallback if both rows cannot fit.
        let hintHeight = wordsHeight + naturalHint <= bounds.height ? naturalHint * readerShare : 0
        let groupHeight = wordsHeight + hintHeight
        let textWidth = min(width, ceil(words.intrinsicContentSize.width))
        wordsBox.frame = CGRect(x: center.x - textWidth / 2, y: center.y - groupHeight / 2, width: textWidth, height: wordsHeight)
        reader.frame = CGRect(x: center.x - width / 2, y: wordsBox.frame.maxY, width: width, height: hintHeight)
        wordsBox.setNeedsLayout()
        bringSubviewToFront(wordsBox); bringSubviewToFront(reader)
    }

    /// The button's own frame on the screen, which the hosting SwiftUI
    /// container wouldn't report for it.
    override var accessibilityFrame: CGRect {
        get {
            guard let window else { return super.accessibilityFrame }
            return window.convert(convert(bounds, to: window), to: window.screen.coordinateSpace)
        }
        set { super.accessibilityFrame = newValue }
    }

    func bind(owner: ChromePlusOwner, role: Role) -> UUID {
        let next = Binding(owner: owner, role: role)
        if next != binding { binding = next; epoch = UUID() }
        return epoch
    }
    func accepts(_ captured: UUID) -> Bool { !retired && epoch == captured }

    func setHold(_ action: (() -> Void)?) { onHold = action; hold.isEnabled = action != nil }
    func retire() {
        retired = true; epoch = UUID(); binding = nil
        onTap = nil; setHold(nil); accessibilityCustomActions = nil; isEnabled = false
    }
    @objc private func pressed() {
        if let held = heldAt {
            heldAt = nil
            if Date().timeIntervalSince(held) < 2 { return }
        }
        onTap?()
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, isEnabled, onHold != nil else { return }
        heldAt = Date(); onHold?()
    }
}
