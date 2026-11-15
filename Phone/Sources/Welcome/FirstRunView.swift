import SwiftUI
import UIKit

/// The first run's stage: the prototype's 402 × 874 drawing, scaled to the
/// screen. Every piece is one view for the whole run whose box is a function
/// of the step, so a step change moves the same thing from where it was to
/// where it goes (forward or back), never a cross-fade between two copies.
/// With Reduce Motion the whole stage cross-fades instead.
struct FirstRunView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    /// How much of the screen the keyboard covers.
    @State private var keyboard: CGFloat = 0
    private var run: FirstRun { .shared }

    var body: some View {
        GeometryReader { proxy in
            let space = ChainSpace(proxy.size, tablet: app.workspace.tabletControls, typeSize: typeSize)
            ZStack(alignment: .topLeading) {
                FirstRunGround()
                    .opacity(run.step == .end ? 0 : 1)
                    .animation(FirstRun.motion(.easeOut(duration: 0.14)), value: run.step)
                    .ignoresSafeArea()
                ChainStage(space: space, keyboard: keyboard)
                    .id(Motion.reduced ? AnyHashable(ReducedKey(run)) : AnyHashable(0))
                    .transition(.opacity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // The keyboard rising under the chain must not move the stage or
            // restart its morph: the field it travels to is where the sheet
            // puts it, keyboard or not.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let covered = max(0, proxy.frame(in: .global).maxY - frame.minY)
                withAnimation(FirstRun.motion(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.34))) { keyboard = min(proxy.size.height, covered) }
            }
            // Where the stage's field stands, so New Tab's own grows from it
            // when the model hands over (FirstRun.toEnd).
            .onChange(of: space.s, initial: true) { _, _ in
                let origin = proxy.frame(in: .global).origin
                run.fieldRect = space.rect(ChainGeo.field).offsetBy(dx: origin.x, dy: origin.y)
            }
        }
        .ignoresSafeArea()
        .onAppear { run.begin(app); FirstRunTilt.shared.start() }
        .onDisappear { FirstRunTilt.shared.stop() }
        // Joined while the code or the Recovery Key is up: a Mac let it in.
        .onChange(of: app.sync.phase) { _, now in
            if now == .on, run.step == .code || run.step == .recovery { run.succeed(app) }
            if now == .on, run.step == .mac, run.mac == .none { run.settle(app) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { run.returned() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome")
        .accessibilityAddTraits(.isModal)
    }

    /// What a Reduce Motion cross-fade turns on.
    private struct ReducedKey: Hashable {
        let step: FirstRun.Step, mac: FirstRun.MacState, accepted: Bool, isDefault: Bool
        @MainActor init(_ run: FirstRun) { step = run.step; mac = run.mac; accepted = run.accepted; isDefault = run.isDefault }
    }
}

/// The welcome's ground: lilac at the top into the page's white (dark: ink).
private struct FirstRunGround: View {
    var body: some View {
        LinearGradient(stops: [.init(color: AppearanceColors.color(0xF1EEFB, 0x1B1826), location: 0),
                               .init(color: AppearanceColors.color(0xFFFFFF, 0x000000), location: 0.62)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - the drawing's space

/// The prototype's 402 × 874 points on this screen: one scale, centred.
struct ChainSpace {
    let s: CGFloat
    let ox: CGFloat
    let oy: CGFloat
    let height: CGFloat
    /// Dynamic Type on the words (not on the code, which is read from across
    /// a desk): 1 at the default size.
    let type: CGFloat

    init(_ size: CGSize, tablet: Bool, typeSize: DynamicTypeSize) {
        s = max(0.5, min(size.width / 402, size.height / 874, tablet ? 1.2 : 1.25))
        ox = (size.width - 402 * s) / 2
        oy = max(0, (size.height - 874 * s) / 2)
        height = size.height
        let body = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: UITraitCollection(preferredContentSizeCategory: typeSize.uiCategory))
        type = min(1.7, max(0.82, body / 17))
    }

    func x(_ v: CGFloat) -> CGFloat { ox + v * s }
    func y(_ v: CGFloat) -> CGFloat { oy + v * s }
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: x(p.x), y: y(p.y)) }
    func rect(_ b: ChainGeo.Box) -> CGRect { CGRect(x: x(b.x), y: y(b.y), width: b.w * s, height: b.h * s) }
    /// A font of the drawing's size, grown with Dynamic Type up to `cap`.
    func font(_ size: CGFloat, _ weight: Font.Weight, cap: CGFloat = 1.7, design: Font.Design = .default) -> Font {
        .system(size: size * s * min(cap, type), weight: weight, design: design)
    }
}

private extension DynamicTypeSize {
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

/// The prototype's boxes (proto/sauce.js), in its 402 × 874 points.
enum ChainGeo {
    struct Box: Equatable {
        var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
        var r: Double = 0
        var o: Double = 1
        var rad: CGFloat = 0
    }

    static let welcomeDrop = Box(x: 126, y: 325, w: 150, h: 150)
    static let back = Box(x: 16, y: 62, w: 44, h: 44)
    static let hero = Box(x: 126, y: 170, w: 150, h: 150)
    static let under = Box(x: 151, y: 230, w: 100, h: 100, o: 0)
    static let blot = Box(x: 178, y: 232, w: 70, h: 70, o: 0)
    static let codeCard = Box(x: 16, y: 172, w: 370, h: 336, rad: 32)
    /// Fourteen groups of four, four to a line.
    static let recoveryCard = Box(x: 16, y: 172, w: 370, h: 314, rad: 32)
    /// Where the field stands in the search sheet the app opens (field.frame
    /// of search.new; the sheet itself is 16, 255, 370 x 159). The icon
    /// stretches into exactly that box, so nothing moves at the hand-over.
    /// A test run draws the sheet only with -YabSearchSheet or
    /// FieldModel.sheetInTests, which is why a plain shot shows the older
    /// full-screen New Tab instead.
    static let field = Box(x: 16, y: 266, w: 370, h: 48, rad: 24)
    /// The eyes in that field (field.eyes of search.new).
    static let eyes = Box(x: 344, y: 272, w: 36, h: 36)
    static let front = Box(x: 126, y: 170, w: 150, h: 150, r: -3)
    static let left = Box(x: 40, y: 206, w: 104, h: 104, r: -12)
    static let right = Box(x: 258, y: 206, w: 104, h: 104, r: 11)
    static let centre = CGPoint(x: 201, y: 400)

    /// The welcome's field: ink, marker, its colour, centre, size, turn.
    struct Sticker {
        let ink: String?
        let marker: String?
        let tint: Color
        let at: CGPoint
        let size: CGFloat
        let turn: Double
        var small: Bool { size <= 26 }
    }

    static let field24: [Sticker] = [
        Sticker(ink: "tabs", marker: "spaces", tint: FirstRunInk.teal, at: CGPoint(x: 66.5, y: 98), size: 76, turn: -14),
        Sticker(ink: "spark", marker: nil, tint: .clear, at: CGPoint(x: 286.5, y: 58), size: 26, turn: 0),
        Sticker(ink: "ai", marker: "ai", tint: FirstRunInk.violet, at: CGPoint(x: 164.5, y: 70), size: 52, turn: 8),
        Sticker(ink: "feedback", marker: "mail", tint: FirstRunInk.green, at: CGPoint(x: 226.5, y: 134), size: 82, turn: -4),
        Sticker(ink: "privacy", marker: "privacy", tint: FirstRunInk.blue, at: CGPoint(x: 364.5, y: 100), size: 78, turn: 12),
        Sticker(ink: nil, marker: "spot", tint: FirstRunInk.red, at: CGPoint(x: 120.5, y: 146), size: 16, turn: 0),
        Sticker(ink: "bookmark", marker: "bookmark", tint: FirstRunInk.purple, at: CGPoint(x: 90.5, y: 196), size: 64, turn: -14),
        Sticker(ink: "key", marker: "key", tint: FirstRunInk.yellow, at: CGPoint(x: 290.5, y: 206), size: 74, turn: -20),
        Sticker(ink: "spark", marker: nil, tint: .clear, at: CGPoint(x: 350.5, y: 180), size: 22, turn: 0),
        Sticker(ink: "search", marker: "spot", tint: FirstRunInk.orange, at: CGPoint(x: 192.5, y: 262), size: 66, turn: -8),
        Sticker(ink: "mail", marker: "doc", tint: FirstRunInk.blue, at: CGPoint(x: 48.5, y: 296), size: 70, turn: 12),
        Sticker(ink: "bringIn", marker: "bringIn", tint: FirstRunInk.sky, at: CGPoint(x: 362.5, y: 298), size: 82, turn: 0),
        Sticker(ink: nil, marker: "spot", tint: FirstRunInk.green, at: CGPoint(x: 144.5, y: 332), size: 14, turn: 0),
        Sticker(ink: nil, marker: "spot", tint: FirstRunInk.sky, at: CGPoint(x: 326.5, y: 244), size: 16, turn: 0),
        Sticker(ink: "spark", marker: nil, tint: .clear, at: CGPoint(x: 100.5, y: 258), size: 22, turn: 0),
        Sticker(ink: "credits", marker: "credits", tint: FirstRunInk.pink, at: CGPoint(x: 300.5, y: 350), size: 50, turn: 10),
        Sticker(ink: "extensions", marker: "extensions", tint: FirstRunInk.indigo, at: CGPoint(x: 114.5, y: 388), size: 56, turn: -12),
        Sticker(ink: "watch", marker: "history", tint: FirstRunInk.teal, at: CGPoint(x: 56.5, y: 444), size: 66, turn: -8),
        Sticker(ink: "folder", marker: "folder", tint: FirstRunInk.orange, at: CGPoint(x: 326.5, y: 414), size: 62, turn: 14),
        Sticker(ink: "search", marker: "downloads", tint: FirstRunInk.red, at: CGPoint(x: 374.5, y: 468), size: 48, turn: 10),
        Sticker(ink: nil, marker: "spot", tint: FirstRunInk.yellow, at: CGPoint(x: 286.5, y: 452), size: 12, turn: 0),
        Sticker(ink: "spark", marker: nil, tint: .clear, at: CGPoint(x: 242.5, y: 350), size: 18, turn: 0),
        Sticker(ink: nil, marker: "spot", tint: FirstRunInk.red, at: CGPoint(x: 262.5, y: 92), size: 10, turn: 0),
        Sticker(ink: "spark", marker: nil, tint: .clear, at: CGPoint(x: 28.5, y: 206), size: 16, turn: 0),
    ]

    /// The three drawings that stay: where they sit in the field.
    static func home(_ drawing: FirstRun.Drawing) -> Int {
        switch drawing { case .tabs: 0; case .key: 7; case .globe: 11 }
    }

    /// Where the small pieces settle: around the hero, or along the top
    /// over a card.
    static let aroundHero: [CGPoint] = [CGPoint(x: 70, y: 150), CGPoint(x: 330, y: 140), CGPoint(x: 40, y: 250), CGPoint(x: 362, y: 262), CGPoint(x: 110, y: 120),
                                        CGPoint(x: 290, y: 336), CGPoint(x: 96, y: 336), CGPoint(x: 250, y: 118), CGPoint(x: 344, y: 200), CGPoint(x: 58, y: 196)]
    static let alongTop: [CGPoint] = [CGPoint(x: 96, y: 80), CGPoint(x: 130, y: 64), CGPoint(x: 176, y: 90), CGPoint(x: 214, y: 68), CGPoint(x: 252, y: 92),
                                      CGPoint(x: 290, y: 66), CGPoint(x: 322, y: 88), CGPoint(x: 352, y: 64), CGPoint(x: 378, y: 92), CGPoint(x: 392, y: 68)]
    static let smallOnes: [Int] = field24.indices.filter { field24[$0].small }

    /// The drawings' ink, marker and colour as they leave the field.
    static func pen(_ drawing: FirstRun.Drawing) -> (ink: String, marker: String, tint: Color) {
        switch drawing {
        case .tabs: ("tabs", "spaces", FirstRunInk.teal)
        case .key: ("key", "key", FirstRunInk.yellow)
        case .globe: ("bringIn", "bringIn", FirstRunInk.sky)
        }
    }
}

// MARK: - the stage

private struct ChainStage: View {
    let space: ChainSpace
    let keyboard: CGFloat
    private var run: FirstRun { .shared }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ChainGeo.field24.indices, id: \.self) { i in
                if !Self.carried.contains(i) { FieldSticker(index: i, space: space) }
            }
            Trackers(space: space)
            ForEach(FirstRun.Drawing.allCases, id: \.self) { drawing in
                ChainTile(drawing: drawing, space: space)
            }
            ChainDrop(space: space)
            StepWords(space: space)
            StepContent(space: space, keyboard: keyboard)
            ChainButtons(space: space, keyboard: keyboard)
            BackButton(space: space)
            ForEach(run.bursts) { burst in
                SparkBurstView(burst: burst, center: space.point(burst.center), scale: space.s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Field places taken by the three drawings that become the tiles.
    static let carried: Set<Int> = Set(FirstRun.Drawing.allCases.map(ChainGeo.home))
}

/// Puts a view in a box of the drawing: size, turn, place.
private extension View {
    func box(_ b: ChainGeo.Box, _ space: ChainSpace) -> some View {
        frame(width: b.w * space.s, height: b.h * space.s).place(b, space)
    }

    /// Turned and put in its place, keeping whatever size it has: for a piece
    /// whose drawing is allowed to hang outside its box.
    func place(_ b: ChainGeo.Box, _ space: ChainSpace) -> some View {
        rotationEffect(.degrees(b.r))
            .offset(x: space.x(b.x), y: space.y(b.y))
    }
}

// MARK: - the field of drawings

/// One drawing of the welcome's field. Large ones leave as a wave from the
/// middle on Get Started and come back on ‹; small ones stay on every step
/// and re-settle with each change.
struct FieldSticker: View {
    let index: Int
    let space: ChainSpace
    private var run: FirstRun { .shared }

    var body: some View {
        let sticker = ChainGeo.field24[index]
        let pose = Self.pose(index, run.step, burst: run.burst)
        Floating(seed: index) {
            PenDrawing(ink: sticker.ink, marker: sticker.marker, tint: sticker.marker == nil ? nil : sticker.tint)
        }
        .parallax(Self.depth(sticker, space))
        .scaleEffect(pose.scale)
        .box(pose.box, space)
        .opacity(pose.box.o)
        .animation(animation(sticker), value: Key(step: run.step, burst: run.burst))
        .allowsHitTesting(false)
    }

    private struct Key: Hashable { let step: FirstRun.Step, burst: Bool }

    /// How far a drawing lies from the glass as the iPhone leans
    /// (Welcome/FirstRunTilt): the big ones come toward the hand, the little
    /// spots and sparks lie behind and move the other way, so the field has
    /// depth instead of sliding as one sheet.
    static func depth(_ s: ChainGeo.Sticker, _ space: ChainSpace) -> CGFloat {
        let near = (s.size - 10) / 72
        return (near * 12 - 3) * space.s
    }

    struct Pose { var box: ChainGeo.Box; var scale: CGFloat }

    static func pose(_ i: Int, _ step: FirstRun.Step, burst: Bool) -> Pose {
        let s = ChainGeo.field24[i]
        let home = ChainGeo.Box(x: s.at.x - s.size / 2, y: s.at.y - s.size / 2, w: s.size, h: s.size, r: s.turn)
        if step == .welcome {
            guard burst else {
                // Before the burst: all of them behind the drop, small and turned.
                let c = ChainGeo.centre, turn = Double(i % 2 == 0 ? -1 : 1) * Double(30 + (i * 7) % 40)
                return Pose(box: .init(x: c.x - s.size / 2, y: c.y - s.size / 2, w: s.size, h: s.size, r: s.turn + turn, o: 0), scale: 0.2)
            }
            return Pose(box: home, scale: 1)
        }
        if let k = ChainGeo.smallOnes.firstIndex(of: i) {
            let set = step == .code || step == .recovery ? ChainGeo.alongTop : ChainGeo.aroundHero
            let at = set[k % set.count]
            var b = ChainGeo.Box(x: at.x - s.size / 2, y: at.y - s.size / 2, w: s.size, h: s.size, r: s.turn)
            if step == .end { b.y += 60; b.o = 0 }
            return Pose(box: b, scale: 1)
        }
        // Out from the middle, smaller, gone.
        let dx = s.at.x - ChainGeo.centre.x, dy = s.at.y - ChainGeo.centre.y, d = max(1, hypot(dx, dy))
        var b = home
        b.x += dx / d * 70; b.y += dy / d * 70; b.o = 0
        return Pose(box: b, scale: 0.7)
    }

    private func animation(_ sticker: ChainGeo.Sticker) -> Animation? {
        let i = index
        let d = hypot(sticker.at.x - ChainGeo.centre.x, sticker.at.y - ChainGeo.centre.y)
        switch run.step {
        case .welcome:
            // Out of the drop with a little give (the welcome's burst), or
            // back from the wave the same way.
            let stagger = Double((i * 13) % 70) / 1000 + (run.wentBack ? 0.06 : 0)
            return FirstRun.travel(.spring(response: 0.55, dampingFraction: 0.62).delay(stagger))
        case .end where sticker.small:
            let k = ChainGeo.smallOnes.firstIndex(of: i) ?? 0
            return FirstRun.travel(.easeIn(duration: 0.26).delay(Double(k) * 0.02))
        default:
            if sticker.small {
                let k = ChainGeo.smallOnes.firstIndex(of: i) ?? 0
                return FirstRun.travel(.spring(response: 0.5, dampingFraction: 0.62).delay(Double(k) * 0.018))
            }
            return FirstRun.travel(.timingCurve(0.4, 0, 0.8, 0.6, duration: 0.24).delay(Double(d) * 0.00035))
        }
    }
}

/// The welcome's idle bob, a few points and a degree or two, each piece on
/// its own clock (the prototype's .float).
private struct Floating<Content: View>: View {
    let seed: Int
    @ViewBuilder let content: Content

    var body: some View {
        if Motion.disabled || Motion.reduced {
            content
        } else {
            content.phaseAnimator([false, true]) { view, up in
                view.offset(y: up ? 2 : -2).rotationEffect(.degrees(up ? 1.5 : -1.5))
            } animation: { _ in
                .easeInOut(duration: 3.2 + Double((seed * 37) % 17) / 10)
            }
        }
    }
}

// MARK: - the three drawings that stay

/// Tabs, key and globe: drawings in the welcome's field, then the three ways
/// to join, then the key's card, the shield, the app icon and the field.
private struct ChainTile: View {
    let drawing: FirstRun.Drawing
    let space: ChainSpace
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    private var run: FirstRun { .shared }

    private var isHero: Bool { run.hero == drawing }
    private var isCard: Bool { drawing == .key && (run.step == .code || run.step == .recovery) }
    /// Landed in the sheet's field: the stage's one gives way to it, so only
    /// the app's field is ever on screen.
    @State private var handedOver = false

    var body: some View {
        let b = box
        let shape = RoundedRectangle(cornerRadius: radius(b) * space.s, style: .continuous)
        ZStack(alignment: .topLeading) {
            // Paper: the app icon's, or the search field's fill.
            shape.fill(run.step == .end ? AppearanceColors.color(0xF5F8FC, 0x2C2C2E) : FirstRunInk.iconPaper(scheme))
                .overlay(shape.strokeBorder(Color.primary.opacity(run.step == .end && isHero ? 0.06 : 0), lineWidth: 0.5))
                .shadow(color: .black.opacity(run.step == .makeDefault && isHero ? 0.16 : run.step == .end && isHero ? 0.06 : 0), radius: 15 * space.s, y: 7 * space.s)
                .opacity(paper)
                .animation(FirstRun.travel(.easeOut(duration: 0.22).delay(0.06)), value: paper)
            // Glass, while the key is a card.
            Color.clear
                .glassEffect(GlassTone.light.glass(for: scheme), in: shape)
                .opacity(isCard ? 1 : 0)
                .animation(FirstRun.travel(.easeOut(duration: 0.14)), value: isCard)
            if isCard {
                Group {
                    if run.step == .code { CodeCard(space: space) } else { RecoveryCard(space: space) }
                }
                .transition(.opacity.animation(FirstRun.travel(.easeOut(duration: 0.2).delay(0.08))))
            }
            if run.step == .end && isHero { FieldFace(space: space) }
        }
        .frame(width: b.w * space.s, height: b.h * space.s)
        .overlay(alignment: .topLeading) { pen }
        .place(b, space)
        .opacity(handedOver ? 0 : b.o)
        .animation(travel, value: TileKey(step: run.step, mac: run.mac, hero: run.hero, burst: run.burst))
        .animation(FirstRun.travel(.easeOut(duration: 0.08)), value: handedOver)
        .task(id: run.step) {
            guard run.step == .end, isHero else { handedOver = false; return }
            if !Motion.disabled { try? await Task.sleep(for: .milliseconds(260)) }
            handedOver = true
        }
        .zIndex(drawing == run.hero ? 2 : drawing == .key && run.step == .mac && run.mac == .none ? 2 : 1)
        .allowsHitTesting(isCard)
    }

    /// A card's corners, the app icon's 22.4%, the field's round ends, a tile's quarter.
    private func radius(_ b: ChainGeo.Box) -> CGFloat {
        if isCard { return b.rad }
        if isHero && run.step == .makeDefault { return b.w * 0.224 }
        if isHero && run.step == .end { return b.h / 2 }
        return b.w * 0.25
    }

    private struct TileKey: Hashable { let step: FirstRun.Step, mac: FirstRun.MacState, hero: FirstRun.Drawing, burst: Bool }

    /// The pen drawing in its place: the whole tile, the card's corner, the
    /// shield; it turns like a key, hops, sways while looking.
    @ViewBuilder private var pen: some View {
        let corner = isCard
        let side = (corner ? 46 : box.w) * space.s
        let kind = penKind
        ZStack {
            if let kind {
                PenDrawing(ink: kind.ink, marker: kind.marker, tint: kind.tint, painted: painted)
                    .animation(FirstRun.travel(.timingCurve(0.3, 0.7, 0.2, 1, duration: 0.55)), value: painted)
                    .id(kind.ink)
                    .transition(.opacity.animation(FirstRun.travel(.easeOut(duration: 0.18))))
            }
        }
        .frame(width: side, height: side)
        .rotationEffect(.degrees(sways ? 7 : 0))
        .modifier(Sway(on: sways))
        .keyframeAnimator(initialValue: 0.0, trigger: drawing == .key ? run.keyTurns : 0) { view, angle in
            view.rotationEffect(.degrees(angle))
        } keyframes: { _ in
            CubicKeyframe(-75, duration: 0.2)
            CubicKeyframe(0, duration: 0.24)
        }
        .keyframeAnimator(initialValue: 0.0, trigger: drawing == .tabs ? run.hops : 0) { view, lift in
            view.offset(y: lift * space.s)
        } keyframes: { _ in
            CubicKeyframe(-18, duration: 0.11)
            SpringKeyframe(0, duration: 0.2, spring: .init(response: 0.2, dampingRatio: 0.5))
        }
        .keyframeAnimator(initialValue: 1.0, trigger: isHero ? run.shieldHits : 0) { view, give in
            view.scaleEffect(give)
        } keyframes: { _ in
            CubicKeyframe(0.94, duration: 0.08)
            CubicKeyframe(1, duration: 0.14)
        }
        .offset(x: corner ? 12 * space.s : 0, y: corner ? 10 * space.s : 0)
        .animation(FirstRun.travel(.spring(response: 0.4, dampingFraction: 0.9)), value: corner)
        // The nearest thing on the stage: it leads the lean, the field of
        // small drawings behind it trailing (FieldSticker.depth).
        .parallax(12 * space.s)
        .accessibilityHidden(true)
    }

    private var penKind: (ink: String, marker: String, tint: Color)? {
        if isHero {
            switch run.step {
            case .privacy:
                return ("privacy", "privacy", SettingsStore.shared.blocksAds ? FirstRunInk.shield : FirstRunInk.shieldOff)
            case .makeDefault, .end:
                return nil
            default: break
            }
        }
        return ChainGeo.pen(drawing)
    }

    /// The Mac's drawing has no marker colour while Yab looks, or when no
    /// Mac turned up; the marker paints it in when one does.
    private var painted: CGFloat {
        guard drawing == .tabs, run.step == .mac else { return 1 }
        return run.mac == .found || run.mac == .insync ? 1 : 0
    }

    private var sways: Bool { drawing == .tabs && run.step == .mac && run.mac == .looking && !Motion.disabled && !Motion.reduced }

    private var paper: Double { isHero && (run.step == .makeDefault || run.step == .end) ? 1 : 0 }

    private var box: ChainGeo.Box {
        let i = ChainGeo.home(drawing)
        switch run.step {
        case .welcome:
            return FieldSticker.pose(i, .welcome, burst: run.burst).box
        case .mac:
            return slot
        case .code, .recovery:
            if drawing == .key { return run.step == .code ? ChainGeo.codeCard : ChainGeo.recoveryCard }
            var b = slot; b.y += 44; b.o = 0
            return b
        case .privacy, .makeDefault:
            return isHero ? ChainGeo.hero : ChainGeo.under
        case .end:
            return isHero ? ChainGeo.field : ChainGeo.under
        }
    }

    /// The three ways: the Mac in front, the key and the globe behind it; no
    /// Mac, the key comes forward and the tabs go back, faded.
    private var slot: ChainGeo.Box {
        let none = run.mac == .none
        switch drawing {
        case .tabs: if none { var b = ChainGeo.left; b.o = 0.5; return b } else { return ChainGeo.front }
        case .key: return none ? ChainGeo.front : ChainGeo.left
        case .globe: return ChainGeo.right
        }
    }

    private var travel: Animation? {
        let spring = Animation.spring(response: 0.42, dampingFraction: 0.84)
        switch run.step {
        case .mac where !run.wentBack:
            // Into the three ways, one after another.
            let order = FirstRun.Drawing.allCases.firstIndex(of: drawing) ?? 0
            return FirstRun.travel(spring.delay(Double(order) * 0.03))
        case .code, .recovery:
            return FirstRun.travel(drawing == .key ? .spring(response: 0.4, dampingFraction: 0.9) : .spring(response: 0.3, dampingFraction: 0.86))
        case .end:
            // Straight into the sheet's own field, no waiting: the step's
            // words leave at the same time, in 130 ms. Long enough to read as
            // a stretch, short enough to be over with everything else.
            return FirstRun.travel(.spring(response: 0.36, dampingFraction: 0.95))
        case .welcome where run.wentBack:
            return FirstRun.travel(spring)
        case .welcome:
            let stagger = Double((ChainGeo.home(drawing) * 13) % 70) / 1000
            return FirstRun.travel(.spring(response: 0.55, dampingFraction: 0.62).delay(stagger))
        default:
            return FirstRun.travel(.spring(response: 0.4, dampingFraction: 0.9))
        }
    }
}

/// ±7° while looking for the Mac, a second each way.
private struct Sway: ViewModifier {
    let on: Bool
    @State private var left = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(on && left ? -14 : 0))
            .animation(on ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: left)
            .onChange(of: on, initial: true) { _, now in left = now }
    }
}

/// The search field the icon stretched into: the glass's glyph and words.
private struct FieldFace: View {
    let space: ChainSpace
    @State private var shown = false

    var body: some View {
        HStack(spacing: 8 * space.s) {
            Glyph(.magnifyingGlass, size: 20 * space.s, color: Ink.secondary)
            Text("Search, ask or give a task")
                .font(.system(size: 17 * space.s))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            // No eyes here: the drop turns into them as it lands (ChainDrop).
        }
        .padding(.leading, 22 * space.s)
        .frame(width: ChainGeo.field.w * space.s, height: ChainGeo.field.h * space.s, alignment: .leading)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(FirstRun.motion(.easeOut(duration: 0.2).delay(0.2))) { shown = true } }
        .accessibilityHidden(true)
    }
}

// MARK: - the drop

/// The flat drop: it grows on the welcome (wide first, then tall), goes into
/// ‹, swells out of the shield's blot as the app icon, and flies into the
/// search field as its eyes.
private struct ChainDrop: View {
    let space: ChainSpace
    @State private var blink: CGFloat = 1
    /// Landed in the field: the drop gives way to New Tab's own eyes.
    @State private var landed = false
    private var run: FirstRun { .shared }

    var body: some View {
        let b = box
        let asEyes = run.drop == .eyes
        // One view travels and shrinks into the sheet's own eyes, fading on
        // the way so the eyes under it are what is left: never two pairs, and
        // nothing drawn over it.
        FlatMark(eye: run.eyeOpen ? blink : 0.12)
            .opacity(asEyes && landed ? 0 : 1)
        .animation(FirstRun.motion(.easeOut(duration: 0.26)), value: run.eyeOpen)
        // Short, and over before the stage leaves (110 ms).
        .animation(FirstRun.travel(.easeOut(duration: 0.11)), value: landed)
        .scaleEffect(x: run.grown ? 1 : 0.03, y: 1)
        .animation(FirstRun.travel(.spring(response: 0.3, dampingFraction: 0.62)), value: run.grown)
        .scaleEffect(x: 1, y: run.grown ? 1 : 0.03)
        .animation(FirstRun.travel(.spring(response: 0.5, dampingFraction: 0.6).delay(0.08)), value: run.grown)
        .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: run.squashes) { view, k in
            view.scaleEffect(x: k.width, y: k.height, anchor: .bottom)
        } keyframes: { _ in
            CubicKeyframe(CGSize(width: 1.08, height: 0.92), duration: 0.12)
            CubicKeyframe(CGSize(width: 0.96, height: 1.05), duration: 0.14)
            CubicKeyframe(CGSize(width: 1, height: 1), duration: 0.16)
        }
        .box(b, space)
        .opacity(b.o)
        .animation(travel, value: run.drop)
        .zIndex(3)
        .allowsHitTesting(false)
        .task(id: run.drop) { await blinking() }
        .task(id: run.drop) {
            // On the way, so the sheet's own eyes are what the drop leaves
            // behind as it shrinks onto them.
            guard run.drop == .eyes else { landed = false; return }
            if !Motion.disabled { try? await Task.sleep(for: .milliseconds(150)) }
            landed = true
        }
    }

    private var box: ChainGeo.Box {
        switch run.drop {
        case .welcome: ChainGeo.welcomeDrop
        case .back: { var b = ChainGeo.back; b.o = 0; return b }()
        case .blot: ChainGeo.blot
        case .icon: ChainGeo.hero
        case .eyes: ChainGeo.eyes
        }
    }

    private var travel: Animation? {
        switch run.drop {
        case .eyes: FirstRun.travel(.spring(response: 0.36, dampingFraction: 0.95))
        case .blot: nil
        default: FirstRun.travel(.spring(response: 0.4, dampingFraction: 0.74))
        }
    }

    /// Now and then the eye closes (230 ms), on the welcome and the icon.
    private func blinking() async {
        guard !Motion.disabled, run.drop == .welcome || run.drop == .icon else { return }
        try? await Task.sleep(for: .seconds(3.4))
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.1)) { blink = 0.12 }
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(.easeInOut(duration: 0.12)) { blink = 1 }
            try? await Task.sleep(for: .seconds(2.6 + Double.random(in: 0...2.4)))
        }
    }
}

// MARK: - trackers

/// Four tracker eyes (the pen's watch drawing) at the shield.
private struct Trackers: View {
    let space: ChainSpace
    private var run: FirstRun { .shared }
    private static let tints = [FirstRunInk.red, FirstRunInk.orange, FirstRunInk.violet, FirstRunInk.pink]

    var body: some View {
        ForEach(0..<4, id: \.self) { i in
            let pose = run.step == .privacy ? run.trackers[i] : .away
            let at = pose == .at ? FirstRun.trackerHit(i) : FirstRun.trackerHomes[i]
            PenDrawing(ink: "watch", marker: "history", tint: Self.tints[i])
                .box(ChainGeo.Box(x: at.x - 29, y: at.y - 29, w: 58, h: 58), space)
                .opacity(pose == .at ? 1 : 0)
                .animation(animation(pose), value: pose)
                .allowsHitTesting(false)
        }
    }

    private func animation(_ pose: FirstRun.Tracker) -> Animation? {
        switch pose {
        case .at: FirstRun.travel(SettingsStore.shared.blocksAds ? .timingCurve(0.5, 0, 0.9, 0.6, duration: 0.3) : .timingCurve(0.3, 0.8, 0.3, 1, duration: 0.44))
        case .thrown: FirstRun.travel(.timingCurve(0.2, 0.7, 0.4, 1, duration: 0.38))
        case .away: nil
        }
    }
}

// MARK: - words

/// Glass, the way the app's own floating pieces wear it.
private extension View {
    func chainGlass(_ radius: CGFloat, _ scheme: ColorScheme) -> some View {
        glassEffect(GlassTone.light.glass(for: scheme), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A piece of a step rising into place as the step comes in (34 points,
/// staggered), the next screen coming in over the last.
private struct Rise: ViewModifier {
    let order: Int
    var base: Double = 0.06
    let space: ChainSpace
    @State private var shown = false
    private var run: FirstRun { .shared }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : (run.wentBack ? -20 : 34) * space.s)
            .onAppear {
                let a = FirstRun.travel(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.32).delay(base + Double(order) * 0.035))
                if let a { withAnimation(a) { shown = true } } else { shown = true }
            }
    }
}

/// The old step's words leave upward in 180 ms.
private extension AnyTransition {
    @MainActor static func leaving(_ space: ChainSpace) -> AnyTransition {
        .asymmetric(insertion: .identity,
                    removal: .opacity.combined(with: .offset(y: -50 * space.s)).animation(FirstRun.travel(.easeOut(duration: 0.13))))
    }
}

/// The welcome's words, and each step's title in its place.
private struct StepWords: View {
    let space: ChainSpace
    @Environment(AppModel.self) private var app
    private var run: FirstRun { .shared }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if run.step == .welcome {
                welcomeWords.transition(.asymmetric(
                    insertion: .opacity.animation(FirstRun.travel(.easeOut(duration: 0.3).delay(0.14))),
                    removal: .opacity.combined(with: .offset(y: -10 * space.s)).animation(FirstRun.travel(.easeOut(duration: 0.14)))))
            }
            if let title {
                titleView(title.text, left: title.left)
                    .id(title.text)
                    .modifier(Rise(order: 0, base: 0.04, space: space))
                    .transition(.leaving(space))
            }
        }
    }

    private var title: (text: String, left: Bool)? {
        switch run.step {
        case .welcome, .end: nil
        case .mac: ("Join Your Mac", false)
        case .code: ("Type This on Your Mac", true)
        case .recovery: ("Recovery Key", true)
        case .privacy: ("Private by Default", false)
        case .makeDefault: ("Make Yab Default?", false)
        }
    }

    /// Bottom-aligned on its line, so larger text grows up, not into the rows.
    private func titleView(_ text: String, left: Bool) -> some View {
        Text(text)
            .font(space.font(left ? 28 : 26, .bold, cap: left ? 1.35 : 1.45))
            .tracking(left ? -0.7 : -0.6)
            .foregroundStyle(Ink.primary)
            .multilineTextAlignment(left ? .leading : .center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 354 * space.s, height: (left ? 96 : 110) * space.s, alignment: left ? .bottomLeading : .bottom)
            .offset(x: space.x(24), y: space.y(left ? 152 - 96 : 393 - 110))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("welcome.title")
    }

    private var welcomeWords: some View {
        let tablet = app.workspace.tabletControls
        return VStack(spacing: 10 * space.s) {
            Text(tablet ? "Your Mac\u{2019}s tabs.\nOn your iPad." : "Your Mac\u{2019}s tabs.\nIn your pocket.")
                .font(space.font(30, .bold, cap: 1.4))
                .tracking(-0.7)
                .foregroundStyle(Ink.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("welcome.words")
                .modifier(Unblur(shown: run.worded, delay: 0))
            Text(tablet ? "Yes, another one. A small, quiet browser for your iPad." : "Yes, another one. A small, quiet browser for your iPhone.")
                .font(space.font(16, .regular, cap: 1.5))
                .foregroundStyle(SettingsInk.footer)
                .frame(maxWidth: 330 * space.s)
                .modifier(Unblur(shown: run.worded, delay: 0.2))
        }
        .multilineTextAlignment(.center)
        .lineLimit(4)
        .minimumScaleFactor(0.7)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 354 * space.s, alignment: .top)
        .offset(x: space.x(24), y: space.y(506))
    }
}

/// Words that come out of blur (at most 8 points), the welcome's way.
private struct Unblur: ViewModifier {
    let shown: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 6)
            .offset(y: shown ? 0 : 4)
            .animation(FirstRun.motion(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.3).delay(delay)), value: shown)
    }
}

// MARK: - each step's rows

private struct StepContent: View {
    let space: ChainSpace
    let keyboard: CGFloat
    private var run: FirstRun { .shared }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch run.step {
            case .mac: MacRows(space: space).transition(.leaving(space))
            case .code: CodeSteps(space: space).transition(.leaving(space))
            case .recovery: RecoveryUnder(space: space, typing: keyboard > 0).transition(.leaving(space))
            case .privacy: PrivacyRows(space: space).transition(.leaving(space))
            case .makeDefault: LinkCard(space: space).transition(.leaving(space))
            case .welcome, .end: EmptyView()
            }
        }
    }
}

/// A glass row: its words and what stands at its end.
private struct ChainRow<Trailing: View>: View {
    let title: String
    let space: ChainSpace
    var dim = false
    @ViewBuilder let trailing: Trailing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10 * space.s) {
            Text(title)
                .font(space.font(17, .semibold))
                .tracking(-0.35)
                .foregroundStyle(dim ? SettingsInk.footer : Ink.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.leading, 20 * space.s)
        .padding(.trailing, 16 * space.s)
        .padding(.vertical, 8 * space.s)
        .frame(minHeight: 62 * space.s)
        .chainGlass(22 * space.s, scheme)
        .contentShape(RoundedRectangle(cornerRadius: 22 * space.s, style: .continuous))
    }
}

private struct Chevron: View {
    let space: ChainSpace
    var body: some View { Glyph(.chevronRight, size: 14 * space.s, color: Color(uiColor: .tertiaryLabel)) }
}

/// A row that answers a press by shrinking a little.
private struct Pressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(FirstRun.motion(.easeOut(duration: 0.12)), value: configuration.isPressed)
    }
}

/// Join Your Mac: the Mac (looking, found, none, in sync), another Apple ID,
/// or on without a Mac.
private struct MacRows: View {
    let space: ChainSpace
    @Environment(AppModel.self) private var app
    private var run: FirstRun { .shared }

    var body: some View {
        let ready = run.mac == .found || run.mac == .insync
        VStack(spacing: 8 * space.s) {
            Button { run.join(app) } label: {
                ChainRow(title: first, space: space, dim: !ready) {
                    HStack(spacing: 8 * space.s) {
                        if run.mac == .looking {
                            ProgressView().controlSize(.small)
                        }
                        if run.mac == .insync {
                            Text("In Sync").font(space.font(15, .medium)).foregroundStyle(SettingsInk.footer)
                        }
                        if ready { Chevron(space: space) }
                    }
                    .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.14))))
                }
            }
            .buttonStyle(Pressed())
            .disabled(!ready)
            .modifier(Rise(order: 0, base: run.wentBack ? 0.06 : 0.16, space: space))
            .accessibilityIdentifier("welcome.join")
            Button { run.useCode(app) } label: {
                ChainRow(title: "Another Apple ID", space: space) { Chevron(space: space) }
            }
            .buttonStyle(Pressed())
            .modifier(Rise(order: 1, base: run.wentBack ? 0.06 : 0.16, space: space))
            .accessibilityIdentifier("welcome.useCode")
            Button { run.useWithoutMac(app) } label: {
                ChainRow(title: "Continue Without a Mac", space: space) { Chevron(space: space) }
            }
            .buttonStyle(Pressed())
            .modifier(Rise(order: 2, base: run.wentBack ? 0.06 : 0.16, space: space))
            .accessibilityIdentifier("welcome.noMac")
        }
        .frame(width: 362 * space.s)
        .offset(x: space.x(20), y: space.y(420))
    }

    private var first: String {
        switch run.mac {
        case .looking: "Looking for Your Mac"
        case .found, .insync: FirstRun.macName(app)
        case .none: "No Mac on This Apple ID"
        }
    }
}

/// Numbered steps on glass, for what to do on the Mac.
private struct StepList: View {
    let lines: [String]
    let space: ChainSpace
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                HStack(spacing: 12 * space.s) {
                    Text("\(i + 1)")
                        .font(.system(size: 13 * space.s, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .frame(width: 24 * space.s, height: 24 * space.s)
                        .background(Color.primary.opacity(0.07), in: Circle())
                    Text(line)
                        .font(space.font(16, .medium))
                        .tracking(-0.3)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16 * space.s)
                .frame(minHeight: 56 * space.s)
                .overlay(alignment: .top) {
                    if i > 0 { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
                }
            }
        }
        .padding(.vertical, 4 * space.s)
        .chainGlass(22 * space.s, scheme)
        .frame(width: 362 * space.s)
    }
}

private struct CodeSteps: View {
    let space: ChainSpace

    var body: some View {
        StepList(lines: ["Open Yab on your Mac", "Go to Settings \u{203A} Sync", "Choose Add a Device"], space: space)
            .modifier(Rise(order: 0, base: 0.12, space: space))
            .offset(x: space.x(20), y: space.y(524))
            .accessibilityIdentifier("welcome.steps")
    }
}

/// Under the Recovery Key's card: Type It Instead or what is wrong, and
/// where the key is.
private struct RecoveryUnder: View {
    let space: ChainSpace
    let typing: Bool
    @Environment(AppModel.self) private var app
    private var run: FirstRun { .shared }

    var body: some View {
        let wrong = app.sync.phase == .joining(.recovery(wrong: true)) && !app.sync.typed.isEmpty
        ZStack(alignment: .topLeading) {
            Group {
                if wrong {
                    Text("That isn\u{2019}t a Recovery Key. Check each group of four.")
                        .font(space.font(14.5, .regular))
                        .foregroundStyle(Ink.warn)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("welcome.wrong")
                } else if !typing && !run.accepted {
                    Button { run.typing = true } label: {
                        Text("Type It Instead")
                            .font(space.font(15.5, .medium))
                            .foregroundStyle(Ink.primary.opacity(0.62))
                            .frame(minHeight: 44 * space.s)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("welcome.type")
                }
            }
            .frame(width: 354 * space.s)
            .offset(x: space.x(24), y: space.y(ChainGeo.recoveryCard.y + ChainGeo.recoveryCard.h + 4))
            if !typing {
                StepList(lines: ["Find Yab Recovery Key.pdf", "Or the key you kept when sync was turned on"], space: space)
                    .modifier(Rise(order: 1, base: 0.12, space: space))
                    .offset(x: space.x(20), y: space.y(548))
                    .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.1))))
            }
        }
    }
}

/// Private by Default: Settings' own rows. The count beside Block ads and
/// trackers is the trackers the shield threw back.
private struct PrivacyRows: View {
    let space: ChainSpace
    @Environment(AppModel.self) private var app
    private var run: FirstRun { .shared }

    var body: some View {
        let settings = SettingsStore.shared
        VStack(spacing: 8 * space.s) {
            ChainRow(title: "Block ads and trackers", space: space) {
                HStack(spacing: 10 * space.s) {
                    if run.thrownBack > 0 && settings.blocksAds {
                        Text("\(run.thrownBack)")
                            .font(.system(size: 13 * space.s, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(run.thrownBack)))
                            .foregroundStyle(SettingsInk.footer)
                            .padding(.horizontal, 7 * space.s)
                            .frame(minWidth: 22 * space.s, minHeight: 22 * space.s)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .animation(FirstRun.motion(.easeOut(duration: 0.18)), value: run.thrownBack)
                            .accessibilityIdentifier("welcome.blocked")
                    }
                    Toggle("Block ads and trackers", isOn: Binding(get: { settings.blocksAds }, set: { run.setBlocking($0) }))
                        .labelsHidden()
                        .accessibilityIdentifier("welcome.blockAds")
                }
            }
            .modifier(Rise(order: 0, base: 0.07, space: space))
            ChainRow(title: "Private Tabs", space: space) {
                Text("Not kept")  // SettingsContent.privateTabsValue
                   .font(space.font(15, .medium)).foregroundStyle(SettingsInk.footer)
            }
            .modifier(Rise(order: 1, base: 0.07, space: space))
            ChainRow(title: "Face ID for Pay and Post", space: space) {
                Toggle("Face ID for Pay and Post", isOn: Binding(get: { settings.faceIDForYes }, set: { settings.faceIDForYes = $0 }))
                    .labelsHidden()
                    .accessibilityIdentifier("welcome.faceID")
            }
            .modifier(Rise(order: 2, base: 0.07, space: space))
        }
        .frame(width: 362 * space.s)
        .offset(x: space.x(20), y: space.y(420))
    }
}

/// Make Yab Default?: a link someone sent, and where it opens.
private struct LinkCard: View {
    let space: ChainSpace
    @Environment(\.colorScheme) private var scheme
    private var run: FirstRun { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12 * space.s) {
                Favicon(icon: "github", host: "github.com", size: 40 * space.s)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fix tab sync after sleep")
                        .font(space.font(16, .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Ink.primary)
                    Text("github.com")
                        .font(space.font(13.5, .regular))
                        .foregroundStyle(SettingsInk.footer)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16 * space.s)
            .frame(minHeight: 72 * space.s)
            HStack {
                Text("Opens in")
                    .font(space.font(15.5, .regular))
                    .foregroundStyle(SettingsInk.footer)
                Spacer(minLength: 8)
                HStack(spacing: 8 * space.s) {
                    ZStack {
                        if run.isDefault {
                            ChainAppIcon(size: 24 * space.s)
                                .transition(.scale(scale: 0.2).combined(with: .opacity).animation(FirstRun.motion(.spring(response: 0.34, dampingFraction: 0.55))))
                        } else {
                            Glyph(.globe, size: 17 * space.s, color: Color(red: 0.04, green: 0.52, blue: 1))
                                .frame(width: 24 * space.s, height: 24 * space.s)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 5.4 * space.s, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 5.4 * space.s, style: .continuous).strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                                .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.12))))
                        }
                    }
                    Text(run.isDefault ? "Yab" : "Safari")
                        .font(space.font(15.5, .semibold))
                        .tracking(-0.25)
                        .foregroundStyle(Ink.primary)
                        .id(run.isDefault)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)).animation(FirstRun.motion(.easeOut(duration: 0.22).delay(0.04))),
                                                removal: .opacity.combined(with: .offset(y: -6)).animation(FirstRun.motion(.easeOut(duration: 0.13)))))
                        .frame(minWidth: 48 * space.s, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("welcome.opensIn")
            }
            .padding(.horizontal, 16 * space.s)
            .frame(minHeight: 52 * space.s)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
        }
        .chainGlass(22 * space.s, scheme)
        .frame(width: 362 * space.s)
        .modifier(ChainShake(travel: CGFloat(run.safariShakes)))
        .animation(FirstRun.motion(.linear(duration: 0.38)), value: run.safariShakes)
        .modifier(Rise(order: 0, base: 0.06, space: space))
        .offset(x: space.x(20), y: space.y(420))
    }
}

// MARK: - buttons

/// The one filled button (it never moves between steps, only its words
/// change) and the quiet one over it.
private struct ChainButtons: View {
    let space: ChainSpace
    let keyboard: CGFloat
    @Environment(AppModel.self) private var app
    private var run: FirstRun { .shared }

    var body: some View {
        let primary = self.primary
        let top = keyboard > 0 && run.step == .recovery
            ? space.height - keyboard - 64 * space.s
            : space.y(786)
        ZStack(alignment: .topLeading) {
            Button { primary?.action() } label: {
                ZStack {
                    if let primary {
                        Text(primary.title)
                            .id(primary.title)
                            .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.2))))
                    }
                }
                .font(space.font(17, .semibold, cap: 1.35))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 354 * space.s, height: 52 * space.s)
                .background(Color.primary.opacity(primary?.enabled == false ? 0.2 : 1), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(Pressed())
            .disabled(primary?.enabled != true)
            .opacity(primary == nil ? 0 : 1)
            .blur(radius: primary == nil ? 8 : 0)
            .offset(y: primary == nil ? 10 * space.s : 0)
            .animation(FirstRun.motion(.easeOut(duration: 0.25)), value: primary == nil)
            .offset(x: space.x(24), y: top)
            .allowsHitTesting(primary != nil)
            .accessibilityIdentifier(primary?.id ?? "welcome.primary")
            if let secondary {
                Button { secondary.action() } label: {
                    Text(secondary.title)
                        .font(space.font(17, .medium, cap: 1.35))
                        .foregroundStyle(Ink.primary.opacity(0.62))
                        .frame(width: 354 * space.s, height: 44 * space.s)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Pressed())
                .offset(x: space.x(24), y: space.y(secondary.y))
                .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.2))))
                .accessibilityIdentifier(secondary.id)
            }
        }
    }

    private struct Action {
        let title: String
        let id: String
        var enabled = true
        var y: CGFloat = 0
        let action: () -> Void
    }

    private var primary: Action? {
        switch run.step {
        case .welcome:
            return run.worded ? Action(title: "Get Started", id: "welcome.start") { run.getStarted(app) } : nil
        case .recovery:
            return run.accepted ? nil : Action(title: "Join", id: "welcome.go", enabled: !app.sync.typed.isEmpty) { run.tryRecovery(app) }
        case .privacy:
            return Action(title: "Continue", id: "welcome.continue") { run.afterPrivacy(app) }
        case .makeDefault:
            return run.isDefault
                ? Action(title: "Continue", id: "welcome.continue") { run.toEnd(app) }
                : Action(title: "Make Yab Default", id: "welcome.makeDefault") { run.makeDefault(app) }
        case .mac, .code, .end:
            return nil
        }
    }

    private var secondary: Action? {
        switch run.step {
        case .code where !run.accepted:
            return Action(title: "Use Recovery Key", id: "welcome.recovery", y: 790) { run.useRecoveryKey(app) }
        case .makeDefault where !run.isDefault:
            return Action(title: "Not Now", id: "welcome.linksNotNow", y: 732) { run.toEnd(app) }
        default:
            return nil
        }
    }
}

/// ‹: where the drop went.
private struct BackButton: View {
    let space: ChainSpace
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    private var run: FirstRun { .shared }

    var body: some View {
        let shows = run.step != .welcome && run.step != .end && !run.accepted
        Button { run.back(app) } label: {
            Glyph(.chevronLeft, size: 20 * space.s, color: Ink.primary)
                .frame(width: 44 * space.s, height: 44 * space.s)
                .glassEffect(GlassTone.light.glass(for: scheme), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(Pressed())
        .opacity(shows ? 1 : 0)
        .animation(FirstRun.motion(.easeOut(duration: 0.25).delay(shows ? 0.12 : 0)), value: shows)
        .allowsHitTesting(shows)
        .offset(x: space.x(ChainGeo.back.x), y: space.y(ChainGeo.back.y))
        .accessibilityLabel("Back")
        .accessibilityIdentifier("welcome.back")
    }
}
