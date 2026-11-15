import SwiftUI

/// All Tabs over the page, a gallery (TabGalleryLayout,
/// TabGalleryMotion): the cards on the space's own ground, each with its
/// site's icon over it and the focus card's title, + in a wide glass capsule
/// on the bar, Settings' gear at its right. Swipe sideways to bring older
/// tabs to the focus, a card up to close it, tap one to open it. Pictures
/// only, never live pages: each card's last picture (TabStack.picture), and
/// a card that has none warms up under the ground (TabWarmup) and
/// cross-fades from its icon. While it is up it draws the stack's glass
/// circle too, under the cards, so they can come out of it and fly back in.
struct TabGalleryLayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    private enum Hold: Equatable { case scroll(from: CGFloat), card(Tab.ID), none }
    @State private var hold: Hold?

    private typealias G = Metrics.TabGallery

    var body: some View {
        GeometryReader { geo in
            let stack = TabStack.of(app)
            if let gallery = stack.gallery {
                content(stack, gallery, geo.size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(TabStack.of(app).gallery != nil)
    }

    private func content(_ stack: TabStack, _ g: TabStack.Gallery, _ size: CGSize) -> some View {
        let tabs = stack.cards(of: g)
        let layout = TabGalleryLayout(screen: size, count: tabs.count,
                                      verticalControls: app.workspace.galleryVerticalControls, leadingRail: app.workspace.leadingRail,
                                      circle: app.workspace.statusColumn ? stack.stackGeometry.circle : nil,
                                      across: app.workspace.galleryAcross)
        let poses = tabs.enumerated().map { i, tab in stack.pose(i, of: tab, in: g, layout: layout) }
        let dark = TabGalleryGround.isDark(app)
        let at = g.phase == .open
        let seated = stack.seatedCards(g, layout: layout)
        // The circle shows + when there is no tab at all; one tab stands in it
        // as it will on the page's button, so nothing swaps as All Tabs goes.
        let plusInCircle = tabs.isEmpty
        let lone = tabs.count == 1 ? tabs.first : nil
        // Drawn again as pictures come (read from the disk, warmed up).
        _ = stack.pictures
        // Only the cards that can show draw a picture (TabGalleryLayout.draws).
        // Opening and closing, every card that moves shows its page, the ones
        // flying into the stack's circle too; at rest only the cards in sight.
        let images = tabs.enumerated().map { i, tab in g.phase != .open || layout.draws(i, focus: g.focus) ? stack.picture(tab) : nil }
        // Closing, the card opened grows into the whole page: the circle, its
        // gear and its seated cards go over it (the chrome is over the page),
        // still under the cards flying in, which lay on it. Under it the
        // circle was hidden from its first frames until All Tabs was gone.
        let chosenZ = g.phase == .closing ? tabs.firstIndex { $0.id == g.chosen }.map { poses[$0].z } : nil
        let circleZ = { (z: Double) in chosenZ.map { $0 + (z + 3.5) / 4 } ?? z }
        return ZStack(alignment: .topLeading) {
            // Where cards with no picture load out of sight, under the ground.
            TabWarmupStageView(stack: stack)
                .frame(width: size.width, height: size.height)
                .position(x: size.width / 2, y: size.height / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(-20)
            // The ground: whole over the page's content area at once; under
            // the chrome's row it comes and goes with the bar, so the page's
            // own chrome crosses over to the gallery's there.
            TabGalleryGround(space: app.browser.space, dark: colorScheme == .dark)
                .mask {
                    VStack(spacing: 0) {
                        Rectangle().frame(height: layout.content.maxY)
                        Rectangle().opacity(Double(g.bar))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { stack.chooseFront() }
                .accessibilityHidden(true)
                .zIndex(-10)
            circle(stack.stackGeometry.circle, offset: stack.circleOffset(g), plus: plusInCircle, lone: lone.flatMap(stack.picture),
                   hasLone: lone != nil, isPrivate: app.browser.space.isPrivate)
                .zIndex(circleZ(-3))
            ForEach(seated) { card in
                face(card.tab, pose: card.pose, image: stack.picture(card.tab), screen: size)
                    .opacity(card.pose.opacity)
                    .rotationEffect(.degrees(Double(card.pose.angle)))
                    .position(x: card.pose.rect.midX, y: card.pose.rect.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(circleZ(card.pose.z))
            }
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                card(tab, pose: poses[i], image: images[i], screen: size, ink: dark ? Ink.onDark : Ink.primary,
                     stack: stack, tappable: g.phase != .closing)
                    .zIndex(poses[i].z)
            }
            // Its target belongs to All Tabs as soon as the bar starts coming in.
            plus(stack, layout: layout, shown: g.bar, accessible: g.phase != .closing)
                .zIndex(10_000)
            chats(stack, layout: layout, shown: g.bar, accessible: at, ink: dark ? Ink.onDark : Ink.primary)
                .zIndex(10_000)
            // Where the circle is: over its glass, under the cards flying into
            // it. Closing, its glass gives way to the circle's as the bar comes
            // back, its glyph is gone in 0.1 s, before the cards land.
            gear(stack, layout: layout, shown: g.bar, accessible: at, ink: dark ? Ink.onDark : Ink.primary,
                 glyph: g.phase == .closing ? Double(g.barFrom) * max(0, 1 - g.time / TabGalleryTiming.othersFade) : 1)
                .zIndex(circleZ(-2.5))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .simultaneousGesture(drag(stack, g, layout, tabs))
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabs.gallery")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { stack.chooseFront() }
    }

    /// + in its wide glass capsule, where the plate's middle is.
    private func plus(_ stack: TabStack, layout: TabGalleryLayout, shown: CGFloat, accessible: Bool) -> some View {
        let rect = layout.plus
        return Button {
            stack.galleryNewTab(from: rect)
        } label: {
            Glyph(.plusMedium, size: Metrics.Chrome.spaceEmoji, color: Ink.primary)
                .frame(width: rect.width, height: rect.height)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        .opacity(Double(shown))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(accessible)
        .accessibilityLabel("New Tab")
        .accessibilityIdentifier("tabs.new")
        .accessibilityHidden(!accessible)
    }

    /// Chats on their glass at the bar's left: the spaces open on their Chats
    /// page, grown from the button, over the cards (as New Tab from +).
    private func chats(_ stack: TabStack, layout: TabGalleryLayout, shown: CGFloat, accessible: Bool, ink: Color) -> some View {
        let rect = layout.chats
        let settings = app.field.sheetAllowed
        return Button {
            if settings { stack.gallerySettings() } else { stack.galleryChats(from: rect) }
        } label: {
            Glyph(settings ? SettingsFieldRow.glyph : .bubbles, size: Metrics.Chrome.spaceEmoji, color: ink)
                .frame(width: rect.width, height: rect.height)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .opacity(Double(shown))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(accessible)
        .accessibilityLabel(settings ? "Settings" : "Chats")
        .accessibilityIdentifier(settings ? "tabs.settings" : "tabs.chats")
        .accessibilityHidden(!accessible)
    }

    /// Settings' gear on its glass, at the bar's right; Settings
    /// opens over All Tabs and closes back to it.
    private func gear(_ stack: TabStack, layout: TabGalleryLayout, shown: CGFloat, accessible: Bool, ink: Color, glyph: Double) -> some View {
        let rect = layout.gear
        let done = app.field.sheetAllowed
        return Button {
            if done { stack.chooseFront() } else { stack.gallerySettings() }
        } label: {
            Group {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Glyph(SettingsFieldRow.glyph, size: Metrics.Chrome.spaceEmoji, color: ink)
                }
            }
            .opacity(shown > 0 ? min(1, glyph / Double(shown)) : 0)
            .frame(width: rect.width, height: rect.height)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(done ? .regular.tint(Color.accentColor).interactive() : .regular.interactive(), in: Circle())
        .opacity(Double(shown))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(accessible)
        .accessibilityLabel(done ? "Done" : "Settings")
        .accessibilityIdentifier(done ? "tabs.done" : "tabs.settings")
        .accessibilityHidden(!accessible)
    }

    /// The stack's glass circle where the chrome's right button is (lent to
    /// All Tabs meanwhile, ChromePlusControl.lent): as much of it shows as of
    /// the chrome, and it comes up from below as All Tabs closes on the top
    /// card. The same glass as the button's, Private's dark one.
    private func circle(_ rect: CGRect, offset: CGFloat, plus: Bool, lone: UIImage?, hasLone: Bool, isPrivate: Bool) -> some View {
        typealias M = Metrics.TabStack
        return ZStack {
            Color.clear
            if plus { Glyph(.plusMedium, size: Metrics.Chrome.spaceEmoji, color: isPrivate ? Ink.onDark : Ink.primary) }
            if hasLone {
                // The lone tab's card, as the stack's button draws it (TabStackView).
                let shape = RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous)
                Group {
                    if let lone {
                        Image(uiImage: lone).resizable().scaledToFill()
                    } else {
                        Color.white
                    }
                }
                .frame(width: M.cardWidth, height: M.cardHeight, alignment: .top)
                .clipShape(shape)
                .rotationEffect(.degrees(Double(M.frontTurn)))
                .offset(x: M.front.x, y: M.front.y)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .glassEffect(isPrivate ? GlassTone.privateTab.glass(for: .dark) : .regular, in: Circle())
        .glassEffectTransition(.identity)
        .opacity(app.surfaces.chromeOpacity)
        .position(x: rect.midX, y: rect.midY + offset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A card's face: the page's content area under its veil, inside its
    /// corners, with the stack's rim and shadow as far as it wears them.
    private func face(_ tab: Tab, pose: TabCardPose, image: UIImage?, screen: CGSize) -> some View {
        typealias M = Metrics.TabStack
        let shape = RoundedRectangle(cornerRadius: pose.radius, style: .continuous)
        return picture(tab, pose: pose, image: image, screen: screen)
            .overlay { Color.black.opacity(pose.veil) }
            .frame(width: pose.rect.width, height: pose.rect.height)
            .clipShape(shape)
            .overlay {
                if pose.rim > 0.001 {
                    shape.strokeBorder(Color.white.opacity(Double(M.rimAlpha) * Double(pose.rim)), lineWidth: M.rim)
                }
            }
            .background {
                if pose.rim > 0.001 {
                    shape.fill(Color.black)
                        .shadow(color: .black.opacity(Double(M.shadowAlpha) * Double(pose.rim)),
                                radius: M.shadowRadius * pose.rim, y: M.shadowY * pose.rim)
                }
            }
    }

    @ViewBuilder private func picture(_ tab: Tab, pose: TabCardPose, image: UIImage?, screen: CGSize) -> some View {
        let stack = TabStack.of(app)
        let pair = stack.pairTabs(for: tab)
        if pair.count == 2 {
            HStack(spacing: 2) {
                ForEach(pair) { page in
                    TabPicture(tab: page, image: stack.picture(page), cropTop: pose.cropTop,
                               screen: CGSize(width: screen.width / 2, height: screen.height))
                        .frame(maxWidth: .infinity).clipped()
                }
            }
            .accessibilityIdentifier("tabs.split.preview")
        } else { TabPicture(tab: tab, image: image, cropTop: pose.cropTop, screen: screen) }
    }

    /// One card: its face turned as it is, its icon and (at the focus) its
    /// title over its top-left corner.
    private func card(_ tab: Tab, pose: TabCardPose, image: UIImage?, screen: CGSize, ink: Color, stack: TabStack,
                      tappable: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: pose.radius, style: .continuous)
        return face(tab, pose: pose, image: image, screen: screen)
            .contentShape(shape)
            .overlay(alignment: .topLeading) {
                label(tab, pose: pose, ink: ink)
            }
            .overlay(alignment: .bottom) {
                if !stack.pairTabs(for: tab).isEmpty {
                    Text("Split View").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12).opacity(pose.rim)
                        .accessibilityHidden(true)
                }
            }
            .opacity(pose.opacity)
            .rotationEffect(.degrees(Double(pose.angle)))
            .position(x: pose.rect.midX, y: pose.rect.midY)
            .onTapGesture { if tappable { stack.choose(tab.id) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stack.pairTabs(for: tab).isEmpty ? tab.title : "Split View, " + stack.pairTabs(for: tab).map(\.title).joined(separator: ", "))
            .accessibilityValue(value(tab, pictured: image != nil))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("tabs.card.\(tab.id)")
            .accessibilityAction { stack.choose(tab.id) }
            .accessibilityAction(named: stack.pairTabs(for: tab).isEmpty ? "Close" : "Close Focused Page") { stack.closeCard(tab.id) }
    }

    /// Where the tab is; test runs also say what the card shows, its page's
    /// picture or the icon standing in (UITests/TabPicturesUITests).
    private func value(_ tab: Tab, pictured: Bool) -> String {
        let place = tab.id == app.browser.tab?.id ? "current" : tab.addressHost
        guard LaunchOptions.current.isTestRun else { return place }
        return place + (pictured ? ", picture" : ", icon")
    }

    /// The icon 18 in from the card's left edge and 8 over its top, the
    /// title after it; both follow the card's size as it grows and shrinks.
    private func label(_ tab: Tab, pose: TabCardPose, ink: Color) -> some View {
        let pair = TabStack.of(app).pairTabs(for: tab)
        return HStack(spacing: G.labelGap) {
            Favicon(icon: tab.icon, host: tab.host, size: G.labelIcon, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                .opacity(pose.icon)
            if pair.count == 2, let other = pair.first(where: { $0.id != tab.id }) {
                Favicon(icon: other.icon, host: other.host, size: G.labelIcon, url: other.navigationURL,
                        isPrivate: other.isPrivate, mark: other.customMark).opacity(pose.icon)
            }
            Text(pair.count == 2 ? pair.map(\.title).joined(separator: " + ") : tab.title)
                .font(.system(size: G.labelFont, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .frame(width: pose.titleWidth, alignment: .leading)
                .opacity(pose.title)
        }
        .frame(height: G.labelIcon)
        .fixedSize()
        // Scaled about its bottom-left corner, which then stands 8 (scaled)
        // over the card's top and 18 (scaled) in from its left edge.
        .scaleEffect(max(0.01, pose.labelScale), anchor: .bottomLeading)
        .offset(x: G.labelInset * pose.labelScale, y: -(G.labelIcon + G.labelRise * pose.labelScale))
        .allowsHitTesting(false)
    }

    /// Sideways moves the cards; up from a card takes it, to close it.
    private func drag(_ stack: TabStack, _ g: TabStack.Gallery, _ layout: TabGalleryLayout, _ tabs: [Tab]) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard g.phase == .open else { return }
                if hold == nil {
                    let t = value.translation
                    if abs(t.width) > abs(t.height) { hold = .scroll(from: g.focus) }
                    else if t.height < 0, let i = layout.card(at: value.startLocation, focus: g.focus), tabs.indices.contains(i) {
                        hold = .card(tabs[i].id)
                    } else { hold = Hold.none }
                }
                switch hold {
                case let .scroll(from)?: stack.scrollGallery(to: layout.resisted(from - value.translation.width / layout.step))
                case let .card(id)?: stack.liftCard(id, by: value.translation.height)
                default: break
                }
            }
            .onEnded { value in
                switch hold {
                case let .scroll(from)?:
                    stack.settleScroll(TabGalleryLayout.settle(from: from, moved: from - value.translation.width / layout.step,
                                                               thrown: from - value.predictedEndTranslation.width / layout.step))
                case let .card(id)?: stack.releaseCard(id, dy: value.translation.height, velocity: value.velocity.height)
                default: break
                }
                hold = nil
            }
    }
}

/// All Tabs' ground: the space's own wash, as its card in the spaces has it
/// (SpacePagesCard: the tint, lighter at the top, darker in dark mode);
/// Private's dark one.
struct TabGalleryGround: View {
    let space: Space
    let dark: Bool

    var body: some View {
        // The look's own color, the one picked on Color, not the pale wash.
        // Dark: the Mac's dark shade of the space, as its column wears it.
        let tint = space.isPrivate ? SpacePagesCard.privateWash
            : dark ? space.folderGround(dark: true) : space.look?.ground ?? space.tint
        let lighten = space.isPrivate ? 0 : dark ? 0.06 : 0.35
        let light = { (v: Int) in (Double(v) + (255 - Double(v)) * lighten) / 255 }
        ZStack {
            LinearGradient(colors: [Color(red: light(tint.r), green: light(tint.g), blue: light(tint.b)),
                                    Color(red: Double(tint.r) / 255, green: Double(tint.g) / 255, blue: Double(tint.b) / 255)],
                           startPoint: .top, endPoint: .bottom)
            if !space.isPrivate {
                LookGrainFill(amount: space.look?.grain ?? 0)
                TabGroundDots(dark: dark)
            }
        }
    }

    /// Light words over it, and a light status bar: Private's, or in dark mode.
    @MainActor static func isDark(_ app: AppModel) -> Bool {
        app.browser.space.isPrivate || AppAppearance.current == .dark
    }
}
