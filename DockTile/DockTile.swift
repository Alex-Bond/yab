import AppKit

/// The Dock's tile for Yab while Yab isn't running. The running app sets its
/// chosen icon itself (AppIconStyle.apply), but macOS forgets that on quit
/// and shows the bundle's icon again. The Dock loads this plug-in for a tile
/// kept in it and draws what it says, so the chosen icon stays put.
///
/// It runs in the Dock's own process, apart from the app: it reads the
/// choice from the app's preferences and the icons from the app's bundle,
/// and hears the app's note when the choice changes.
@objc(YabDockTile)
final class YabDockTile: NSObject, NSDockTilePlugIn {
    private var tile: NSDockTile?
    private var observers: [NSObjectProtocol] = []

    /// The app around this plug-in: Contents/PlugIns/YabDockTile.docktileplugin.
    private lazy var app: Bundle? = {
        let url = Bundle(for: YabDockTile.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: url)
    }()

    func setDockTile(_ dockTile: NSDockTile?) {
        tile = dockTile
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers = []
        guard dockTile != nil, let id = app?.bundleIdentifier else { return }
        let center = DistributedNotificationCenter.default()
        // The notes AppIconStyle.announce() and macOS (AppIconStyle.systemChanged) post.
        for name in ["\(id).appIconChanged", "AppleInterfaceThemeChangedNotification"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                // A beat after, so the setting has turned over.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.draw() }
            })
        }
        draw()
    }

    private func draw() {
        guard let tile, let app, let id = app.bundleIdentifier else { return }
        CFPreferencesAppSynchronize(id as CFString)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("appearance.appIcon" as CFString, id as CFString) as? String
        let dark = (CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String)?
            .caseInsensitiveCompare("Dark") == .orderedSame

        // The same files AppIconStyle.image(dark:) reads. The original is
        // the bundle's own icon, light, dark, tinted or clear as macOS
        // picks, which the Dock shows with no view at all.
        // The best friend charm is drawn from its halves, as the app draws
        // it (CharmDraw, compiled into this plug-in too).
        if style == "charm", let resources = app.resourceURL {
            let left = CFPreferencesCopyAppValue("invite.charm.left" as CFString, id as CFString) as? String ?? "mint"
            let right = CFPreferencesCopyAppValue("invite.charm.right" as CFString, id as CFString) as? String
            let apart = CFPreferencesCopyAppValue("invite.charm.apart" as CFString, id as CFString) as? Bool ?? false
            if let image = CharmDraw.image(resources: resources, left: left, right: right, apart: apart) {
                let view = NSImageView(image: image)
                view.imageScaling = .scaleProportionallyUpOrDown
                tile.contentView = view
                tile.display()
                return
            }
        }
        let name = style.flatMap { $0 == "original" ? nil : $0 + (dark ? "-dark" : "") }
        if let name, let resources = app.resourceURL,
           let image = NSImage(contentsOf: resources.appendingPathComponent("AppIcons/\(name).icns")) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}
