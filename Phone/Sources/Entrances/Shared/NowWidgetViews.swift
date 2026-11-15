import SwiftUI
import WidgetKit

/// The Now widget's faces: the Mac's Now rows about mail, in its words
/// (NowShelf). The size is the one you placed and never changes; each has
/// its own face for when nothing waits: Search and Ask on the medium, the
/// Search widget's on the small. A row opens its mail where it is
/// (yab://now, NowOpen in the app). The widget extension draws these; the
/// app's pictures (widgets.4-5) draw the same ones.
struct NowWidgetFace: View {
    let rows: [NowShelfRow]
    let family: WidgetFamily

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: NowWidgetRectangular(rows: rows)
            case .systemSmall: NowWidgetSmall(rows: rows)
            default: NowWidgetMedium(rows: rows)
            }
        }
        .accessibilityIdentifier("widget.now.\(family.pictureName).\(rows.count)")
    }
}

enum NowWidgetMetrics {
    static let medium = CGSize(width: 364, height: 170)
    static let mark: CGFloat = 26
    static let bigMark: CGFloat = 40
    static let markRadius: CGFloat = 7
}

/// The row's mark: the sender's first letter on a color of their site.
struct NowRowMark: View {
    let row: NowShelfRow
    var size: CGFloat = NowWidgetMetrics.mark

    var body: some View {
        RoundedRectangle(cornerRadius: size * NowWidgetMetrics.markRadius / NowWidgetMetrics.mark, style: .continuous)
            .fill(Self.color(row.host.isEmpty ? row.who : row.host))
            .frame(width: size, height: size)
            .overlay {
                Text(row.letter)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .widgetAccentable()
            .accessibilityHidden(true)
    }

    /// One of a few deep colors, the same for a site every time.
    static func color(_ key: String) -> Color {
        let palette: [(Double, Double, Double)] = [(0.86, 0.27, 0.24), (0.07, 0.48, 0.79), (0.48, 0.36, 1.0),
                                                   (0.05, 0.54, 0.37), (0.95, 0.6, 0.0), (0.83, 0.25, 0.53)]
        let sum = key.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let (r, g, b) = palette[sum % palette.count]
        return Color(red: r, green: g, blue: b)
    }
}

/// "Now" over the rows, with Yab's mark.
private struct NowWidgetHead: View {
    var body: some View {
        HStack(spacing: 6) {
            EntranceMark(size: 16)
            Text("Now")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EntranceLook.primary)
            Spacer(minLength: 0)
        }
        .frame(height: 18)
    }
}

/// Home Screen, medium: one row says more, three are one line each.
struct NowWidgetMedium: View {
    let rows: [NowShelfRow]

    var body: some View {
        if rows.isEmpty {
            NowWidgetQuiet()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                NowWidgetHead()
                switch rows.count {
                case 1: one(rows[0])
                default:
                    VStack(spacing: 0) {
                        ForEach(Array(rows.prefix(NowShelf.limit).enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Rectangle().fill(EntranceLook.fill).frame(height: 0.5) }
                            line(row, roomy: rows.count == 2)
                        }
                    }
                    .padding(.top, rows.count == 2 ? 8 : 4)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func one(_ row: NowShelfRow) -> some View {
        Link(destination: row.link) {
            HStack(alignment: .top, spacing: 12) {
                NowRowMark(row: row, size: NowWidgetMetrics.bigMark)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(EntranceLook.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .privacySensitive()
                    Text(row.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(EntranceLook.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
        }
    }

    private func line(_ row: NowShelfRow, roomy: Bool) -> some View {
        Link(destination: row.link) {
            HStack(spacing: 10) {
                NowRowMark(row: row, size: roomy ? 30 : NowWidgetMetrics.mark)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: roomy ? 15 : 14, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(EntranceLook.primary)
                        .lineLimit(1)
                        .privacySensitive()
                    Text(row.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(EntranceLook.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
                Spacer(minLength: 0)
            }
            .frame(height: roomy ? 58 : 41)
            .contentShape(Rectangle())
        }
    }
}

/// Medium with nothing waiting: Yab's mark over Search and Ask, the two
/// ways in Yab already has as widgets of their own.
struct NowWidgetQuiet: View {
    private typealias M = SearchWidgetMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EntranceMark(size: M.mark)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                ForEach(SearchWidgetKind.allCases, id: \.self) { kind in
                    Link(destination: kind.route.url) {
                        HStack(spacing: 8) {
                            EntranceGlyph(kind.glyph, size: M.fieldGlyph)
                                .foregroundStyle(EntranceLook.glyph)
                                .widgetAccentable()
                            Text(kind.word)
                                .font(.system(size: M.fieldFont, weight: .medium))
                                .foregroundStyle(EntranceLook.placeholder)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, M.fieldLeading)
                        .frame(maxWidth: .infinity, minHeight: M.field, maxHeight: M.field)
                        .background(EntranceLook.fill, in: Capsule(style: .continuous))
                    }
                    .accessibilityLabel(kind.accessibilityLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Home Screen, small: the top row, and how many more; nothing waiting,
/// the Search widget's face.
struct NowWidgetSmall: View {
    let rows: [NowShelfRow]

    var body: some View {
        if let row = rows.first {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NowRowMark(row: row)
                    Spacer(minLength: 0)
                    EntranceMark(size: 16)
                }
                Text(row.who.isEmpty ? row.host : row.who)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EntranceLook.primary)
                    .lineLimit(1)
                    .padding(.top, 10)
                Text(row.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(EntranceLook.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .privacySensitive()
                    .padding(.top, 2)
                Spacer(minLength: 0)
                HStack {
                    Text(row.detail.components(separatedBy: " · ").first ?? "")
                        .privacySensitive()
                    Spacer(minLength: 0)
                    if rows.count > 1 { Text("+\(rows.count - 1) more") }
                }
                .font(.system(size: 12))
                .foregroundStyle(EntranceLook.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            SearchWidgetSmall(kind: .search)
        }
    }
}

/// Lock Screen, rectangular: who wrote, and what the top one is about once
/// the iPhone is unlocked; nothing waiting, Search.
struct NowWidgetRectangular: View {
    let rows: [NowShelfRow]

    var body: some View {
        if rows.isEmpty {
            SearchWidgetRectangular(kind: .search)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Now")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(rows.map { $0.who.isEmpty ? $0.host : $0.who }.joined(separator: ", "))
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text(rows[0].title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .privacySensitive()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
