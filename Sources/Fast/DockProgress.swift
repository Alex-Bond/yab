import AppKit

// Downloads under way, on Yab's icon in the Dock, as browsers show
// them (register 1006): a bar across the foot of the icon, filling with the
// bytes of every download in every window together, from the first one
// that starts until the last is in, stopped or failed. Then the Dock shows
// the plain icon again.
//
// The tile's content view draws the icon itself and the bar over it. The
// Mail badge (MailNotify.badge) is the Dock's own label and is drawn over
// whatever the tile shows, so it stays as it is.

@MainActor
final class DockProgress {
    static let shared = DockProgress()

    /// One download's bytes: what has come, and the whole when the site
    /// said it (0 or less when it didn't).
    struct Bytes: Equatable {
        var got: Int64
        var total: Int64
    }

    /// What each window's downloads button has under way (Hoard.toldDock).
    private var windows: [ObjectIdentifier: [Bytes]] = [:]
    /// The bar's fill as drawn, nil while the tile is the plain icon.
    private(set) var shown: Double?
    private var view: DockProgressView?

    /// The bar's fill for downloads under way: the bytes come of all of them
    /// over the bytes of all of them, among those whose size is known, to
    /// the half percent and never ahead. Nil when nothing is under way; 0
    /// while none has said its size, so the bar still says something is.
    nonisolated static func fraction(_ downloads: [Bytes]) -> Double? {
        guard !downloads.isEmpty else { return nil }
        let known = downloads.filter { $0.total > 0 }
        let total = known.reduce(Int64(0)) { $0 + $1.total }
        guard total > 0 else { return 0 }
        let got = known.reduce(Int64(0)) { $0 + min(max($1.got, 0), $1.total) }
        return (Double(got) / Double(total) * 200).rounded(.down) / 200
    }

    /// A window's downloads now; an empty list when it has none going, or
    /// has closed.
    func report(_ window: ObjectIdentifier, _ downloads: [Bytes]) {
        windows[window] = downloads.isEmpty ? nil : downloads
        show(Self.fraction(windows.values.flatMap { $0 }))
    }

    private func show(_ fraction: Double?) {
        guard fraction != shown, let tile = NSApp?.dockTile else { return }
        shown = fraction
        if let fraction {
            let view = self.view ?? DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            self.view = view
            view.fraction = fraction
            if tile.contentView !== view { tile.contentView = view }
        } else if tile.contentView === view {
            tile.contentView = nil
        }
        // A tile with a content view is drawn only when asked.
        tile.display()
    }

    /// The tile as the Dock is drawing it now, for the bench: the bar's view
    /// while something is under way, the plain icon otherwise.
    func picture() -> NSBitmapImageRep? {
        let tile = NSApp?.dockTile
        let size = tile?.size ?? NSSize(width: 128, height: 128)
        let view = tile?.contentView ?? DockIconView(frame: NSRect(origin: .zero, size: size))
        if view.frame.size != size { view.frame = NSRect(origin: .zero, size: size) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

/// The icon as the Dock shows it, whichever one is chosen (AppIconStyle).
class DockIconView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
    }
}

/// The icon with the downloads' bar over its foot.
final class DockProgressView: DockIconView {
    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }

    /// The track, in a tile of `bounds`: across most of the icon, over the
    /// foot of its art.
    static func track(in bounds: NSRect) -> NSRect {
        let width = (bounds.width * 0.7).rounded()
        let height = (bounds.height * 0.11).rounded()
        return NSRect(x: ((bounds.width - width) / 2).rounded(), y: (bounds.height * 0.14).rounded(),
                      width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Light or dark as the Dock is, not as Yab's own Theme sets its windows.
        let look = NSAppearance(named: AppIconStyle.systemDark ? .darkAqua : .aqua)
        (look ?? effectiveAppearance).performAsCurrentDrawingAppearance { self.drawBar() }
    }

    private func drawBar() {
        let track = Self.track(in: bounds)
        let outer = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        Palette.NS.ground.setFill()
        outer.fill()
        Palette.NS.hairline.setStroke()
        outer.lineWidth = 1
        outer.stroke()
        // The fill a real inset in from the track, its corner the track's
        // less that inset (concentric).
        let inset: CGFloat = 2
        let room = track.insetBy(dx: inset, dy: inset)
        guard fraction > 0, room.width > 0 else { return }
        var fill = room
        fill.size.width = max(room.height, (room.width * CGFloat(min(fraction, 1))).rounded())
        Palette.NS.ink.setFill()
        NSBezierPath(roundedRect: fill, xRadius: room.height / 2, yRadius: room.height / 2).fill()
    }
}
