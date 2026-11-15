import AppKit

/// The best friend charm as a picture: Yab's blob as a gold-rimmed enamel
/// charm broken in two, your half on the left and theirs on the right, over
/// the charm's own ground. The ground comes from Icon Composer like every
/// other icon (Icon/Alternates/90-charm-ground.png → AppIcons/90-charm-ground.icns),
/// so the mask, the shadow and the edge are macOS's; the halves are layers
/// cut from one whole charm (Resources/Charm), in each one's color, drawn
/// into the art's square, whole or a little apart.
///
/// Plain AppKit and nothing of the app's, because the Dock tile's plug-in
/// (DockTile/DockTile.swift) draws the same picture in the Dock's process:
/// build.sh compiles this file into both.
enum CharmDraw {
    /// The colors a half comes in; silver is the right half before your
    /// best friend picks theirs.
    static let colors = ["mint", "lilac", "sky", "rose", "coral", "lemon", "indigo"]

    /// The square an icon's art fills in Icon Composer's 1024 grid: the
    /// squircle, 100 in from each side.
    static let art = NSRect(x: 100, y: 100, width: 824, height: 824)

    /// The charm, drawn at 1024 points. `right` nil is the half no one has
    /// colored yet; `apart` parts them along the break, a little, the way
    /// the charm looks while one of you is away.
    static func image(resources: URL, left: String, right: String?, apart: Bool) -> NSImage? {
        guard let parts = parts(resources: resources, left: left, right: right) else { return nil }
        let (ground, leftHalf, rightHalf) = parts
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            ground.draw(in: rect)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: art, xRadius: 185, yRadius: 185).addClip()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(srgbRed: 0.24, green: 0.12, blue: 0.16, alpha: 0.22)
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.shadowBlurRadius = 20
            shadow.set()
            draw(leftHalf, shift: apart ? -1 : 0)
            draw(rightHalf, shift: apart ? 1 : 0)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// The pieces `image` puts together, for a picture that moves the
    /// halves itself (Settings › Best Friend parts them under the pointer):
    /// the ground at 1024 points and each half as cut, filling `art`.
    static func parts(resources: URL, left: String, right: String?) -> (ground: NSImage, left: NSImage, right: NSImage)? {
        guard let leftHalf = half(resources, "left-" + valid(left)),
              let rightHalf = half(resources, "right-" + (right.map(valid) ?? "silver")) else { return nil }
        let ground = NSImage(contentsOf: resources.appendingPathComponent("AppIcons/90-charm-ground.icns"))
            ?? NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
                // Without the compiled ground (a run from the checkout):
                // the same color in a rounded square, near enough.
                NSColor(srgbRed: 243 / 255, green: 238 / 255, blue: 230 / 255, alpha: 1).setFill()
                NSBezierPath(roundedRect: art, xRadius: 185, yRadius: 185).fill()
                return true
            }
        return (ground, leftHalf, rightHalf)
    }

    /// A half in the art's square, moved out along the break and turned a
    /// few degrees when the two are apart.
    private static func draw(_ half: NSImage, shift: CGFloat) {
        guard shift != 0 else {
            half.draw(in: art)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let turn = NSAffineTransform()
        turn.translateX(by: art.midX + shift * art.width * 0.035, yBy: art.midY)
        turn.rotate(byDegrees: -shift * 3)
        turn.translateX(by: -art.midX, yBy: -art.midY)
        turn.concat()
        half.draw(in: art)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func valid(_ color: String) -> String { colors.contains(color) ? color : "mint" }

    private static func half(_ resources: URL, _ name: String) -> NSImage? {
        NSImage(contentsOf: resources.appendingPathComponent("Charm/\(name).png"))
    }
}
