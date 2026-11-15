import AppKit
import SwiftUI

// Under Get to Know's answer in its chat: its notebook (yab://you), a sheet
// of the page's own paper with the greeting in the pen, the name underlined
// as the page underlines it, and the portrait's start; under the sheet, a
// line saying what waits there. A click brings the page forward, as Notes
// About You in Settings does (docs/get-to-know.md, The chat).

struct KnowCard: View {
    let browser: Browser
    @State private var summary: KnowSummary?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { KnowPage.show(in: browser) } label: {
            VStack(alignment: .leading, spacing: 8) {
                sheet
                caption
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyTip("Open your notebook")
        // Read off the main thread: the Wallet is the keychain.
        .task { summary = await Task.detached(priority: .userInitiated) { KnowSummary.load() }.value }
    }

    // MARK: the sheet

    private var dark: Bool { scheme == .dark }
    /// The page's own paper and ink (KnowPage.html's --paper and --ink).
    private var paper: Color { dark ? Color(red: 0.114, green: 0.110, blue: 0.102) : Color(red: 0.949, green: 0.941, blue: 0.918) }
    private var ink: Color { dark ? Color(red: 0.925, green: 0.922, blue: 0.902) : Color(red: 0.090, green: 0.090, blue: 0.090) }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 2) {
            greeting
            if let portrait = summary?.portrait, !portrait.isEmpty {
                Text(portrait)
                    .font(.system(size: 12))
                    .foregroundStyle(ink)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, minHeight: 78, maxHeight: 78, alignment: .topLeading)
        .background {
            // design: a miniature of yab://you's paper, its dots every 18 pt
            Rectangle().fill(paper).overlay(Image(nsImage: KnowCard.dots(dark)).resizable(resizingMode: .tile))
        }
        // The page goes on below: the sheet fades out where the card ends.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.62), .init(color: .black.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// "nice to meet you, Mira!", the name underlined by the pen.
    private var greeting: some View {
        let first = summary?.first ?? ""
        let hand = Font(UpdateInk.hand(22, weight: 500))
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(first.isEmpty ? "nice to meet you!" : "nice to meet you, ")
            if !first.isEmpty {
                Text(first)
                    .overlay { GeometryReader { box in KnowUnderline(width: box.size.width, height: box.size.height).stroke(UpdateInk.pen, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)) } }
                Text("!")
            }
        }
        .font(hand)
        .foregroundStyle(UpdateInk.pen)
        .lineLimit(1)
    }

    // MARK: the line under it

    private var caption: some View {
        HStack(spacing: 8) {
            Symbol("notes", size: 11.5)
                .foregroundStyle(Palette.muted)
                .frame(width: 14, height: 14)
            Text("Notes about you")
                .foregroundStyle(Palette.ink)
            if let summary, summary.lines > 0 {
                Text(summary.seen ? "\(summary.lines) \(summary.lines == 1 ? "thing" : "things") it kept" : "\(summary.lines) \(summary.lines == 1 ? "thing" : "things") to look over")
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13.5))
        .frame(height: 20)
    }

    // MARK: the paper's dots

    /// One dot in the middle of an 18 pt square, tiled: the page's
    /// radial-gradient background, in the page's two inks.
    private static let light = tile(NSColor(white: 0, alpha: 0.075))
    private static let night = tile(NSColor(white: 1, alpha: 0.05))
    static func dots(_ dark: Bool) -> NSImage { dark ? night : light }

    private static func tile(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 2, height: 2)).fill()
            return true
        }
    }
}

/// The page's underline under the name (KnowPage.html, `underline`), drawn
/// at the card's size: a stroke under the words that ends in a small loop.
struct KnowUnderline: Shape {
    let width: CGFloat
    let height: CGFloat

    func path(in rect: CGRect) -> Path {
        // The page draws it under its 58 pt hand, a box some 60 tall; here
        // the same, scaled to this one's box.
        let k = height / 60
        let x = -4 * k, y = height - 10 * k, w = width + 12 * k
        var p = Path()
        p.move(to: CGPoint(x: x, y: y + 2 * k))
        p.addCurve(to: CGPoint(x: x + w, y: y + 1 * k), control1: CGPoint(x: x + w * 0.35, y: y + 8 * k), control2: CGPoint(x: x + w * 0.7, y: y - 1 * k))
        var at = CGPoint(x: x + w, y: y + 1 * k)
        for (c1, c2, to) in [((8.0, -1.0), (10.0, -10.0), (3.0, -11.0)), ((-7.0, -1.0), (-9.0, 9.0), (0.0, 13.0)), ((6.0, 2.0), (12.0, 1.0), (18.0, -3.0))] {
            let end = CGPoint(x: at.x + to.0 * k, y: at.y + to.1 * k)
            p.addCurve(to: end, control1: CGPoint(x: at.x + c1.0 * k, y: at.y + c1.1 * k), control2: CGPoint(x: at.x + c2.0 * k, y: at.y + c2.1 * k))
            at = end
        }
        return p
    }
}
