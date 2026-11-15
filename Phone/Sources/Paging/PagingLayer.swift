import SwiftUI
import UIKit
import WebKit

/// The neighbors beside the page while a swipe on the plate pages through
/// tabs: the tab before on the left, the one after (or New Tab's blank page)
/// on the right, 416 apart, following the finger with the page in front.
/// Each shows its live page when it has one, else its last picture.
struct PagingLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            let swipe = app.surfaces.pageSwipe
            let pager = Pager.of(app)
            ZStack(alignment: .topLeading) {
                if let swipe {
                    let at = pager.beside(swipe.offset)
                    let corners = RoundedRectangle(cornerRadius: Metrics.Page.cardCorner, style: .continuous)
                    if let before = swipe.before {
                        NeighborPage(tab: before, pool: app.pages)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipShape(corners)
                            .offset(x: at.before)
                    }
                    if swipe.newTab {
                        NewTabSlide(size: geo.size)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipShape(corners)
                            .offset(x: at.after)
                            .onTapGesture { pager.tapBlank() }
                            .accessibilityElement()
                            .accessibilityIdentifier("paging.blank")
                            .accessibilityLabel("New Tab")
                    } else if let after = swipe.after {
                        NeighborPage(tab: after, pool: app.pages)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipShape(corners)
                            .offset(x: at.after)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onAppear {
                pager.screen = geo.size
                app.surfaces.paging = pager
            }
            .onChange(of: geo.size) { pager.screen = geo.size }
        }
        .ignoresSafeArea()
        .allowsHitTesting(app.surfaces.pageSwipe?.blank == true)
    }
}

extension PagingLayer {
    /// Past the last tab New Tab's own spaces slide in (not a blank page), and
    /// letting go opens them in place. A private space keeps its dark page.
    @MainActor static func slidesSpaces(_ app: AppModel) -> Bool {
        !app.browser.space.isPrivate && app.browser.spaces.contains { !$0.isPrivate }
    }
}

/// New Tab coming in past the last tab: the spaces as the field will stand
/// them, keyboard down, so letting go changes nothing on the screen.
private struct NewTabSlide: View {
    @Environment(AppModel.self) private var app
    let size: CGSize

    var body: some View {
        if PagingLayer.slidesSpaces(app) {
            let g = FieldGeometry(size: size, keyboard: 0, mode: .newTab, resting: true)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Metrics.Field.backdrop)
                SpacePagesCard(rows: [], content: NewTabContent.make(for: app), width: size.width,
                               maxHeight: g.spacesBottom, fieldExtraHeight: g.spacesFieldExtra,
                               bottom: g.spacesBottom, fullness: 1)
                    .frame(width: size.width)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
        } else {
            AppearanceColors.color(light: Metrics.Page.blank, dark: 0x121214)
        }
    }
}

/// The New Tab field's own words on a pill coming in past the last tab:
/// the magnifier and the placeholder where the field will have them.
struct NewTabFieldLabel: View {
    var body: some View {
        HStack(spacing: Metrics.Field.newTabGap) {
            Glyph(.magnifyingGlass, size: Metrics.Field.magnifier, color: Ink.fieldGlyph)
            Text("Search, ask or give a task")
                .font(.system(size: Metrics.Field.font))
                .foregroundStyle(Ink.rowSubtitle)
        }
        .lineLimit(1)
        .padding(.leading, Metrics.Field.leading)
    }
}

/// A neighbor tab's page: its web view when it is alive, else its picture.
private struct NeighborPage: UIViewRepresentable {
    let tab: Tab
    let pool: WebPool

    func makeUIView(context: Context) -> NeighborSlot { NeighborSlot() }

    func updateUIView(_ slot: NeighborSlot, context: Context) { slot.show(tab, pool: pool) }

    static func dismantleUIView(_ slot: NeighborSlot, coordinator: ()) { slot.letGo() }
}

final class NeighborSlot: UIView {
    private weak var web: WKWebView?
    private let picture = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppearanceColors.ui(0xFFFFFF, 0x121214)
        isUserInteractionEnabled = false
        clipsToBounds = true
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        addSubview(picture)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ tab: Tab, pool: WebPool) {
        // A late update from the departing swipe must not take the selected
        // WebView back from PageHost, then remove it during dismantling.
        guard pool.front != tab.id else { letGo(); return }
        if pool.isLive(tab.id) {
            let view = pool.view(for: tab)
            if view.superview !== self { addSubview(view) }
            web = view
            picture.isHidden = true
        } else {
            letGo()
            picture.image = pool.snapshots[tab.id]
            picture.isHidden = picture.image == nil
        }
        setNeedsLayout()
    }

    /// The web view goes back to the pool, unless the page in front took it already.
    func letGo() {
        if let web, web.superview === self { web.removeFromSuperview() }
        web = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = bounds
        if let web, web.superview === self { web.frame = bounds }
    }
}

/// The plate's label while it pages: the tab's own between its neighbors',
/// each moving by the finger's travel times the plate's share of a page.
struct PagingLabels: View {
    @Environment(AppModel.self) private var app
    let swipe: PageSwipe
    let tab: Tab?
    var onDark = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = swipe.offset * width / Pager.of(app).slot
            ZStack {
                if let before = swipe.before {
                    label(PlateLabel(tab: before, folded: false, onDark: onDark), width, geo.size.height, x - width)
                }
                label(PlateLabel(tab: tab, folded: false, onDark: onDark), width, geo.size.height, x)
                if swipe.newTab {
                    label(NewTabLabel(onDark: onDark), width, geo.size.height, x + width)
                } else if let after = swipe.after {
                    label(PlateLabel(tab: after, folded: false, onDark: onDark), width, geo.size.height, x + width)
                }
            }
            .frame(width: width, height: geo.size.height)
        }
        .clipped()
    }

    private func label<V: View>(_ view: V, _ width: CGFloat, _ height: CGFloat, _ x: CGFloat) -> some View {
        view.frame(width: width, height: height).offset(x: x)
    }
}

/// "+ New Tab" on the plate as the blank page past the last tab comes in.
struct NewTabLabel: View {
    var onDark = false

    var body: some View {
        let font = Metrics.Chrome.labelFont
        HStack(spacing: Metrics.Chrome.labelGap) {
            Glyph(.plusMedium, size: Metrics.Chrome.labelIcon, color: onDark ? Ink.onDark : Ink.primary)
            Text("New Tab")
                .font(.system(size: font, weight: .semibold))
                .tracking(-0.02 * font)
                .foregroundStyle(onDark ? Ink.onDark : Ink.primary)
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.Chrome.labelPadding)
    }
}
