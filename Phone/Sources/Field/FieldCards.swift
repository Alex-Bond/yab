import SwiftUI
import UIKit

/// The cards over the field: the page's card (Copy Link, Share, Ask, On Mac),
/// the rows typed words lead to, New Tab's sections, and Incognito's empty
/// field. Rows stand best lowest, nearest the field and the thumb.

// MARK: - the page's card

struct PageCard: View {
    let tab: Tab
    /// Copy Link, Share, Ask, On Mac; over a private tab the first two.
    var actions: [AppModel.PageAction] = AppModel.PageAction.allCases
    let act: (AppModel.PageAction) -> Void

    private typealias C = Metrics.FieldCard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: C.headGap) {
                Favicon(icon: tab.icon, host: tab.host, size: C.headIcon,
                        url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                VStack(alignment: .leading, spacing: C.headLineGap) {
                    Text(tab.title)
                        .font(.callout.weight(.semibold))
                        .tracking(-0.01 * C.headTitle)
                        .foregroundStyle(Ink.primary)
                        .frame(minHeight: C.headTitleLine)
                    Text("\(tab.addressHost) · \(tab.site)")
                        .font(.footnote)
                        .foregroundStyle(Ink.rowSubtitle)
                        .frame(minHeight: C.headSubtitleLine)
                }
                .lineLimit(dynamicTypeSize > .large ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(C.headPadding)
            Rectangle().fill(Ink.hairline).frame(height: C.hairline)
            HStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element) { i, action in
                    if i > 0 { Rectangle().fill(Ink.cellLine).frame(width: C.hairline) }
                    Button { act(action) } label: {
                        VStack(spacing: C.actionGap) {
                            Glyph(action.glyph, size: C.actionIcon)
                            Text(action.title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Ink.primary)
                                .frame(minHeight: C.actionLabel)
                        }
                        .padding(.top, C.actionTop)
                        .padding(.bottom, C.actionBottom)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("field.card.\(action.rawValue)")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: C.radius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("field.card")
    }
}

// MARK: - rows for typed words

/// The rows card: one line a row, best lowest, filled. Its rows stand 8
/// in from its edges, rounded 22 − 8 = 14 (concentric with it).
struct RowsCard: View {
    let rows: [WordRow]
    let dark: Bool
    /// False while the answer plate over the rows is what the key does.
    var bestLit = true
    let choose: (WordRow) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated().reversed()), id: \.element.id) { i, row in
                Button { choose(row) } label: {
                    WordRowView(row: row, best: i == 0 && bestLit, dark: dark)
                }
                .buttonStyle(WordRowPress(best: i == 0 && bestLit, fill: WordRowView.bestFill(dark: dark)))
                .accessibilityIdentifier(i == 0 ? "field.best" : "field.row.\(i)")
            }
        }
        .padding(Metrics.FieldCard.linesPadding)
        .cardSurface(radius: Metrics.FieldCard.linesRadius, fill: dark ? Ink.privateCard : Ink.surface.opacity(0.95))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("field.rows")
    }
}

/// One row on one line: its icon in a 22 column, then what it does, and
/// after it, fainter, what tells it apart (Ask Claude “words”, a tab's site).
/// The best row sits on a quiet capsule, its words their usual color; no
/// key's word on it: the capsule's row is what the keyboard's key does.
struct WordRowView: View {
    let row: WordRow
    let best: Bool
    var dark = false

    private typealias C = Metrics.FieldCard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The best row's capsule: flat, no color of the space's and no
    /// shadow, a gray step off the sheet in the light theme (7.5% black)
    /// and in the dark one or on a dark card (11% white), so it reads the
    /// same over any space and any page (the 2026-11-04 pick).
    static func bestFill(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.11) : AppearanceColors.color(0x000000, 0xFFFFFF, alpha: 0.075, darkAlpha: 0.11)
    }

    var body: some View {
        let line = row.line
        // Words are white on a dark card only; the best row's capsule is
        // light enough to keep them their usual color.
        let lit = dark
        HStack(spacing: C.rowGap) {
            RowIcon(icon: row.icon, dark: lit)
            let main = Text(line.main).foregroundStyle(lit ? Color.white : Ink.primary)
            let detail = Text(line.detail.map { "  " + $0 } ?? "")
                .foregroundStyle(lit ? Color.white.opacity(0.72) : Ink.rowSubtitle)
            Text("\(main)\(detail)")
                .font(.callout.weight(.medium))
                .tracking(-0.01 * C.rowTitle)
                // Larger text keeps its words on a second line, not cut off.
                .lineLimit(dynamicTypeSize > .large ? 2 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(C.linePadding)
        .frame(minHeight: C.line)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.subtitle)")
        .accessibilityValue(best ? row.key.rawValue : "")
    }
}

/// A row under the finger: a wash and a hair smaller; the best row keeps
/// its capsule and deepens it a step. Rows are capsules, as the field is.
struct WordRowPress: ButtonStyle {
    let best: Bool
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        configuration.label
            .background {
                if best { shape.fill(fill) }
                if configuration.isPressed {
                    shape.fill(best ? AppearanceColors.color(0x000000, 0xFFFFFF, alpha: 0.04) : AppearanceColors.fill(0.16))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.disabled ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension WordRow {
    /// The row's one line: what it does, and fainter after it what tells it
    /// apart. Searches are their words alone, the magnifier says the rest;
    /// "in this tab" stays, a new tab is what a search usually opens.
    var line: (main: String, detail: String?) {
        let parts = subtitle.components(separatedBy: " · ")
        switch action {
        case .search, .open: return (title, subtitle.contains("in this tab") ? "in this tab" : nil)
        case .searchFor, .findOnPage: return (title, nil)
        case .ask, .task:
            return (parts[0], "“\(title)”" + (parts.count > 1 ? " · " + parts[1] : ""))
        default: return (title, parts.first.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}

struct RowIcon: View {
    let icon: WordRow.Icon
    var dark = false
    var glyphSize: CGFloat = Metrics.FieldCard.rowIcon

    var body: some View {
        Group {
            switch icon {
            case let .favicon(key, host): Favicon(icon: key, host: host, size: Metrics.FieldCard.rowFavicon)
            case .magnifier: glyph(.magnifyingGlass)
            // Asking Claude: its face with the eyes, as the chat's avatar.
            case .sparkle: AgentFace(size: glyphSize, color: dark ? .white : Ink.primary)
            case .agent: glyph(.agent)
            case .globe: glyph(.globe)
            case .settings: glyph(.settingsGear1)
            case .onPage: glyph(.pageText)
            case .clipboard: Glyph(.clipboard, size: 21, color: dark ? .white : Ink.primary)
            }
        }
        .frame(width: Metrics.FieldCard.rowIconColumn, height: Metrics.FieldCard.rowIconColumn)
    }

    private func glyph(_ name: GlyphName) -> some View {
        Glyph(name, size: glyphSize, color: dark ? .white : Ink.primary)
    }
}

// MARK: - New Tab

/// New Tab's card over its field: Now nearest the field, Recent Tabs, then
/// Frequent at the top; typed words, their rows in groups. Anchored at its
/// foot: on a short screen it scrolls up under a soft top edge.
struct NewTabCard: View {
    @Environment(AppModel.self) private var app
    let rows: [WordRow]
    let content: NewTabContent
    let maxHeight: CGFloat
    var fieldExtraHeight: CGFloat = 0
    var bottom: CGFloat? = nil

    @State private var scrolledUnder = false
    /// The rows' own height: the card is as tall as they are, up to its most.
    @State private var contentHeight: CGFloat = 0

    @ViewBuilder
    var body: some View {
        // A fresh profile has no rows or suggestions. Padding alone would
        // draw a narrow 16 by 70 point card across the empty search field.
        if !rows.isEmpty || !content.now.isEmpty || !content.recent.isEmpty || !content.frequent.isEmpty {
            card
        }
    }

    private var card: some View {
        let fits = contentHeight <= maxHeight + 0.5
        let height = min(contentHeight, maxHeight)
        return rowsView(fits: fits)
            .frame(height: height)
            .background {
                // The card as drawn, for tests to measure; only in test runs.
                if LaunchOptions.current.isTestRun {
                    Color.clear
                        .accessibilityElement()
                        .accessibilityIdentifier("newtab.card.frame")
                        .accessibilityValue("rows \(Int(contentHeight.rounded()))")
                }
            }
            .cardSurface(radius: Metrics.NewTab.radius, fill: Ink.surface.opacity(0.94))
            // The card has a finite frame before it moves. A full-screen
            // custom layout also made its accessibility viewport full-screen.
            .offset(y: bottom.map { $0 - height } ?? 0)
    }

    /// The rows as they are when they fit; on a screen too short for them, a
    /// scroll anchored at the foot under a soft top edge. Only a real scroll
    /// is a ScrollView: one near the status bar reaches up under it, its
    /// frame and touches with it.
    @ViewBuilder private func rowsView(fits: Bool) -> some View {
        let measured = inner.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        if fits {
            measured
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: min(contentHeight, maxHeight), alignment: .bottom)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("newtab.card")
                .gesture(app.field.closeDrag)
        } else {
            NewTabScroll(content: measured.environment(app), scrolled: { offset in
                let under = offset > 2
                if under != scrolledUnder { Motion.scrollEdge.run { scrolledUnder = under } }
            }, pulled: { pull in
                app.field.drag = pull * Metrics.Field.dragFollow
            }, released: { pull, speed in
                if pull > Metrics.Field.closeDistance || (pull > 0 && speed > Metrics.Field.closeVelocity) {
                    app.field.close()
                } else {
                    Motion.fieldRows.run { app.field.drag = 0 }
                }
            })
                .frame(height: min(contentHeight, maxHeight))
                .overlay(alignment: .top) {
                    // Only when something is really under the top edge.
                    ScrollEdge(surface: Ink.surface.opacity(0.94)).opacity(scrolledUnder ? 1 : 0)
                }
        }
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                sections
            } else {
                groups
            }
        }
        .padding(EdgeInsets(top: Metrics.NewTab.cardPadding.top,
                            leading: Metrics.NewTab.cardPadding.leading,
                            bottom: Metrics.NewTab.cardPadding.bottom + fieldExtraHeight,
                            trailing: Metrics.NewTab.cardPadding.trailing))
    }

    @ViewBuilder private var sections: some View {
        if !content.frequent.isEmpty {
            SectionTitle(text: "Frequent")
            FrequentGrid(sites: Array(content.frequent.prefix(NewTabContent.frequentShown))) { app.chooseFrequent($0) }
        }
        if !content.recent.isEmpty {
            SectionTitle(text: "Recent Tabs")
            ForEach(content.recent.prefix(2)) { item in itemRow(item) }
        }
        if !content.now.isEmpty {
            SectionTitle(text: "Now")
            ForEach(content.now) { item in itemRow(item) }
        }
    }

    private func itemRow(_ item: NewTabItem) -> some View {
        Button { app.choose(item) } label: {
            NewTabRowView(icon: item.icon, title: item.title, subtitle: item.subtitle)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newtab.item.\(item.id)")
    }

    /// The groups in reverse, each group's rows best lowest.
    @ViewBuilder private var groups: some View {
        // One list, as the spaces' typed rows: no group titles.
        ForEach(Words.grouped(rows).reversed()) { group in
            ForEach(group.rows.reversed()) { entry in
                Button { app.choose(entry.row) } label: {
                    WordRowView(row: entry.row, best: entry.index == 0)
                }
                .buttonStyle(WordRowPress(best: entry.index == 0, fill: WordRowView.bestFill(dark: false)))
                .accessibilityIdentifier(entry.index == 0 ? "field.best" : "field.row.\(entry.index)")
            }
        }
    }
}

/// A New Tab row: 52 high, the icon in a 22 column.
struct NewTabRowView: View {
    let icon: WordRow.Icon
    let title: String
    let subtitle: String
    var tab: Tab? = nil

    private typealias C = Metrics.FieldCard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: C.rowGap) {
            if let tab {
                Favicon(icon: tab.icon, host: tab.host, size: Metrics.FieldCard.rowFavicon,
                        url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                    .frame(width: C.rowIconColumn, height: C.rowIconColumn)
            } else {
                RowIcon(icon: icon)
            }
            VStack(alignment: .leading, spacing: C.rowLineGap) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .tracking(-0.01 * C.rowTitle)
                    .foregroundStyle(Ink.primary)
                    .frame(minHeight: C.rowTitleLine)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Ink.rowSubtitle)
                    .frame(minHeight: C.rowSubtitleLine)
            }
            .lineLimit(dynamicTypeSize > .large ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Metrics.NewTab.rowPadding)
        .frame(minHeight: Metrics.NewTab.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

/// NOW, RECENT TABS, FREQUENT: a caption that grows without clipping.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(Metrics.NewTab.sectionTracking)
            .foregroundStyle(Ink.section)
            .frame(minHeight: Metrics.NewTab.sectionFont)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Metrics.NewTab.sectionPadding)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Frequent: five sites a row, each its icon on a soft tile and its name.
struct FrequentGrid: View {
    let sites: [SiteCandidate]
    let open: (SiteCandidate) -> Void

    private typealias N = Metrics.NewTab

    var body: some View {
        HStack(alignment: .top, spacing: N.tileGap) {
            ForEach(sites, id: \.key) { site in
                Button { open(site) } label: {
                    VStack(spacing: N.tileNameGap) {
                        RoundedRectangle(cornerRadius: N.tileRadius, style: .continuous)
                            .fill(AppearanceColors.fill(0.1))
                            .frame(width: N.tile, height: N.tile)
                            .overlay { Favicon(icon: site.key, host: site.host, size: N.tileIcon) }
                        Text(site.name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppearanceColors.gray(0.75))
                            .lineLimit(1)
                            .frame(minHeight: N.tileName)
                    }
                    .padding(.vertical, N.tilePadding)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newtab.site.\(site.key)")
                .accessibilityLabel(site.name)
            }
            // Fewer than five keep their columns.
            ForEach(sites.count..<NewTabContent.frequentShown, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
        }
        .padding(N.gridPadding)
    }
}

/// Incognito, nothing typed: no history to show, only what this is.
struct PrivateEmpty: View {
    var body: some View {
        VStack(spacing: Metrics.NewTab.privateGap) {
            Glyph(.incognito, size: Metrics.NewTab.privateGlyph, color: Color.white.opacity(0.55))
            Text("You’re browsing Incognito")
                .font(.system(size: Metrics.NewTab.privateFont, weight: .semibold))
                .tracking(-0.01 * Metrics.NewTab.privateFont)
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("field.incognito")
    }
}

/// The soft fade at a scroller's top while something is under it: a 26
/// point band of the surface's color, blurred, going clear downward (the
/// field's cards, Settings' lists).
struct ScrollEdge: View {
    let surface: Color

    var body: some View {
        ScrollEdgeMaterial(surface: surface)
            .frame(height: Metrics.scrollEdge)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A material fill plus a SwiftUI mask can expose the backing blur as an
/// unlabeled accessibility node. Keep this decoration and its mask in one
/// native view, with every backing view explicitly outside the AX tree.
private struct ScrollEdgeMaterial: UIViewRepresentable {
    let surface: Color

    func makeUIView(context: Context) -> ScrollEdgeBackdrop {
        ScrollEdgeBackdrop()
    }

    func updateUIView(_ view: ScrollEdgeBackdrop, context: Context) {
        view.tint.backgroundColor = UIColor(surface)
    }
}

private final class ScrollEdgeBackdrop: UIView {
    let tint = UIView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let fade = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        blur.isAccessibilityElement = false
        blur.accessibilityElementsHidden = true
        blur.contentView.isAccessibilityElement = false
        blur.contentView.accessibilityElementsHidden = true
        tint.isAccessibilityElement = false
        tint.accessibilityElementsHidden = true
        addSubview(blur)
        blur.contentView.addSubview(tint)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.35, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = fade
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        tint.frame = blur.contentView.bounds
        fade.frame = bounds
    }
}

extension View {
    /// A card over the field: its fill, its radius, a soft shadow under it.
    func cardSurface(radius: CGFloat, fill: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .clipShape(shape)
            .background {
                shape.fill(fill)
                    .shadow(color: Ink.shadow.opacity(0.06), radius: 1, x: 0, y: 1)
                    .shadow(color: Ink.shadow.opacity(0.25), radius: 8, x: 0, y: 12)
            }
    }
}

extension Ink {
    /// The card's hairlines: under the page's head (.16), between its cells (.12).
    static let hairline = AppearanceColors.gray(0.16)
    static let cellLine = AppearanceColors.gray(0.12)
}
