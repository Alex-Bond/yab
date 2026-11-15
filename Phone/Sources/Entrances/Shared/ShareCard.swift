import SwiftUI

/// Where the share sheet's card is: reading what was shared, offering it,
/// or after a choice that leaves the card up a moment.
enum ShareCardPhase: Equatable, Sendable {
    case loading
    case ready
    /// Keep for Later done: said, then the sheet goes.
    case kept
    /// Yab couldn't be opened from here: the link waits in the queue.
    case waiting
    /// Nothing Yab can open, or the queue couldn't be written.
    case nothing
    case failed
}

/// The share sheet's sizes: New Tab's field, as a sheet.
enum ShareCardMetrics {
    static let padding: CGFloat = 20
    static let headHeight: CGFloat = 30
    static let mark: CGFloat = 28
    static let headFont: CGFloat = 17
    static let close: CGFloat = 30
    static let closeGlyph: CGFloat = 14
    static let gap: CGFloat = 16
    /// The page: its glyph on a 40 tile, title 16 semibold, host 13.
    static let pageHeight: CGFloat = 64
    static let pageRadius: CGFloat = 20
    static let pageTile: CGFloat = 40
    static let pageTileRadius: CGFloat = 12
    static let pageGlyph: CGFloat = 20
    static let titleFont: CGFloat = 16
    static let lineFont: CGFloat = 13
    /// The two buttons: 50 high capsules, 10 apart, 16 semibold.
    static let button: CGFloat = 50
    static let buttonGap: CGFloat = 10
    static let buttonFont: CGFloat = 16
    static let buttonGlyph: CGFloat = 18
    /// The sheet above the home indicator's room: the card's rows and their gaps.
    static let sheetHeight: CGFloat = padding + headHeight + gap + pageHeight + gap + button + padding
}

/// The share sheet's Yab, in Yab's own look: the mark, what was shared, and
/// Keep for Later beside Open in Yab.
/// Words without a link offer Search in Yab alone. Drawn by the share
/// extension (Phone/Share) and by the app's pictures of it (share.1-3).
struct ShareCard: View {
    let found: SharedItems.Found?
    let phase: ShareCardPhase
    var open: () -> Void = {}
    var keep: () -> Void = {}
    var close: () -> Void = {}

    private typealias M = ShareCardMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: M.gap) {
            head
            page
            foot
        }
        .padding(M.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(EntranceLook.surface)
        .foregroundStyle(EntranceLook.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.card")
    }

    private var head: some View {
        HStack(spacing: 10) {
            EntranceMark(size: M.mark)
            Text("Yab")
                .font(.system(size: M.headFont, weight: .semibold))
                .tracking(-0.01 * M.headFont)
            Spacer(minLength: 0)
            Button(action: close) {
                // The app's crosses are the system's xmark (Design/Glyph.swift).
                Image(systemName: "xmark")
                    .font(.system(size: M.closeGlyph, weight: .semibold))
                    .foregroundStyle(EntranceLook.secondary)
                    .frame(width: M.close, height: M.close)
                    .background(EntranceLook.fill, in: Circle())
                    // 30 to see, 44 to hit.
                    .contentShape(Rectangle().inset(by: -7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("share.close")
        }
        .frame(height: M.headHeight)
    }

    /// The page shared (or the words), on a quiet card.
    private var page: some View {
        HStack(spacing: 12) {
            EntranceGlyph(found?.search == true ? "MagnifyingGlass" : "Globe", size: M.pageGlyph)
                .foregroundStyle(EntranceLook.glyph)
                .frame(width: M.pageTile, height: M.pageTile)
                .background(EntranceLook.surface, in: RoundedRectangle(cornerRadius: M.pageTileRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: M.titleFont, weight: .semibold))
                    .tracking(-0.01 * M.titleFont)
                    .lineLimit(1)
                Text(line)
                    .font(.system(size: M.lineFont))
                    .foregroundStyle(EntranceLook.secondary)
                    .lineLimit(1)
            }
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("share.title")
        }
        .padding(.horizontal, 12)
        .frame(height: M.pageHeight)
        .background(EntranceLook.fill, in: RoundedRectangle(cornerRadius: M.pageRadius, style: .continuous))
        .redacted(reason: phase == .loading ? .placeholder : [])
    }

    private var title: String {
        guard let found else { return phase == .loading ? "Reading what was shared" : "Nothing to open" }
        if found.search { return "\u{201C}\(found.address)\u{201D}" }
        return found.title ?? found.host ?? found.address
    }

    private var line: String {
        guard let found else { return phase == .loading ? "…" : "Share a link or some words" }
        if found.search { return "Search the web in Yab" }
        return found.host ?? found.address
    }

    @ViewBuilder
    private var foot: some View {
        switch phase {
        case .loading, .ready:
            HStack(spacing: M.buttonGap) {
                if found?.search == false {
                    capsule("Keep for Later", glyph: "Thumbtack", dark: false, id: "share.keep", action: keep)
                }
                capsule(found?.search == true ? "Search in Yab" : "Open in Yab", glyph: nil, dark: true, id: "share.open", action: open)
            }
            .disabled(phase == .loading)
        case .kept:
            said("Kept for later in Yab", glyph: "Checkmark1", tint: EntranceLook.done)
        case .waiting:
            said("Saved. Yab opens it when you open Yab next.", glyph: "Clock", tint: EntranceLook.secondary)
        case .nothing, .failed:
            said(phase == .failed ? "Yab couldn\u{2019}t take this. Try again." : "There\u{2019}s no link or text here.",
                 glyph: "ExclamationCircle", tint: EntranceLook.secondary)
        }
    }

    private func capsule(_ word: String, glyph: String?, dark: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let glyph { EntranceGlyph(glyph, size: M.buttonGlyph) }
                Text(word)
                    .font(.system(size: M.buttonFont, weight: .semibold))
                    .tracking(-0.01 * M.buttonFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(dark ? Color.white : EntranceLook.primary)
            .frame(maxWidth: .infinity)
            .frame(height: M.button)
            .background(dark ? EntranceLook.button : EntranceLook.fill, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// A done or a can't, where the buttons were, the card's height kept.
    private func said(_ words: String, glyph: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            EntranceGlyph(glyph, size: M.buttonGlyph)
                .foregroundStyle(tint)
            Text(words)
                .font(.system(size: M.buttonFont, weight: .semibold))
                .tracking(-0.01 * M.buttonFont)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if phase != .kept {
                Button("Done", action: close)
                    .font(.system(size: M.buttonFont, weight: .semibold))
                    .foregroundStyle(EntranceLook.primary)
                    .padding(.horizontal, 18)
                    .frame(height: M.button)
                    .background(EntranceLook.fill, in: Capsule(style: .continuous))
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("share.done")
            }
        }
        .frame(height: M.button)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.said")
    }
}
