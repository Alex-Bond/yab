import SwiftUI
import WidgetKit

/// The Search and Ask widgets: Yab's ways in from the Home Screen and the
/// Lock Screen. Search opens New Tab's field with the keyboard up, Ask a new
/// chat (yab://new, yab://ask). The widget extension (Phone/Activity) shows
/// these faces; the app draws the same ones in its pictures (widgets.1-3).
enum SearchWidgetKind: String, CaseIterable, Sendable {
    case search, ask

    var route: YabRoute { self == .search ? .newTab : .ask }
    /// WidgetKit's kind: stable, or placed widgets go blank after an update.
    var widgetKind: String { "dev.serafim.fast.iphone.\(rawValue)" }
    /// The field's own glyphs: its magnifier, the Ask row's sparkle.
    var glyph: String { self == .search ? "MagnifyingGlass" : "Sparkle" }
    /// What the capsule says, as New Tab's field does.
    var word: String { self == .search ? "Search" : "Ask" }
    var galleryName: String { self == .search ? "Search" : "Ask" }
    var galleryDescription: String {
        self == .search ? "Opens Yab with New Tab\u{2019}s field ready to type an address or a search."
            : "Opens Yab with a new chat ready for your question."
    }
    var accessibilityLabel: String { self == .search ? "Search in Yab" : "Ask in Yab" }
}

/// Sizes of the faces, as the system lays widgets out on a 402-point iPhone.
enum SearchWidgetMetrics {
    static let small = CGSize(width: 170, height: 170)
    static let circular = CGSize(width: 72, height: 72)
    static let rectangular = CGSize(width: 160, height: 72)
    /// WidgetKit's own margin inside a small widget.
    static let margin: CGFloat = 16
    static let smallRadius: CGFloat = 22
    static let mark: CGFloat = 36
    /// New Tab's field, smaller: 44 high, magnifier 18, words 16.
    static let field: CGFloat = 44
    static let fieldGlyph: CGFloat = 18
    static let fieldFont: CGFloat = 16
    static let fieldLeading: CGFloat = 12
    static let circularGlyph: CGFloat = 26
    static let rectangularGlyph: CGFloat = 18
    static let rectangularFont: CGFloat = 15
}

/// A widget's face for its family. `inWidget` is false in the app's
/// pictures, which stand in for what WidgetKit puts behind it.
struct SearchWidgetFace: View {
    let kind: SearchWidgetKind
    let family: WidgetFamily
    var inWidget = true

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: SearchWidgetCircular(kind: kind, inWidget: inWidget)
            case .accessoryRectangular: SearchWidgetRectangular(kind: kind, inWidget: inWidget)
            default: SearchWidgetSmall(kind: kind)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("widget.\(kind.rawValue).\(family.pictureName)")
    }
}

/// Home Screen, small: Yab's mark above New Tab's field; the whole widget
/// is the tap.
struct SearchWidgetSmall: View {
    let kind: SearchWidgetKind

    private typealias M = SearchWidgetMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tinted Home Screens keep the mark's glass, only without its blue.
            Image("YabMark")
                .resizable()
                .interpolation(.high)
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .aspectRatio(contentMode: .fit)
                .frame(width: M.mark, height: M.mark)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                EntranceGlyph(kind.glyph, size: M.fieldGlyph)
                    .foregroundStyle(EntranceLook.glyph)
                    .widgetAccentable()
                Text(kind.word)
                    .font(.system(size: M.fieldFont, weight: .medium))
                    .tracking(-0.01 * M.fieldFont)
                    .foregroundStyle(EntranceLook.placeholder)
                Spacer(minLength: 0)
            }
            .padding(.leading, M.fieldLeading)
            .frame(maxWidth: .infinity, minHeight: M.field, maxHeight: M.field)
            .background(EntranceLook.fill, in: Capsule(style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Lock Screen, circular: the glyph alone on the system's round backing.
struct SearchWidgetCircular: View {
    let kind: SearchWidgetKind
    var inWidget = true

    var body: some View {
        ZStack {
            if inWidget { AccessoryWidgetBackground() } else { Circle().fill(.white.opacity(0.18)) }
            EntranceGlyph(kind.glyph, size: SearchWidgetMetrics.circularGlyph)
                .foregroundStyle(.white)
                .widgetAccentable()
        }
    }
}

/// Lock Screen, rectangular: Yab's name over a field that says Search or Ask.
struct SearchWidgetRectangular: View {
    let kind: SearchWidgetKind
    var inWidget = true

    private typealias M = SearchWidgetMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Yab")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 6) {
                EntranceGlyph(kind.glyph, size: M.rectangularGlyph)
                    .widgetAccentable()
                Text(kind.word)
                    .font(.system(size: M.rectangularFont, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if inWidget { AccessoryWidgetBackground().clipShape(Capsule(style: .continuous)) }
                else { Capsule(style: .continuous).fill(.white.opacity(0.18)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

extension WidgetFamily {
    /// The family's word in identifiers: small, circular, rectangular.
    var pictureName: String {
        switch self {
        case .accessoryCircular: "circular"
        case .accessoryRectangular: "rectangular"
        case .accessoryInline: "inline"
        case .systemSmall: "small"
        case .systemMedium: "medium"
        case .systemLarge: "large"
        default: "other"
        }
    }
}
