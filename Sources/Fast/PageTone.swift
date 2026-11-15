import AppKit

/// A color is written only by the latest read of the current document,
/// after the same surface has agreed twice. Failed reads keep the last
/// good color, rather than flashing the window's default between them.
struct PageToneGate {
    struct Ticket: Equatable {
        let document: UInt64
        let request: UInt64
    }

    private(set) var document: UInt64 = 0
    private var request: UInt64 = 0
    private var candidate: NSColor?
    private var since: TimeInterval = 0

    mutating func invalidate() {
        document &+= 1
        candidate = nil
    }

    mutating func begin() -> Ticket {
        request &+= 1
        return Ticket(document: document, request: request)
    }

    func current(_ ticket: Ticket) -> Bool {
        ticket.document == document && ticket.request == request
    }

    mutating func offer(_ color: NSColor, ticket: Ticket, now: TimeInterval) -> Bool {
        guard current(ticket), now.isFinite else { return false }
        if let candidate, Self.near(candidate, color) { return now - since >= 0.12 }
        candidate = color
        since = now
        return false
    }

    static func near(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return max(abs(a.redComponent - b.redComponent),
                   max(abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))) <= 12.0 / 255
    }
}

struct PageToneReading {
    let color: NSColor?
    let rect: CGRect
    let href: String

    init?(_ answer: Any?, size: CGSize) {
        guard let row = answer as? [String: Any], let href = row["href"] as? String,
              let width = row["width"] as? Double, let height = row["height"] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0,
              let region = (row["regions"] as? [[String: Double]])?.first,
              let x = region["x"], let y = region["y"], let w = region["width"], let h = region["height"],
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
        self.href = href
        let rect = CGRect(x: x * size.width / width, y: y * size.height / height,
                          width: w * size.width / width, height: h * size.height / height)
            .intersection(CGRect(origin: .zero, size: size))
        guard !rect.isNull, !rect.isEmpty else { return nil }
        self.rect = rect
        if let rgb = row["color"] as? [Double], rgb.count == 3,
           rgb.allSatisfy({ $0.isFinite && (0...255).contains($0) }) {
            color = NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1)
        } else { color = nil }
    }
}
