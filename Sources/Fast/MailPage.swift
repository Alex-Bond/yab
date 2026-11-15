import AppKit
import SwiftUI

// yab://mail: the tab that holds mail's place in its space (MailSpace). The
// app draws mail over it (MailPane, MailDesk); the page itself is a ground.
// Which list a thread is in (MailSplit) and a mail's own HTML made safe to
// show (MailHTML) are files of their own.

enum MailPage {
    static let url = URL(string: "yab://mail")!
    static let host = "mail"

    static func isMail(_ url: URL?) -> Bool {
        url?.scheme == DiaryPage.scheme && url?.host() == host
    }

    static var page: Data { Data(html.utf8) }

    /// The mail pin's mark, and the mail tab's: the envelope emoji in the
    /// dark, and on a light ground, where the white envelope all but goes,
    /// the same envelope drawn in gray.
    @MainActor
    static var mark: NSImage { Favicons.dark ? Spaces.picture(emoji: "✉️", side: 16) : gray }

    /// ✉️ in gray: the emoji's shapes, its body, the sides folded in, the
    /// bottom fold and the flap with its rim, each a shade apart.
    private static let gray = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { r in
        let u = r.width / 16
        let body = CGRect(x: 1.1 * u, y: 3.2 * u, width: 13.8 * u, height: 9.6 * u)
        let round = NSBezierPath(roundedRect: body, xRadius: 1.1 * u, yRadius: 1.1 * u)
        let (x0, y0, x1, y1, cx) = (body.minX, body.minY, body.maxX, body.maxY, body.midX)
        NSGraphicsContext.saveGraphicsState()
        let under = NSShadow()
        under.shadowColor = NSColor(white: 0, alpha: 0.25)
        under.shadowBlurRadius = 0.6 * u
        under.shadowOffset = NSSize(width: 0, height: -0.3 * u)
        under.set()
        NSColor(white: 0.48, alpha: 1).setFill()
        round.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        round.addClip()
        let meet = NSPoint(x: cx, y: y0 + body.height * 0.58)
        let sides = NSBezierPath()
        sides.move(to: NSPoint(x: x0, y: y0)); sides.line(to: meet); sides.line(to: NSPoint(x: x0, y: y1)); sides.close()
        sides.move(to: NSPoint(x: x1, y: y0)); sides.line(to: meet); sides.line(to: NSPoint(x: x1, y: y1)); sides.close()
        NSGradient(starting: NSColor(white: 0.45, alpha: 1), ending: NSColor(white: 0.41, alpha: 1))?.draw(in: sides, angle: 90)
        let bottom = NSBezierPath()
        bottom.move(to: NSPoint(x: x0 - u, y: y1 + 0.2 * u))
        bottom.line(to: NSPoint(x: cx, y: y0 + body.height * 0.40))
        bottom.line(to: NSPoint(x: x1 + u, y: y1 + 0.2 * u))
        bottom.close()
        NSGradient(starting: NSColor(white: 0.54, alpha: 1), ending: NSColor(white: 0.47, alpha: 1))?.draw(in: bottom, angle: 90)
        let tip = y0 + body.height * 0.66
        let flap = NSBezierPath()
        flap.move(to: NSPoint(x: x0 - 0.2 * u, y: y0 - 0.2 * u))
        flap.line(to: NSPoint(x: cx - 1.1 * u, y: tip - 0.75 * u))
        flap.curve(to: NSPoint(x: cx + 1.1 * u, y: tip - 0.75 * u),
                   controlPoint1: NSPoint(x: cx - 0.45 * u, y: tip), controlPoint2: NSPoint(x: cx + 0.45 * u, y: tip))
        flap.line(to: NSPoint(x: x1 + 0.2 * u, y: y0 - 0.2 * u))
        flap.close()
        NSGraphicsContext.saveGraphicsState()
        let lift = NSShadow()
        lift.shadowColor = NSColor(white: 0, alpha: 0.5)
        lift.shadowBlurRadius = 0.5 * u
        lift.shadowOffset = NSSize(width: 0, height: -0.25 * u)
        lift.set()
        NSGradient(starting: NSColor(white: 0.60, alpha: 1), ending: NSColor(white: 0.52, alpha: 1))?.draw(in: flap, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.70, alpha: 1).setStroke()
        flap.lineWidth = 0.45 * u
        flap.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 1, alpha: 0.10).setStroke()
        round.lineWidth = 0.3 * u
        round.stroke()
        return true
    }
}

extension Browser {
    /// Mail's space, the mail page in front.
    func showMail() {
        enterMail()
    }
}

extension MailPage {
    /// Only a ground: the tab holds mail's place in its space, and the app
    /// draws mail over it (MailPane).
    static let html = #"""
    <!doctype html><html><head><meta charset="utf-8"><title>Mail</title>
    <style>html,body{margin:0;height:100%;background:#fff}@media (prefers-color-scheme: dark){html,body{background:#1c1c1c}}</style>
    </head><body></body></html>
    """#
}
