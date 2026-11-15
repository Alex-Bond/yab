import AppKit
import SwiftUI

// One way for every name Yab gives on its own (While You Browse): a kept
// tab's short name (ShortNames), a folder made from tabs (LinkFolders), a
// download (DownloadNames). The old name goes to dust as Clear's rows do
// (Dust.swift), the window crossing it left to right, and the new one comes
// in right behind the window, in the space's color, which settles to the
// row's ink. The sand band chosen on 2026-10-20 (docs/tidy-names.md).
//
// Without dust (Reduce Motion, Low Power Mode, the column out of sight, the
// shader not built yet) the new name is simply there, as before.

@MainActor
enum Rename {
    /// The selected prototype: one band over the name in 620 ms.
    nonisolated static let cross: TimeInterval = 0.62
    /// How far behind the window the new letters come, and over how much.
    static let lag: CGFloat = 4
    static let soft: CGFloat = 18
    /// The space's color held, then eased to ink.
    static let hold: TimeInterval = cross + 0.5
    static let settle: TimeInterval = 0.5
    static var length: TimeInterval { hold + settle }

    /// What a row's name occupies, from its row's frame (DrawnRows): after
    /// the mark and its gap, to the end slot. A little of the gap before
    /// the letters is kept in, where Dust reads the row's own ground.
    static func titleRect(row: CGRect) -> CGRect {
        let x = row.minX + SideBar.inner + SideBar.mark + SideBar.markGap - 4
        return CGRect(x: x, y: row.minY, width: max(0, row.maxX - Density.current.endInset - x), height: row.height)
    }

    /// The name drawn in `rect` (the column's space) gone to dust now. True
    /// when the dust plays: the caller shows the new name with a Reveal from
    /// now, in the same pass, so the old letters and the dust swap in one
    /// commit. False: nothing happened, show the new name plainly.
    static func dust(_ rect: CGRect, in browser: Browser) -> Bool {
        guard let column = browser.column, column.shown else { return false }
        let clip = browser.rowsClip ?? column.bounds
        let shown = rect.intersection(clip)
        guard !shown.isNull, shown.width > 24, shown.height > 8 else { return false }
        return column.dust([DustRow(rect: shown, start: 0, fold: 0)], renaming: true)
    }

    /// A tab's row: its name to dust, if it is drawn.
    static func dust(tab: Tab, in browser: Browser) -> Bool {
        guard let row = browser.drawnRows[DrawnRows.tab(tab.id)] else { return false }
        return dust(titleRect(row: row), in: browser)
    }

    /// A folder's row, the gray bar or the name it had.
    static func dust(folder id: String, in browser: Browser) -> Bool {
        guard let row = browser.drawnRows[DrawnRows.folder(id)] else { return false }
        return dust(titleRect(row: row), in: browser)
    }

    /// The color a new name comes in: the space's, deep enough to read on
    /// its column; the system's accent off a toned column.
    static func tint(_ tone: Tone?) -> Color {
        guard let tone, !tone.glass else { return Color(nsColor: .controlAccentColor) }
        let base = tone.page.usingColorSpace(.sRGB) ?? tone.page
        let toward: NSColor = tone.scheme == .dark ? .white : .black
        let deep = base.blended(withFraction: tone.scheme == .dark ? 0.45 : 0.55, of: toward) ?? base
        // A gray space would give a gray: then the accent.
        let s = deep.usingColorSpace(.sRGB).map { max($0.redComponent, $0.greenComponent, $0.blueComponent) - min($0.redComponent, $0.greenComponent, $0.blueComponent) } ?? 0
        return s < 0.12 ? Color(nsColor: .controlAccentColor) : Color(nsColor: deep)
    }

    /// Warmed ahead: the shader is built the first time it is asked for.
    static func warm() { Dust.shared.warm() }
}

/// A name coming in behind the dust: left of the window's place, the name,
/// tinted at first; right of it, nothing yet (its old letters are dust).
/// Only while it plays: a mask and a clock for about a second, then the
/// row as it always is.
struct RenameReveal: ViewModifier {
    let since: Date?
    let tint: Color
    @State private var finished: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if let since, finished != since, !reduceMotion, Date().timeIntervalSince(since) < Rename.length {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(since)
                    let ink = min(1, max(0, (t - Rename.hold) / Rename.settle))
                    content
                        .overlay {
                            Rectangle().fill(tint)
                                .mask(content)
                                .opacity(1 - ink)
                                .allowsHitTesting(false)
                        }
                        .mask(alignment: .leading) {
                            GeometryReader { g in
                                let w = max(1, g.size.width)
                                let edge = w * CGFloat(t / Rename.cross) - Rename.lag
                                let full = min(1, max(0, (edge - Rename.soft) / w))
                                let none = min(1, max(full + 0.0001, edge / w))
                                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: full),
                                                       .init(color: edge >= w ? .black : .clear, location: none)],
                                               startPoint: .leading, endPoint: .trailing)
                            }
                        }
                }
            } else {
                content
            }
        }
        .task(id: since) {
            guard let since else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, Rename.length - Date().timeIntervalSince(since))))
            } catch { return }
            guard !Task.isCancelled else { return }
            finished = since
        }
    }
}
