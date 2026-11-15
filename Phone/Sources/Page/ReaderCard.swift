import SwiftUI
import UIKit

/// Reader's Themes & Settings, as Apple Books has them on the iPhone: a
/// glass card over the bottom of the article with smaller and larger text,
/// Justify and the light (Match iPhone, Light, Dark), the screen's
/// brightness, the six themes (ReaderThemes.swift, the Mac's) each in its
/// own face and colors, and Customize. Customize Theme takes the screen:
/// the theme's lines on its own ground above, the font, Bold Text and the
/// spacing under them; ✕ puts back what it changed, ✓ keeps it. The article
/// takes every change at once (WebPool.restyleReaders). Opened by the page
/// menu's Themes & Settings while a page is in Reader.
@MainActor
@Observable
final class ReaderCardModel {
    static let shared = ReaderCardModel()

    enum Page: Equatable { case themes, customize, fonts }

    private(set) var shown = false
    var page: Page = .themes
    /// The prefs as Customize found them, for ✕.
    @ObservationIgnored private var before: ReaderPrefs?

    func open() {
        page = .themes
        Haptics.play(.soft, reason: Haptics.Reason.readerCard)
        withAnimation(Motion.readerCard.current) { shown = true }
    }

    func close() {
        guard shown else { return }
        if page != .themes, let before { ReaderStyle.shared.prefs = before }
        before = nil
        withAnimation(Motion.readerCard.current) {
            shown = false
            page = .themes
        }
    }

    /// Gone at once, the page under it gone too.
    func drop() {
        before = nil
        shown = false
        page = .themes
    }

    func customize() {
        before = ReaderStyle.shared.prefs
        withAnimation(Motion.readerCard.current) { page = .customize }
    }

    /// ✓: what Customize changed stays.
    func done() {
        before = nil
        withAnimation(Motion.readerCard.current) { page = .themes }
    }

    /// ✕: what Customize changed goes.
    func cancel() {
        if let before { ReaderStyle.shared.prefs = before }
        before = nil
        withAnimation(Motion.readerCard.current) { page = .themes }
    }
}

extension Motion {
    /// The card rising over the article, Customize taking the screen.
    static let readerCard = spring("reader card", response: 0.34, damping: 0.88)
}

extension Haptics.Reason {
    static let readerCard = "reader card"      // soft: Themes & Settings opened
    static let readerTheme = "reader theme"    // soft: a theme picked
}

// MARK: - the layer

struct ReaderCardLayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let model = ReaderCardModel.shared
        let reading = app.currentPageState.readerEnabled
        let dark = ReaderStyle.shared.prefs.isDark(system: scheme == .dark)
        ZStack(alignment: .bottom) {
            if model.shown && reading {
                if model.page == .themes {
                    // A tap on the article puts the card away, as in Books.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { model.close() }
                        .accessibilityHidden(true)
                    ReaderThemesCard(model: model, dark: dark)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    ReaderCustomize(model: model, dark: dark)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                }
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .onChange(of: reading) { _, now in if !now { model.drop() } }
        .onChange(of: app.browser.tab?.id) { _, _ in model.drop() }
    }
}

// MARK: - Themes & Settings

private struct ReaderThemesCard: View {
    let model: ReaderCardModel
    let dark: Bool
    @State private var brightness = Double(ReaderScreen.brightness)
    private var style: ReaderStyle { ReaderStyle.shared }

    var body: some View {
        let prefs = style.prefs
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                RoundButton(symbol: "xmark", label: "Close", id: "reader.card.close") { model.close() }
                Text("Themes & Settings")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                pill {
                    Button { style.prefs.step(-1) } label: { Text("A").font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        .disabled(prefs.look.size <= 0)
                        .accessibilityLabel("Smaller Text")
                        .accessibilityIdentifier("reader.card.smaller")
                    divider
                    Button { style.prefs.step(1) } label: { Text("A").font(.system(size: 21, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        .disabled(prefs.look.size >= ReaderLook.sizes.count - 1)
                        .accessibilityLabel("Larger Text")
                        .accessibilityIdentifier("reader.card.larger")
                }
                pill {
                    Button { style.prefs.change { $0.justify.toggle() } } label: {
                        Image(systemName: "text.justify")
                            .font(.system(size: 17, weight: .medium))
                            .opacity(prefs.look.justify ? 1 : 0.55)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .accessibilityLabel("Justify Text")
                    .accessibilityAddTraits(prefs.look.justify ? .isSelected : [])
                    .accessibilityIdentifier("reader.card.justify")
                    divider
                    Menu {
                        Picker("Appearance", selection: Binding(get: { style.prefs.mode }, set: { style.prefs.mode = $0 })) {
                            ForEach(ReaderMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                        }
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 17, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .accessibilityLabel("Appearance")
                    .accessibilityValue(prefs.mode.title)
                    .accessibilityIdentifier("reader.card.appearance")
                }
            }
            .buttonStyle(.plain)
            .frame(height: 48)
            HStack(spacing: 10) {
                Image(systemName: "sun.min.fill").font(.system(size: 13)).opacity(0.7)
                Slider(value: $brightness, in: 0...1)
                    .tint(.primary)
                    .onChange(of: brightness) { _, value in ReaderScreen.brightness = CGFloat(value) }
                    .accessibilityLabel("Brightness")
                    .accessibilityIdentifier("reader.card.brightness")
                Image(systemName: "sun.max.fill").font(.system(size: 15)).opacity(0.7)
            }
            .padding(.horizontal, 4)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(0..<2, id: \.self) { line in
                    GridRow {
                        ForEach(ReaderThemeSpec.ordered[line * 3 ..< line * 3 + 3], id: \.id) { spec in tile(spec, prefs: prefs) }
                    }
                }
            }
            Button { model.customize() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").font(.system(size: 16, weight: .medium))
                    Text("Customize").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.primary.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.card.customize")
        }
        .foregroundStyle(.primary)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.card")
        .onAppear { brightness = Double(ReaderScreen.brightness) }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 1, height: 22)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.1), in: Capsule())
    }

    private func tile(_ spec: ReaderThemeSpec, prefs: ReaderPrefs) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let colors = prefs.colors(spec.id, dark: dark)
        let picked = prefs.theme == spec.id
        let edited = prefs.edited(spec.id)
        let face = spec.id == .original ? ReaderFont.sfPro : spec.look.font
        return Button {
            Haptics.play(.soft, reason: Haptics.Reason.readerTheme)
            style.prefs.theme = spec.id
        } label: {
            VStack(spacing: 0) {
                Text("Aa").font(face.font(size: 28, weight: spec.fontWeight))
                Text(spec.name).font(face.font(size: 14, weight: spec.fontWeight)).opacity(0.85)
            }
            .foregroundStyle(colors.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 82)
            .background(colors.ground, in: shape)
            .overlay(alignment: .topTrailing) {
                Circle().fill(colors.ink.opacity(0.8)).frame(width: 6, height: 6).padding(9).opacity(edited ? 1 : 0)
            }
            // Inside the tile, as Books draws it: the ring is the tile's edge.
            .overlay(shape.strokeBorder(picked ? Color.primary.opacity(0.85) : Color.primary.opacity(0.08), lineWidth: picked ? 2.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(edited ? "\(spec.name), edited" : spec.name)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("reader.card.theme.\(spec.id.rawValue)")
    }
}

/// A round glass button with a symbol: ✕, ‹.
private struct RoundButton: View {
    let symbol: String
    let label: String
    let id: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(filled ? Color(uiColor: .systemBackground) : .primary)
                .frame(width: 44, height: 44)
                .background(filled ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary.opacity(0.12)), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Customize Theme

private struct ReaderCustomize: View {
    let model: ReaderCardModel
    let dark: Bool
    private var style: ReaderStyle { ReaderStyle.shared }

    var body: some View {
        let prefs = style.prefs
        let colors = prefs.colors(prefs.theme, dark: dark)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RoundButton(symbol: "xmark", label: "Cancel", id: "reader.customize.cancel") { model.cancel() }
                    Spacer()
                    Text("Customize Theme").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    RoundButton(symbol: "checkmark", label: "Done", id: "reader.customize.done", filled: true) { model.done() }
                }
                .foregroundStyle(colors.ink)
                ReaderSampleLines(prefs: prefs, colors: colors)
            }
            .padding(.horizontal, 16)
            .padding(.top, ApprovalScreen.insets.top + 4)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.ground)
            .animation(.easeOut(duration: 0.18), value: prefs)

            Group {
                if model.page == .fonts { fonts(prefs) } else { knobs(prefs) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.customize")
    }

    private func knobs(_ prefs: ReaderPrefs) -> some View {
        let look = prefs.look
        let spec = prefs.spec
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Text").font(.title3.weight(.semibold)).padding(.horizontal, 4).padding(.top, 18)
                group {
                    Button { withAnimation(Motion.readerCard.current) { model.page = .fonts } } label: {
                        HStack(spacing: 12) {
                            Text("Aa").font(look.font.font(size: 15, weight: .semibold)).frame(width: 24)
                            Text("Font")
                            Spacer(minLength: 0)
                            Text(look.font == .site ? "\(spec.name)\u{2019}s" : look.font.title)
                                .font(look.font.font(size: 17))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .row()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reader.customize.font")
                    line
                    toggle("Bold Text", glyph: Text("B").font(.system(size: 17, weight: .bold)), id: "bold", look.bold) { on in
                        style.prefs.change { $0.bold = on }
                    }
                }
                Text("Layout").font(.title3.weight(.semibold)).padding(.horizontal, 4).padding(.top, 14)
                group {
                    slider("Line Spacing", symbol: "list.bullet", id: "line", value: look.line, range: ReaderLook.lines, step: 0.05,
                           text: String(format: "%.2f", look.line)) { v in style.prefs.change { $0.line = (v * 20).rounded() / 20 } }
                    line
                    slider("Character Spacing", symbol: "textformat.characters", id: "letter", value: Double(look.letter), range: ReaderLook.letters, step: 1,
                           text: "\(look.letter)%") { v in style.prefs.change { $0.letter = Int(v.rounded()) } }
                    line
                    slider("Word Spacing", symbol: "text.alignleft", id: "word", value: Double(look.word), range: ReaderLook.words, step: 2,
                           text: "\(look.word)%") { v in style.prefs.change { $0.word = Int(v.rounded()) } }
                    line
                    slider("Margins", symbol: "rectangle.portrait", id: "margins", value: Double(look.margins), range: ReaderLook.marginRange, step: 2,
                           text: "\(look.margins)%") { v in style.prefs.change { $0.margins = Int(v.rounded()) } }
                }
                group {
                    toggle("Justify Text", glyph: nil, id: "justify", look.justify) { on in style.prefs.change { $0.justify = on } }
                }
                if prefs.edited(prefs.theme) {
                    group {
                        Button { style.prefs.reset() } label: {
                            Text("Reset \(spec.name)").foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).row()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reader.customize.reset")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, ApprovalScreen.insets.bottom + 20)
        }
        .scrollIndicators(.hidden)
    }

    private func fonts(_ prefs: ReaderPrefs) -> some View {
        let look = prefs.look
        let spec = prefs.spec
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button { withAnimation(Motion.readerCard.current) { model.page = .customize } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        Text("Font").font(.title3.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.top, 18)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("reader.fonts.back")
                group {
                    ForEach(Array(ReaderFont.allCases.enumerated()), id: \.element) { index, face in
                        if index > 0 { line }
                        Button { style.prefs.change { $0.font = face } } label: {
                            HStack {
                                Text(face == .site ? "Original" : face.title).font(face.font(size: 18))
                                if face == spec.look.font {
                                    Text("\(spec.name)\u{2019}s").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if look.font == face { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
                            }
                            .row()
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(look.font == face ? .isSelected : [])
                        .accessibilityIdentifier("reader.fonts.\(face.rawValue)")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, ApprovalScreen.insets.bottom + 20)
        }
        .scrollIndicators(.hidden)
    }

    private var line: some View {
        Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 16)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func toggle(_ title: String, glyph: Text?, id: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: set)) {
            HStack(spacing: 12) {
                if let glyph { glyph.frame(width: 24) }
                Text(title)
            }
        }
        .tint(Color(uiColor: .systemGreen))
        .row()
        .accessibilityIdentifier("reader.customize.\(id)")
    }

    private func slider(_ title: String, symbol: String, id: String, value: Double, range: ClosedRange<Double>, step: Double,
                        text: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 24)
                Slider(value: Binding(get: { value }, set: set), in: range, step: step)
                    .tint(.primary)
                    .accessibilityLabel(title)
                    .accessibilityValue(text)
                    .accessibilityIdentifier("reader.customize.\(id)")
                Text(text).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private extension View {
    func row() -> some View {
        padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
    }
}

/// "Aa" and a few lines in the theme in front, set as the article is.
private struct ReaderSampleLines: View {
    let prefs: ReaderPrefs
    let colors: ReaderColors

    var body: some View {
        let look = prefs.look
        let size = CGFloat(look.points)
        let weight: Font.Weight = look.bold || prefs.spec.weight >= 700 ? .bold : prefs.spec.weight >= 500 ? .medium : .regular
        let face = look.font == .site ? ReaderFont.newYork : look.font
        VStack(alignment: .leading, spacing: 10) {
            Text("Aa").font(face.font(size: 34, weight: weight))
            Text("The tide came in slowly that evening, and nobody on the pier was in any hurry to leave.")
                .font(face.font(size: size, weight: weight))
                .tracking(size * CGFloat(look.letter) / 100)
                .lineSpacing(size * CGFloat(look.line - 1.2))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, max(0, CGFloat(look.margins) * 0.6))
        }
        .foregroundStyle(colors.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample text in \(prefs.spec.name)")
        .accessibilityIdentifier("reader.customize.sample")
    }
}

/// The screen's brightness, for Books' sun slider.
@MainActor
enum ReaderScreen {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static var brightness: CGFloat {
        get { screen?.brightness ?? 0.5 }
        set { screen?.brightness = min(max(newValue, 0), 1) }
    }
}

extension ReaderColors {
    var ground: Color { Color(uiColor: Self.uiColor(background) ?? .white) }
    var ink: Color { Color(uiColor: Self.uiColor(text) ?? .black) }

    private static func uiColor(_ hex: String) -> UIColor? {
        guard hex.count == 7, let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return UIColor(red: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                       blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}
