import AppKit
import MailCore
import SwiftUI

// The small pictures a new tab's rows and Now's wear, one per kind of
// thing, drawn with the pen as Settings draws its pages (PenArt): paper,
// a marker swipe of the kind's color, the ink over it. A kind borrows a
// Settings drawing where one says the same thing (mail, a calendar, a
// card) and has its own where none does (picked 2026-10-14). An agent
// names the kind in `suggest`; without one, the site says it (Gmail is
// mail, GitHub a review, Stripe money). When a row is about one thing in
// one place, the place's own icon sits on the picture's corner.

enum Pictures {
    /// A kind's drawing in PenArt, and its swipe's color.
    struct Drawing {
        let ink: String
        let color: UInt32
    }

    static let kinds: [String: Drawing] = [
        "me": Drawing(ink: "person.text.rectangle", color: 0xa96be0),
        "mail": Drawing(ink: "mail", color: 0x2f8cf6),
        "reply": Drawing(ink: "reply", color: 0x2f8cf6),
        "money": Drawing(ink: "autofill", color: 0xf0943a),
        "failed": Drawing(ink: "failed", color: 0xe5534b),
        "invoice": Drawing(ink: "invoice", color: 0xe8b33a),
        "flight": Drawing(ink: "flight", color: 0x34b85a),
        "stay": Drawing(ink: "stay", color: 0x34b85a),
        "calendar": Drawing(ink: "calendar", color: 0xa96be0),
        "meeting": Drawing(ink: "video", color: 0xa96be0),
        "code": Drawing(ink: "developers", color: 0x808087),
        "review": Drawing(ink: "review", color: 0xa96be0),
        "chat": Drawing(ink: "feedback", color: 0xe84c6c),
        "shopping": Drawing(ink: "shopping", color: 0xf0943a),
        "delivery": Drawing(ink: "delivery", color: 0xe8b33a),
        "document": Drawing(ink: "doc", color: 0x2f8cf6),
        "sign": Drawing(ink: "sign", color: 0x808087),
        "reading": Drawing(ink: "book", color: 0x34b85a),
        "terminal": Drawing(ink: "terminal", color: 0x808087),
        "security": Drawing(ink: "lock", color: 0xe8b33a),
        "routine": Drawing(ink: "agentRoutines", color: 0xe84c6c),
        "video": Drawing(ink: "play", color: 0xe5534b),
        // Settings › AI's own drawing and color: Connect Claude or ChatGPT.
        "ai": Drawing(ink: "ai", color: 0xa96be0),
    ]

    private static var made: [String: NSImage] = [:]

    /// Not a drawing: Yab for iPhone's own icon, for the row that offers it
    /// (PhoneBeta), as a row that unlocks a thing wears that thing's mark.
    static let iphone = "iphone"

    /// A kind's tile at `side` points, in light or dark: Settings' paper,
    /// its drawing at Now's 0.78 of it, as the field's places are drawn.
    static func image(_ kind: String, side: CGFloat, dark: Bool) -> NSImage? {
        if kind == iphone { return PhoneBeta.icon }
        let key = "\(kind) \(side) \(dark)"
        if let hit = made[key] { return hit }
        guard let drawing = kinds[kind] else { return nil }
        let color = NSColor(srgbRed: CGFloat(drawing.color >> 16 & 0xff) / 255, green: CGFloat(drawing.color >> 8 & 0xff) / 255,
                            blue: CGFloat(drawing.color & 0xff) / 255, alpha: 1)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            PenArt.draw(drawing.ink, symbol: drawing.ink, color: color, in: rect, dark: dark, art: 0.78)
            return true
        }
        made[key] = image
        return image
    }

    /// A kind for a row an agent didn't name one for, from where it is.
    static func kind(for host: String?) -> String {
        let host = (host ?? "").lowercased()
        let table: [(String, String)] = [
            ("mail.google", "mail"), ("outlook", "mail"), ("calendar.google", "calendar"), ("github", "review"),
            ("gitlab", "review"), ("linear", "code"), ("atlassian", "code"), ("stripe", "money"), ("paypal", "money"),
            ("bank", "money"), ("slack", "chat"), ("discord", "chat"), ("linkedin", "chat"), ("telegram", "chat"),
            ("whatsapp", "chat"), ("x.com", "chat"), ("amazon", "delivery"), ("ups", "delivery"), ("fedex", "delivery"),
            ("docs.google", "document"), ("notion", "document"), ("docusign", "sign"), ("youtube", "video"),
            ("airbnb", "stay"), ("booking", "stay"), ("airline", "flight"), ("flights", "flight"), ("zoom", "meeting"),
        ]
        return table.first { host.contains($0.0) }?.1 ?? "document"
    }
}

/// A row's mark: its picture, with the site it is about on the corner.
struct HintPicture: View {
    let kind: String
    let site: String?
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = Pictures.image(kind, side: size, dark: scheme == .dark) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: size, height: size)
            }
            if let site = HintPicture.badge(site) {
                // Its own icon only, never a letter standing in for it: a
                // "G" read as the sender's initial.
                if let icon = Favicons.shared.cached(site) ?? Favicons.shared.cached("www." + site) {
                    Mark(icon: icon, letter: "", size: size * 0.42)
                        .padding(1)
                        .background(RoundedRectangle(cornerRadius: size * 0.42 * 0.22 + 1, style: .continuous).fill(Palette.ground))  // design: the plate under a corner mark, not a card
                        .offset(x: 4, y: 4)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { if let site = HintPicture.badge(site), Favicons.shared.cached(site) == nil { Favicons.shared.fetch(host: site) } }
    }

    /// The site worth a mark on the corner: not one everyone writes from,
    /// gmail.com says nothing of a mail from a person.
    static func badge(_ site: String?) -> String? {
        guard let site, !site.isEmpty else { return nil }
        let bare = site.hasPrefix("www.") ? String(site.dropFirst(4)) : site
        return MailBlock.common.contains(bare.lowercased()) ? nil : bare
    }
}

extension FieldPlace {
    /// A place's own pen drawing on its tile, where Settings has none to lend.
    var pen: String? { rawValue == "now" ? "now" : nil }
}
