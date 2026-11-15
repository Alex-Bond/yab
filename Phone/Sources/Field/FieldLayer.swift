import SwiftUI
import UIKit

/// The field over the keyboard, the plate's (about this page, ⌘L) and New
/// Tab's (⌘T). Surfaces says whether the field is up;
/// FieldModel holds its words and position between the plate and keyboard.
///
/// The field grows out of whatever summoned it (the plate, +) as the
/// keyboard rises, the page behind frosts over, and the card above it says
/// what Return will do. It lands back on the plate when nothing is chosen.
struct FieldLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Heard after `shown` and `mode`, whatever transaction they came in (FieldModel.revision).
            let _ = app.field.revision
            ZStack(alignment: .topLeading) {
                if app.field.shown, let mode = app.field.mode {
                    FieldSurface(mode: mode, size: size)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        // The code scanner's camera, over everything (Field/CodeScanner).
        .fullScreenCover(isPresented: Binding(get: { app.scanner.shown }, set: { app.scanner.shown = $0 }),
                         onDismiss: { app.scanner.closed() }) {
            CodeScannerCover().environment(app)
        }
    }
}

/// Where the field and its cards stand on a screen, with the keyboard as tall
/// as it says it is (sizes.md: the plate's field 10 over the keyboard, New
/// Tab's 20; cards 10 over the field, New Tab's card 8 over the keyboard).
struct FieldGeometry {
    let size: CGSize
    let keyboard: CGFloat
    let mode: Surfaces.FieldMode
    var textScale: CGFloat = 1
    /// New Tab over no keyboard (the plate swiped up): the field stands
    /// over the home indicator instead.
    var resting = false
    /// The search sheet, when the field stands in it (Field/SearchSheet).
    var sheet: SearchSheetPose? = nil

    var keyboardTop: CGFloat { size.height - (resting && mode == .newTab ? Metrics.NewTab.restingFoot : keyboard) }

    /// Leave room for the person's body font while preserving the default
    /// field height. The same geometry supplies the question's flight origin.
    private var textHeight: CGFloat { UIFont.systemFont(ofSize: Metrics.Field.font * textScale).lineHeight + Metrics.Field.gap * 2 }

    var sheetFieldHeight: CGFloat { max(Metrics.Chrome.height, Metrics.Field.newTabHeight * textScale, textHeight) }

    var field: CGRect {
        if let sheet { return sheetField(sheet, height: sheetFieldHeight) }
        switch mode {
        case .address:
            // Never smaller than the plate it grows out of; larger text grows it.
            let h = max(Metrics.Chrome.height, Metrics.Field.height * textScale, textHeight)
            return CGRect(x: Metrics.Field.side, y: keyboardTop - Metrics.Field.aboveKeyboard - h,
                          width: size.width - Metrics.Field.side * 2 - h - Metrics.Field.closeGap, height: h)
        case .newTab:
            let h = max(Metrics.Chrome.height, Metrics.Field.newTabHeight * textScale, textHeight)
            return CGRect(x: Metrics.Field.newTabInset, y: keyboardTop - Metrics.Field.newTabAboveKeyboard - h,
                          width: size.width - Metrics.Field.newTabInset * 2 - h - Metrics.Field.closeGap, height: h)
        }
    }

    /// ✕ in its own glass circle beside the field.
    /// As tall as the field, so the two always match (larger text grows both).
    var close: CGRect {
        let side = field.height
        return CGRect(x: field.maxX + Metrics.Field.closeGap, y: field.minY, width: side, height: side)
    }

    var radius: CGFloat { field.height / 2 }

    /// The page card and the rows card: their foot 10 over the field.
    var cardBottom: CGFloat { field.minY - Metrics.Edge.stack }
    var cardWidth: CGFloat { size.width - Metrics.Field.side * 2 }

    /// New Tab's card: 8 from the sides, its foot 8 over the keyboard, at
    /// most 502 high and never into the status bar. The prototype's keyboard
    /// is 302 and its card starts at 64; the iPhone's own is a little taller
    /// (308 on a 17 Pro), and the card rises the difference rather than
    /// scroll rows that fit.
    var newTabBottom: CGFloat { keyboardTop - Metrics.NewTab.inset }
    /// The spaces: the whole screen, down to the keyboard when it is up.
    var spacesBottom: CGFloat { resting && mode == .newTab ? size.height : keyboardTop }
    /// What the spaces keep clear over their foot (past their own 14) so
    /// their last row ends 10 over the field, wherever the field stands.
    var spacesFieldExtra: CGFloat {
        max(0, spacesBottom - field.minY + Metrics.Edge.stack - Metrics.NewTab.cardPadding.bottom)
    }
    var newTabWidth: CGFloat { size.width - Metrics.NewTab.inset * 2 }
    var newTabMaxHeight: CGFloat { max(0, min(Metrics.NewTab.maxHeight, newTabBottom - Metrics.NewTab.highest)) }
}

extension FieldModel {
    /// The field's frame now, for what grows out of it (an answer).
    func frame(in size: CGSize) -> CGRect {
        if let presentationFrame { return presentationFrame }
        return FieldGeometry(size: size, keyboard: keyboard, mode: resting ? .newTab : (mode ?? .address),
                      textScale: textScale, resting: resting, sheet: sheetPose).field
    }
}

/// What the field shows, worked out when the words or the pages change, never
/// in a morph: only the stage under it reads the motion, frame by frame.
private struct FieldSurface: View {
    @Environment(AppModel.self) private var app
    let mode: Surfaces.FieldMode
    let size: CGSize

    var body: some View {
        let rows = app.fieldRows
        let content = NewTabContent.make(for: app)
        let plain = rows.isEmpty && content.sheetRows.isEmpty
        FieldStage(mode: mode, size: size, rows: rows, content: content, key: app.fieldKey, hasNow: app.nowItem != nil)
            .onChange(of: plain) { _, plain in app.field.sheetBody = Metrics.SearchSheet.body(plain: plain) }
    }
}

/// The field, its cards and the frosted page behind them.
private struct FieldStage: View {
    @Environment(AppModel.self) private var app
    @ScaledMetric(relativeTo: .body) private var bodyFontSize = Metrics.Field.font
    @State private var nativeBodyFontSize: CGFloat?
    let mode: Surfaces.FieldMode
    let size: CGSize
    let rows: [WordRow]
    let content: NewTabContent
    let key: WordRow.Key
    let hasNow: Bool

    /// The plate's field stands in the space's card as New Tab's does: the
    /// page's own actions live in its menu (≡), so no card repeats them here;
    /// what is typed shows in the same card.
    private var asSpaces: Bool {
        mode == .address && app.browser.spaces.contains { !$0.isPrivate }
    }

    var body: some View {
        let model = app.field
        let _ = model.revision
        let fontSize = nativeBodyFontSize ?? bodyFontSize
        // The address erased (or typed over): the field takes New Tab's place in
        // the one card, as New Tab's does.
        let g = FieldGeometry(size: size, keyboard: model.keyboard, mode: asSpaces ? .newTab : mode,
                              textScale: fontSize / Metrics.Field.font, resting: model.resting, sheet: model.sheetPose)
        let dark = model.isPrivate
        // The page menu turning into this field (a tap on its address): its
        // sheet carries the motion, the backdrop and cards follow it, and the
        // field takes over from the sheet's row only at the end.
        let fromMenu: CGFloat = app.surfaces.menu == .plate ? app.pageMenu.toField : 1
        ZStack(alignment: .topLeading) {
            Group {
                if model.inSheet {
                    // Over the sheet the page stays in sight, dimmed.
                    Color.black.opacity(Metrics.SearchSheet.dim).ignoresSafeArea()
                } else {
                    FieldBackdrop(mode: mode, dark: dark)
                }
            }
                .opacity(model.backdrop * Double(fromMenu))
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.inSheet { model.close() }
                    else if mode == .newTab || asSpaces { model.putKeyboardAway() }
                    else { model.close() }
                }
                .gesture(backdropDrag)
                .accessibilityIdentifier("field.backdrop")
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)
                // The full-screen backdrop's center is covered by New Tab.
                // Activate the exposed margin, or close directly with VoiceOver.
                .accessibilityActivationPoint(UnitPoint(x: 6 / size.width, y: 0.3))
                .accessibilityAction { model.close() }
                .accessibilityAction(.escape) { model.close() }

            cards(geometry: g, dark: dark)
                .animation(Motion.cardHug.animation, value: asSpaces)
                .opacity(model.cards * Double(min(max((fromMenu - 0.6) / 0.3, 0), 1)))
                .offset(y: (1 - model.cards) * Metrics.Field.rowsRise + model.drag)

            FieldPill(mode: mode, geometry: g, key: key, hasNow: hasNow, fontSizeChanged: { nativeBodyFontSize = $0 })
                .opacity(model.spacesBar ? 0 : Double(min(max((fromMenu - 0.6) / 0.4, 0), 1)))
                .allowsHitTesting(!model.spacesBar)
                .offset(y: model.sheetPose.map { g.sheetDrop($0) + model.drag } ?? 0)
                // The sheet's field pulls the sheet as the rest of it does; a tap stays a tap.
                .simultaneousGesture(model.sheetDrag, including: model.inSheetNow ? .all : .subviews)
            if model.sheetAllowed {
                SpacesFootBar(size: size)
                    .opacity(model.spacesBarOpacity)
                    .allowsHitTesting(model.spacesBar)
                    .accessibilityHidden(!model.spacesBar)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(Motion.disabled || !model.inSheet ? nil : Motion.cardHug.animation, value: rows.isEmpty)
        .onChange(of: fontSize, initial: true) { _, value in
            // Actions use the same geometry as the actual native text field.
            model.textScale = value / Metrics.Field.font
        }
        .onChange(of: model.words) { _, _ in FieldAnswers.shared.clear() }
        .onDisappear { FieldAnswers.shared.clear() }
    }

    @ViewBuilder
    private func cards(geometry g: FieldGeometry, dark: Bool) -> some View {
        let model = app.field
        if model.sheetAllowed, mode == .newTab || asSpaces, !(mode == .newTab && app.browser.spaces.allSatisfy(\.isPrivate)) {
            // One spaces card for the field's whole life: the sheet's ground under it,
            // its rows over it, so the morph never builds a screen under the finger.
            let pose = model.sheetPose
            let lift = pose == nil && mode == .newTab
                ? LiftFrame(reveal: model.reveal, size: size, bottom: g.spacesBottom,
                            plate: ChromeGeometry(size: size, folded: false, hasNow: hasNow).plate) : nil
            ZStack(alignment: .topLeading) {
                if let pose { SearchSheetGround(geometry: g, pose: pose) }
                if pose == nil || model.sheetSpacesReady || model.sheetExpand > 0.001 {
                    let e = pose?.expand ?? 1
                    let hidden = pose.map { g.sheetSpacesHidden($0) } ?? 0
                    SpacePagesCard(rows: pose == nil ? rows : [], content: content, width: size.width,
                                   maxHeight: pose == nil ? g.spacesBottom : size.height,
                                   fieldExtraHeight: pose == nil ? g.spacesFieldExtra
                                       : max(0, size.height - g.sheetRestField(height: g.sheetFieldHeight).minY + Metrics.Edge.stack - Metrics.NewTab.cardPadding.bottom),
                                   bottom: pose == nil ? g.spacesBottom : size.height,
                                   privatePage: !model.pageIsPrivate, onlyPrivate: model.pageIsPrivate,
                                   reveal: pose == nil ? model.reveal : 1, fullness: 1)
                        .equatable()
                        .frame(width: size.width)
                        .opacity(pose == nil ? Double(min(1, max(0, model.reveal) / 0.15)) : Double(SearchSheetPose.share(e, in: Metrics.SearchSheet.spacesIn)))
                        // Drawn there, not laid out there: a long list's rows don't each hear of every frame.
                        .geometryGroup()
                        .transformEffect(CGAffineTransform(translationX: 0, y: pose.map { g.sheetSpacesHang($0) + g.sheetDrop($0) } ?? lift?.drop ?? 0))
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .mask(alignment: .topLeading) {
                            if let lift {
                                RoundedRectangle(cornerRadius: lift.radius, style: .continuous)
                                    .frame(width: lift.rect.width, height: lift.rect.height)
                                    .offset(x: lift.rect.minX, y: lift.rect.minY)
                            } else {
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: hidden)
                                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                        .frame(height: hidden > 0 ? Metrics.SearchSheet.spacesEdge : 0)
                                    Color.black
                                }
                            }
                        }
                        .allowsHitTesting(e >= 1)
                        .accessibilityHidden(e < 1)
                }
                if let pose { SearchSheetFront(rows: rows, recent: Array(content.sheetRows.prefix(Metrics.SearchSheet.rows)), geometry: g, pose: pose) }
            }
        } else { switch mode {
        case .address where asSpaces:
            SpacePagesCard(rows: rows, content: content, width: size.width,
                           maxHeight: g.spacesBottom, fieldExtraHeight: g.spacesFieldExtra, bottom: g.spacesBottom,
                           // The one input: the same card as + opens, Private first, and the same
                           // eyes. Over a private tab the field is private already, and the card
                           // is Private's page alone: no public tab shows behind a private one.
                           privatePage: !model.pageIsPrivate, onlyPrivate: model.pageIsPrivate, fullness: 1)
                .frame(width: size.width)
                .transition(.asymmetric(insertion: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity),
                                        removal: .opacity))
        case .address:
            if !rows.isEmpty {
                answered(RowsCard(rows: rows, dark: false, bestLit: !app.fieldAnswerTakesKey, choose: app.choose), dark: false)
                    .frame(width: g.cardWidth)
                    .bottomAt(x: Metrics.Field.side, y: g.cardBottom, in: size)
                    .gesture(closeDrag)
            } else if let tab = app.browser.tab {
                PageCard(tab: tab, actions: app.pageActions, act: app.pageAction)
                    .frame(width: g.cardWidth)
                    .bottomAt(x: Metrics.Field.side, y: g.cardBottom, in: size)
                    .gesture(closeDrag)
            }
        case .newTab:
            if app.browser.spaces.contains(where: { !$0.isPrivate }) {
                // The whole screen: the spaces (Private first) or the typed
                // rows at its foot; out of the plate and back into it by a finger.
                let lift = LiftFrame(reveal: model.reveal, size: size, bottom: g.spacesBottom,
                                     plate: ChromeGeometry(size: size, folded: false, hasNow: hasNow).plate)
                SpacePagesCard(rows: rows, content: content, width: size.width,
                               maxHeight: g.spacesBottom, fieldExtraHeight: g.spacesFieldExtra,
                               bottom: g.spacesBottom, reveal: model.reveal, fullness: 1)
                    .frame(width: size.width)
                    // Its first and last 15 %: the plate under it shows through as one gives way to the other.
                    .opacity(Double(min(1, max(0, model.reveal) / 0.15)))
                    // Lifted by a finger: the card grows out of the plate, its
                    // contents hanging from its top, which is the finger.
                    .offset(y: lift?.drop ?? 0)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .mask(alignment: .topLeading) {
                        if let lift {
                            RoundedRectangle(cornerRadius: lift.radius, style: .continuous)
                                .frame(width: lift.rect.width, height: lift.rect.height)
                                .offset(x: lift.rect.minX, y: lift.rect.minY)
                        } else {
                            Rectangle()
                        }
                    }
            } else if model.isPrivate {
                if rows.isEmpty {
                    PrivateEmpty()
                        .frame(width: size.width)
                        .offset(y: size.height * Metrics.NewTab.privateAt - Metrics.NewTab.privateLift)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .allowsHitTesting(false)
                } else {
                    answered(RowsCard(rows: rows, dark: true, bestLit: !app.fieldAnswerTakesKey, choose: app.choose), dark: true)
                        .frame(width: g.cardWidth)
                        .bottomAt(x: Metrics.Edge.bar, y: g.field.minY - Metrics.NewTab.privateRowsAboveField, in: size)
                        .gesture(closeDrag)
                }
            } else {
                NewTabCard(rows: rows, content: content, maxHeight: g.newTabMaxHeight,
                           fieldExtraHeight: g.field.height - Metrics.Field.newTabHeight, bottom: g.newTabBottom)
                    .frame(width: g.newTabWidth)
                    .offset(x: Metrics.NewTab.inset)
            }
        } }
    }

    private var closeDrag: some Gesture { app.field.closeDrag }

    /// The rows with the words' answer on its own plate over them (FieldAnswer).
    private func answered(_ rows: RowsCard, dark: Bool) -> some View {
        VStack(spacing: Metrics.FieldCard.linesOverField) {
            if let answer = app.fieldAnswer {
                AnswerPlate(answer: answer, words: app.field.words,
                            lit: app.fieldAnswerTakesKey ? WordRowView.bestFill(dark: dark) : nil,
                            dark: dark, copy: app.copyFieldAnswer)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
            rows
        }
        .animation(Motion.disabled ? nil : Motion.typedRows.animation, value: app.fieldAnswer == nil)
    }

    private var backdropDrag: AnyGesture<Void> {
        // Beside the sheet a finger pulls it too; it never jumps to the spaces.
        if app.field.inSheet { return AnyGesture(app.field.sheetDrag.map { _ in () }) }
        if mode == .newTab || asSpaces {
            return AnyGesture(DragGesture().onChanged { _ in
                if !app.field.resting { app.field.putKeyboardAway() }
            }.map { _ in () })
        }
        return AnyGesture(closeDrag.map { _ in () })
    }
}

/// The spaces while a finger lifts them out of the plate or takes them back
/// down: one object, its foot from the plate's to the screen's, its sides
/// spreading from the plate's to the screen's, its top the finger, its
/// corners the plate's growing to the screen's; nil once it is open.
struct LiftFrame {
    let rect: CGRect
    let radius: CGFloat
    /// How far below its open place the contents hang.
    let drop: CGFloat
    /// The screen's own corners, which the open spaces take.
    static let screenCorner: CGFloat = 55

    init?(reveal: CGFloat, size: CGSize, bottom: CGFloat, plate: CGRect) {
        guard reveal < 0.999 else { return nil }
        let r = max(0, reveal)
        func ease(_ x: CGFloat) -> CGFloat { let c = min(max(x, 0), 1); return 1 - pow(1 - c, 3) }
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        let screen = CGRect(x: 0, y: 0, width: size.width, height: bottom)
        let foot = mix(plate.maxY, screen.maxY, ease(r / 0.35))
        let top = min(foot - plate.height, mix(plate.minY, screen.minY, r))
        let side = ease(r / 0.5)
        let x = mix(plate.minX, screen.minX, side), w = mix(plate.width, screen.width, side)
        rect = CGRect(x: x, y: top, width: w, height: foot - top)
        radius = mix(plate.height / 2, Self.screenCorner, min(1, r / 0.5))
        drop = top - screen.minY
    }
}

extension FieldModel {
    /// Down on the cards or beside them: they follow at 60 %, and past 60 pt
    /// or 500 pt/s the field goes.
    var closeDrag: some Gesture {
        DragGesture(minimumDistance: 7)
            .onChanged { [weak self] value in
                guard let self, value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                self.drag = value.translation.height * Metrics.Field.dragFollow
            }
            .onEnded { [weak self] value in
                guard let self else { return }
                if value.translation.height > Metrics.Field.closeDistance || value.velocity.height > Metrics.Field.closeVelocity {
                    self.close()
                } else {
                    Motion.fieldRows.run { self.drag = 0 }
                }
            }
    }
}

/// Address editing keeps the real page visible through the native blur.
/// New Tab retains its neutral surface and Incognito's privacy shade.
private struct FieldBackdrop: View {
    let mode: Surfaces.FieldMode
    let dark: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            if mode == .newTab {
                Rectangle().fill(dark ? Ink.privateBackdrop : Metrics.Field.backdrop)
            }
        }
        .ignoresSafeArea()
    }
}

/// The field itself: grown from its origin (the plate, +) into its place
/// over the keyboard, and back. Its contents stand where they will be and
/// the growing shape reveals them.
private struct FieldPill: View {
    @Environment(AppModel.self) private var app
    let mode: Surfaces.FieldMode
    let geometry: FieldGeometry
    let key: WordRow.Key
    let hasNow: Bool
    let fontSizeChanged: (CGFloat) -> Void

    var body: some View {
        let model = app.field
        let to = geometry.field
        let from = model.landing ?? model.origin ?? ChromeGeometry(size: geometry.size, folded: false, hasNow: hasNow).plate
        let t = model.progress
        let rect = CGRect(x: lerp(from.minX, to.minX, t), y: lerp(from.minY, to.minY, t),
                          width: lerp(from.width, to.width, t), height: lerp(from.height, to.height, t))
        let radius = lerp(from.height / 2, geometry.radius, t)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = model.isPrivate
        ZStack(alignment: .topLeading) {
            // Where the field stands, and the keyboard's height it stands on,
            // for tests to measure against the prototype; only in test runs,
            // so VoiceOver never stops on it.
            if LaunchOptions.current.isTestRun {
                Color.clear
                    .frame(width: to.width, height: to.height)
                    .offset(x: to.minX, y: to.minY)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityIdentifier("field.frame")
                    .accessibilityValue("keyboard \(Int(model.keyboard.rounded()))")
            }
            Group {
                // Liquid Glass, the plate's own (untinted, in dark mode too);
                // Private's is the same glass, dark.
                Color.clear
                    .glassEffect(dark ? .regular.tint(Ink.privateField.opacity(0.7)) : .regular, in: shape)
                    .animation(Motion.disabled ? nil : Motion.eyes.animation, value: dark)
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)

            FieldContents(mode: mode, key: key, fontSizeChanged: fontSizeChanged)
                .equatable()
                .frame(width: to.width, height: to.height)
                // Lifted by a finger: the words come in as the plate becomes the field.
                .opacity(model.contents * Double(model.reveal < 1 ? min(max((model.reveal - 0.08) / 0.22, 0), 1) : 1) * model.sheetWordsVeil)
                .offset(x: to.minX, y: to.minY)
                .mask(alignment: .topLeading) {
                    shape.frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                }

            // ✕ beside the field: the bar's right button rises into it.
            let closeTo = geometry.close
            let closeFrom = ChromeGeometry(size: geometry.size, folded: false, hasNow: hasNow).space
            let c = CGRect(x: lerp(closeFrom.minX, closeTo.minX, t), y: lerp(closeFrom.minY, closeTo.minY, t),
                           width: lerp(closeFrom.width, closeTo.width, t), height: lerp(closeFrom.height, closeTo.height, t))
            Button {
                // Chats' search closes back into its button; the page stays.
                if model.chatsSearch { model.putKeyboardAway() } else { model.close() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(dark ? Color.white.opacity(0.9) : Ink.primary)
                    .opacity(Double(model.contents) * Double(min(1, max(0, (t - 0.3) / 0.5))))
                    .frame(width: c.width, height: c.height)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(dark ? .regular.tint(Ink.privateField) : .regular.interactive(), in: Circle())
            .offset(x: c.minX, y: c.minY)
            .accessibilityIdentifier("field.close")
            .accessibilityLabel("Close")
            // The sheet closes by a tap beside it or a pull down, the spaces by their check.
            .opacity(model.inSheetNow ? 0 : 1)
            .allowsHitTesting(!model.inSheetNow)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        // The spaces' field is the plate in the first and last 15 % of their move.
        .opacity(model.pill * (model.spacesVeil ?? 1) * model.sheetFieldVeil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("field.pill")
    }
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// What is in the field: the page's icon over its address, or the
/// magnifier; the words; the eyes (New Tab); ✕ on its grey plate.
private struct FieldContents: View, Equatable {
    @Environment(AppModel.self) private var app
    @State private var mathKeys = FieldMathKeys()
    let mode: Surfaces.FieldMode
    let key: WordRow.Key
    let fontSizeChanged: (CGFloat) -> Void

    /// The pill's morph runs over it; its own reads bring it back when they change.
    static func == (a: Self, b: Self) -> Bool { a.mode == b.mode && a.key == b.key }

    var body: some View {
        let model = app.field
        let dark = model.isPrivate
        let privateSearch = dark || model.pageIsPrivate
        let purpose = mode == .address
            ? (privateSearch ? "Address or private search" : "Address, search, ask or give a task")
            : (privateSearch ? "Private search" : "Search, ask or give a task")
        // New Tab: the words start where the card's row titles do (58 in).
        HStack(spacing: Metrics.Field.gap) {
            if model.showsAddress, !model.chatsSearch, let tab = app.browser.tab {
                Favicon(icon: tab.icon, host: tab.host, size: Metrics.Field.favicon,
                        url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
            } else if mode == .newTab, NewTabPager.shared.onChats, !dark, !model.sheetAllowed {
                // On Chats the box at the field's left shows the archived
                // chats, lit while they're shown; again, the chats.
                let archive = NewTabPager.shared.showsArchive
                Button {
                    Haptics.play(.light, reason: Haptics.Reason.archive)
                    Motion.columnRows.run { NewTabPager.shared.showsArchive.toggle() }
                } label: {
                    Image("MacArchivebox")
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .frame(width: Metrics.Field.magnifier + 2, height: Metrics.Field.magnifier + 2)
                        .foregroundStyle(archive ? Color.white : Ink.fieldGlyph)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(archive ? Ink.primary : Color.clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, Metrics.Field.newTabGap - Metrics.Field.gap - 7)
                .padding(.leading, -7)
                .accessibilityIdentifier("field.archive")
                .accessibilityLabel(archive ? "Show Chats" : "Show Archived Chats")
            } else {
                Glyph(.magnifyingGlass, size: Metrics.Field.magnifier, color: dark ? Color.white.opacity(0.7) : Ink.fieldGlyph)
                    // New Tab: the words start where the card's row titles do (58 in).
                    .padding(.trailing, mode == .newTab || model.inSheet ? Metrics.Field.newTabGap - Metrics.Field.gap : 0)
            }
            let listening = mode == .newTab && app.voice.listening
            FieldInput(text: model.text, selected: model.showsAddress, completion: app.fieldCompletion,
                       placeholder: listening ? "Listening…" : privateSearch ? "Search…" : NewTabPager.shared.onChats ? (NewTabPager.shared.showsArchive ? "Search archive" : "Search chats") : "Search, ask or give a task",
                       compactPlaceholder: listening ? "Listening…" : mode == .address && !privateSearch ? "Address…" : "Search…",
                       accessibilityPurpose: purpose,
                       dark: dark, key: key,
                       focusRequest: model.focusRequest, blurRequest: model.blurRequest,
                       // Typing while voice search listens takes over from it.
                       typed: { app.voice.interrupted(); model.typed($0) }, editAddress: { model.editAddress() },
                       submit: { app.fieldReturn() }, escape: { model.close() },
                       fontSizeChanged: fontSizeChanged,
                       accessory: app.fieldMathKeys ? mathKeys : nil, waits: model.resting)
                .frame(maxWidth: .infinity)
            // ✕ is its own circle beside the field now; inside, the eyes
            // (New Tab) where Safari has its microphone, or ⓧ to clear.
            if mode == .newTab {
                // The eyes come in with the field's last stretch, not at once:
                // black on glass, they would jump out of a half-grown pill.
                let eyesIn = min(max((model.progress - 0.55) / 0.45, 0), 1)
                HStack(spacing: 0) {
                    // The lit microphone while voice search listens.
                    FieldInputOptions()
                    ZStack {
                        if model.text.isEmpty {
                            if !model.chatsSearch {
                                EyesButton(shut: dark, dark: dark) { model.setPrivate(!dark) }
                                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        } else {
                            clearWords(dark: dark)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .animation(Motion.disabled ? nil : Motion.eyesWord.animation, value: model.text.isEmpty)
                }
                .opacity(Double(eyesIn))
                .scaleEffect(0.8 + 0.2 * eyesIn)
            } else {
                // The plate's field: ⓧ while there are words. Erased, it turns
                // into the eyes and the field is what + opens, with its eyes
                // (over a private tab the field is private already).
                let eyes = !model.pageIsPrivate && model.text.isEmpty && !model.chatsSearch
                ZStack {
                    if !model.text.isEmpty && !eyes {
                        clearWords(dark: dark)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    if eyes {
                        EyesButton(shut: dark, dark: dark) { model.setPrivate(!dark) }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(Motion.disabled ? nil : Motion.eyesWord.animation, value: eyes)
            }
        }
        // New Tab's magnifier on the rows' icons' middle, its words on their titles.
        .padding(.leading, model.inSheetNow ? Metrics.SearchSheet.fieldLeading
                 : mode == .newTab ? Metrics.Field.newTabLeading : Metrics.Field.leading)
        // The close control stays 44 points while the font grows. Keep its
        // ordinary cap inset instead of reserving the taller text's radius.
        .padding(.trailing, 4)
    }

    private func clearWords(dark: Bool) -> some View {
        Button {
            app.voice.interrupted()
            app.field.clear()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(dark ? Color.white.opacity(0.6) : Ink.clearGlyph)
                .frame(width: Metrics.touch, height: Metrics.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("field.clearWords")
        .accessibilityLabel("Clear")
    }
}

/// The native close glyph: a 32-point circle inside a real 44-point target.
struct FieldCloseButton: View {
    let dark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: Metrics.Field.clearGlyph, weight: .medium))
                .foregroundStyle(dark ? Color.white.opacity(0.8) : Ink.clearGlyph)
                .frame(width: Metrics.Field.clear, height: Metrics.Field.clear)
                .background(dark ? Color.white.opacity(0.16) : Ink.clearPlate, in: Circle())
                .frame(width: Metrics.touch, height: Metrics.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("field.clear")
        .accessibilityLabel("Close")
    }
}

extension View {
    /// Placed with its foot at `y` and its left at `x`, on a screen of `size`.
    func bottomAt(x: CGFloat, y: CGFloat, in size: CGSize) -> some View {
        frame(maxHeight: .infinity, alignment: .bottom)
            .frame(height: y, alignment: .bottom)
            .offset(x: x)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

extension Ink {
    /// The field's own grays: the magnifier (.55), ✕'s glyph (.7) and plate (118,118,128,.16).
    static let fieldGlyph = AppearanceColors.gray(0.55)
    static let clearGlyph = AppearanceColors.gray(0.7)
    static let clearPlate = AppearanceColors.fill(0.16)
    /// New Tab's field: rgba(118,118,128,.12).
    static let fill = AppearanceColors.fill(0.12)
    /// Second lines of rows: rgba(60,60,67,.62); section titles .55.
    /// Small text must stay readable over the card and its filled best row.
    static let rowSubtitle = AppearanceColors.color(0x5A5A62, 0xC7C7D1)
    static let section = AppearanceColors.color(0x5A5A62, 0xC7C7D1)
    /// Incognito: the field rgba(36,34,44,.92), its cards rgba(28,27,34,.96), the backdrop rgba(14,13,18,.82).
    static let privateField = Color(red: 36 / 255, green: 34 / 255, blue: 44 / 255).opacity(0.92)
    static let privateCard = Color(red: 28 / 255, green: 27 / 255, blue: 34 / 255).opacity(0.96)
    static let privateBackdrop = Color(red: 14 / 255, green: 13 / 255, blue: 18 / 255).opacity(0.82)
    /// A private tab's row in the column: rgba(28,28,32,.86).
    static let privateRow = Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255).opacity(0.86)
    /// Ink for buttons that say the main thing (Keep, Run on Your Mac): #161615.
    static let button = AppearanceColors.color(0x161615, 0x3A3A3C)
}

extension Metrics.Menu.Plate {
    /// Everything under the plate's menu (the page, the buttons, the plate), a little darker.
    static let scrim: Double = 0.08
}
