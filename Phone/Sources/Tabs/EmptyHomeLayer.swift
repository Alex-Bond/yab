import SwiftUI

extension Metrics {
    enum EmptyHome {
        /// The hint and its arrow, their foot this far over +.
        static let hintOverPlus: CGFloat = 14
        static let hintGap: CGFloat = 6
        static let arrow: CGFloat = 13
    }
}

extension AppModel {
    /// No tab in front, on an iPhone's ordinary space.
    var emptyHome: Bool { !workspace.tabletControls && browser.tab == nil && !browser.space.isPrivate }
    /// And no tab waiting in the stack: the bar is All Tabs' own, the plate has nothing to show.
    var emptyHomeBar: Bool { emptyHome && TabStack.of(self).order.isEmpty }
}

/// No tabs: All Tabs with its cards gone. The same ground and
/// the same three buttons, so the last card closed only takes its card away,
/// and a word over + saying where search is. A tab waiting in the stack (one
/// a Mac opened) keeps the page's bar and its circle.
struct EmptyHomeLayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    private typealias E = Metrics.EmptyHome

    var body: some View {
        GeometryReader { geo in
            if app.emptyHome {
                content(geo.size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(app.emptyHome)
    }

    private func content(_ size: CGSize) -> some View {
        let layout = TabGalleryLayout(screen: size, count: 0, verticalControls: app.workspace.verticalControls,
                                      leadingRail: app.workspace.leadingRail)
        let dark = TabGalleryGround.isDark(app)
        let ink = dark ? Ink.onDark : Ink.primary
        // While the first run hands the screen over, this ground is only what
        // stands behind the chain's last move: its own hint and buttons would
        // show through the leaving step, so they wait for the hand-over to end
        // (Welcome/FirstRun.toEnd).
        let handing = FirstRun.shared.handsOver
        let bar = app.emptyHomeBar && !handing
        return ZStack(alignment: .topLeading) {
            TabGalleryGround(space: app.browser.space, dark: colorScheme == .dark)
                .contentShape(Rectangle())
                .onTapGesture { if app.emptyHomeBar { app.openNewTab(from: layout.plus) } }
                .gesture(lift)
                .accessibilityHidden(true)

            VStack(spacing: E.hintGap) {
                Text("Tap to search")
                    .font(.callout)
                Image(systemName: "arrow.down")
                    .font(.system(size: E.arrow, weight: .medium))
            }
            .foregroundStyle(dark ? Ink.onDark.opacity(0.6) : Ink.rowSubtitle)
            .frame(width: size.width)
            .position(x: size.width / 2, y: layout.plus.minY - E.hintOverPlus - 24)
            // Undo stands here for its seconds.
            .opacity(app.surfaces.toast == nil && !handing ? 1 : 0)
            .animation(Motion.disabled ? nil : Motion.crossFade.animation, value: app.surfaces.toast == nil)
            .animation(Motion.disabled ? nil : Motion.crossFade.animation, value: handing)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if bar {
                let new = layout.plus, chats = layout.chats, gear = layout.gear
                button(.plusMedium, new, Capsule(style: .continuous), ink: Ink.primary, label: "New Tab", id: "empty.new") {
                    app.openNewTab(from: new)
                }
                if app.field.sheetAllowed {
                    button(SettingsFieldRow.glyph, chats, Circle(), ink: ink, label: "Settings", id: "empty.settings") {
                        Motion.sheetGrow.run { app.surfaces.openSettings() }
                    }
                } else {
                    // Settings keeps the left on every empty screen, the one
                    // with a tab waiting in the stack too (SharedBottomToolbar
                    // puts it where ‹ stands there), so the two never disagree.
                    button(SettingsFieldRow.glyph, chats, Circle(), ink: ink, label: "Settings", id: "empty.settings") {
                        Motion.sheetGrow.run { app.surfaces.openSettings() }
                    }
                    button(.bubbles, gear, Circle(), ink: ink, label: "Chats", id: "empty.chats") {
                        NewTabPager.shared.startAt = NewTabPager.chatsPage
                        app.openNewTab(from: gear)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty.home")
    }

    private func button<S: Shape>(_ glyph: GlyphName, _ rect: CGRect, _ shape: S, ink: Color, label: String, id: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(glyph, size: Metrics.Chrome.spaceEmoji, color: ink)
                .frame(width: rect.width, height: rect.height)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: shape)
        .position(x: rect.midX, y: rect.midY)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Up from the ground, as from the plate: the spaces, under the finger.
    private var lift: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard value.translation.height < 0 else { return }
                app.field.beginLift()
                app.field.liftMoved(value.translation.height)
            }
            .onEnded { value in
                app.field.liftEnded(value.translation.height, velocity: value.velocity.height)
            }
    }
}

/// The dot grid under All Tabs and the empty screen.
struct TabGroundDots: View {
    let dark: Bool

    private static let step: CGFloat = 20
    private static let dot: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            var y = Self.step / 2
            while y < size.height {
                var x = Self.step / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: Self.dot, height: Self.dot))
                    x += Self.step
                }
                y += Self.step
            }
            context.fill(dots, with: .color((dark ? Color.white : Color.black).opacity(dark ? 0.1 : 0.12)))
        }
        .allowsHitTesting(false)
    }
}
