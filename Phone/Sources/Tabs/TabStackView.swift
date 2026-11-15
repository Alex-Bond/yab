import SwiftUI
import UIKit

/// The two cards in the right button's glass circle, a stack made small: the tab used before this one in front, a little up and to the
/// right, turned 8° clockwise, and the one before that behind it, down and
/// to the left, turned 12° the other way, a shade darker. Each has a
/// faint rim inside its edge, its own light shadow and no icon on it: the
/// top of its page (from under the status bar, as wide as the card), from
/// its last picture (TabStack.picture, kept across launches); a tab never pictured shows its icon until it is.
final class TabStackView: UIView {
    private let backCard = TabCardView(veil: Metrics.TabStack.backVeil)
    private let frontCard = TabCardView()
    /// How far a finger has lifted the front card, in points (the flick).
    var lift: CGFloat = 0 {
        didSet { if lift != oldValue { setNeedsLayout() } }
    }
    /// The tab just left taking the front place while the flicked page grows:
    /// 0 small and clear, 1 in place.
    var arrival: CGFloat = 1 {
        didSet { if arrival != oldValue { setNeedsLayout() } }
    }
    private struct Shown: Equatable {
        let front: Tab?
        let back: Tab?
        let pictures: Int
        let frontMark: ObjectIdentifier?
        let backMark: ObjectIdentifier?
    }
    private var shown: Shown?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        addSubview(backCard)
        addSubview(frontCard)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// What the cards show. Unchanged contents keep the drawn cards, so the
    /// chrome's frequent updates never draw them again.
    func show(front: Tab?, back: Tab?, pictures: Int, artwork: SyncFolderArtwork? = nil, picture: (Tab) -> UIImage?) {
        func mark(_ tab: Tab?) -> ObjectIdentifier? {
            guard let tab else { return nil }
            let image = tab.customMark.flatMap { artwork?.image($0, isPrivate: tab.isPrivate) }
                ?? artwork?.siteImage(for: tab.navigationURL, isPrivate: tab.isPrivate)
                ?? FaviconImages.image(tab.icon, host: tab.host, url: tab.navigationURL, isPrivate: tab.isPrivate)
            return image.map(ObjectIdentifier.init)
        }
        let next = Shown(front: front, back: back, pictures: pictures, frontMark: mark(front), backMark: mark(back))
        guard next != shown else { return }
        shown = next
        frontCard.show(front, picture: front.flatMap(picture), artwork: artwork)
        backCard.show(back, picture: back.flatMap(picture), artwork: artwork)
        frontCard.isHidden = front == nil
        backCard.isHidden = back == nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        typealias M = Metrics.TabStack
        let size = CGSize(width: M.cardWidth, height: M.cardHeight)
        // Around the circle's middle; a larger hit target keeps them centered.
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        for (card, at) in [(backCard, M.back), (frontCard, M.front)] {
            card.transform = .identity
            card.bounds = CGRect(origin: .zero, size: size)
            card.center = CGPoint(x: middle.x + at.x, y: middle.y + at.y)
        }
        backCard.transform = CGAffineTransform(rotationAngle: M.backTurn * .pi / 180)
        backCard.alpha = M.backOpacity
        let grown = 1 + M.liftGrowth * min(1, max(0, lift) / M.liftSpan)
        let a = min(max(arrival, 0), 1)
        // The arriving card comes from 60 % with the prototype's ease-out.
        let arriving = 0.6 + 0.4 * (1 - pow(1 - a, 3))
        frontCard.transform = CGAffineTransform(translationX: 0, y: -lift)
            .scaledBy(x: grown * arriving, y: grown * arriving)
            .rotated(by: M.frontTurn * .pi / 180)
        frontCard.alpha = a
    }
}

/// One card: the page's top inside its corners with the rim's hairline
/// along its edge, on a mat of its size that casts the card's shadow.
private final class TabCardView: UIView {
    private let mat = UIView()
    private let face = UIView()
    private let picture = UIView()
    private let icon = UIImageView()
    private let shade = UIView()
    private var shownTab: Tab.ID?

    init(veil: CGFloat = 0) {
        super.init(frame: .zero)
        typealias M = Metrics.TabStack
        isUserInteractionEnabled = false
        mat.layer.cornerRadius = M.cardRadius
        mat.layer.cornerCurve = .continuous
        mat.layer.shadowColor = UIColor.black.cgColor
        mat.layer.shadowOpacity = M.shadowAlpha
        mat.layer.shadowRadius = M.shadowRadius
        mat.layer.shadowOffset = CGSize(width: 0, height: M.shadowY)
        face.clipsToBounds = true
        face.layer.cornerRadius = M.cardRadius
        face.layer.cornerCurve = .continuous
        // A layer's border lies inside its edge, over what it holds.
        face.layer.borderWidth = M.rim
        face.layer.borderColor = UIColor.white.withAlphaComponent(M.rimAlpha).cgColor
        picture.layer.contentsGravity = .resize
        icon.contentMode = .scaleAspectFit
        shade.backgroundColor = UIColor.black.withAlphaComponent(veil)
        shade.isHidden = veil <= 0
        addSubview(mat)
        addSubview(face)
        face.addSubview(picture)
        face.addSubview(icon)
        face.addSubview(shade)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ tab: Tab?, picture image: UIImage?, artwork: SyncFolderArtwork? = nil) {
        guard let tab else { return }
        // The page's picture arriving over its icon (read from the disk,
        // warmed up) cross-fades in.
        if image != nil, picture.isHidden, shownTab == tab.id, !Motion.disabled {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.reduced ? Motion.fadeDuration : Motion.tabPictureIn.duration
            face.layer.add(fade, forKey: "picture")
        }
        shownTab = tab.id
        face.backgroundColor = tab.dark || tab.isPrivate ? UIColor(white: 0.11, alpha: 1) : .white
        picture.layer.contents = image?.cgImage
        picture.isHidden = image == nil
        // The top of the page under the status bar: as wide as the card, as
        // much of its height as fits. Every picture is the page in points
        // from the screen's top (the pool's whole page, or a kept one down to
        // the chrome's row), so the status bar is the same share of either.
        if let image, image.size.width > 0, image.size.height > 0 {
            let top = min(0.5, Metrics.statusBar / image.size.height)
            let fits = (Metrics.TabStack.cardHeight / Metrics.TabStack.cardWidth) / (image.size.height / image.size.width)
            picture.layer.contentsRect = CGRect(x: 0, y: top, width: 1, height: min(1 - top, fits))
        }
        // A page not pictured yet: its icon in the middle.
        icon.isHidden = image != nil
        if image == nil { icon.image = TabIcons.image(for: tab, size: Metrics.TabStack.fallbackIcon, artwork: artwork) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        typealias M = Metrics.TabStack
        mat.frame = bounds
        mat.layer.shadowPath = UIBezierPath(roundedRect: mat.bounds, cornerRadius: M.cardRadius).cgPath
        face.frame = bounds
        picture.frame = face.bounds
        shade.frame = face.bounds
        let side = M.fallbackIcon
        icon.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }
}

/// A tab's site icon as a picture for UIKit (the stack's cards, the menu's
/// rows): the same Favicon the spaces draw, rendered once per change.
/// An ImageRenderer builds a whole SwiftUI graph, and the + menu is made
/// again on SwiftUI updates: crash #49 (0.0.15) was the watchdog killing
/// Yab on its way out with the main thread inside this render. A picture
/// is kept until the site's icon behind it changes.
@MainActor
enum TabIcons {
    private struct Rendered { let source: UIImage?; let image: UIImage? }
    private static var rendered: [String: Rendered] = [:]
    /// ImageRenderer runs so far, for tests.
    private(set) static var renders = 0

    static func image(for tab: Tab, size: CGFloat, artwork: SyncFolderArtwork? = nil) -> UIImage? {
        let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
        // What Favicon draws from: the site's picture (by identity, as it
        // arrives later from SiteIcons) or, without one, the tile its key names.
        let source = tab.customMark.flatMap { artwork?.image($0, isPrivate: tab.isPrivate) }
            ?? artwork?.siteImage(for: tab.navigationURL, isPrivate: tab.isPrivate)
            ?? (tab.icon == "mail" || tab.icon == "face" ? nil
                : FaviconImages.image(tab.icon, host: tab.host, url: tab.navigationURL, isPrivate: tab.isPrivate))
        let key = "\(tab.icon)|\(tab.host ?? "")|\(tab.customMark ?? "")|\(tab.isPrivate)|\(size)|\(scale)"
        if let hit = rendered[key], hit.source === source { return hit.image }
        let renderer = ImageRenderer(content: Favicon(icon: tab.icon, host: tab.host, size: size,
                                                      url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark, artwork: artwork))
        renderer.scale = scale
        renders += 1
        let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal)
        if rendered.count >= 256 { rendered.removeAll() }
        rendered[key] = Rendered(source: source, image: image)
        return image
    }

    /// The tab's icon in a native menu, as large as the menu's glyphs.
    @MainActor
    static func menuImage(for tab: Tab, artwork: SyncFolderArtwork? = nil) -> UIImage? {
        let side = UIImage.menuGlyphSide
        guard let icon = image(for: tab, size: side * 20 / 24, artwork: artwork) else { return nil }
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        let inset = (side - icon.size.width) / 2
        let picture = UIGraphicsImageRenderer(size: box.size).image { _ in icon.draw(in: box.insetBy(dx: inset, dy: inset)) }
        return picture.withBaselineOffset(fromBottom: side / 2 - UIFont.preferredFont(forTextStyle: .body).capHeight / 2)
            .withRenderingMode(.alwaysOriginal)
    }
}

/// A tab's page as a card shows it: its last picture, as wide as the card,
/// from `cropTop` (the share of the screen's height above what shows) down;
/// a tab never pictured shows its page's color and its icon, and its picture
/// cross-fades in when it comes. A picture is the page from the screen's
/// top, as wide as it (the pool's whole page, or a kept one down to the
/// chrome's row), so `screen` says how tall a share is.
struct TabPicture: View {
    let tab: Tab
    let image: UIImage?
    var cropTop: CGFloat = 0
    var iconSize: CGFloat = 32
    var screen: CGSize = Metrics.screen

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Rectangle().fill(tab.dark || tab.isPrivate ? Color(white: 0.11) : Color.white)
                if let image, image.size.width > 0 {
                    let height = geo.size.width * image.size.height / image.size.width
                    let page = screen.width > 0 ? geo.size.width * screen.height / screen.width : height
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: geo.size.width, height: height)
                        .offset(y: -cropTop * page)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .transition(.opacity)
                } else {
                    Favicon(icon: tab.icon, host: tab.host, size: iconSize, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                }
            }
            .animation(Motion.tabPictureIn.current, value: image != nil)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}
