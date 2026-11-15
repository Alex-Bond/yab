import SwiftUI
import UIKit

/// The page plate: menu, address and Reload or Stop on native glass. A tap opens the
/// field about this page and unfolds the chrome, a swipe up brings the
/// spaces, a hold its menu; a swipe across pages through the tabs when the
/// tabs branch hands it a pager (Surfaces.paging).
struct PlateView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let tab: Tab?
    let tint: RGB
    let folded: Bool
    /// The plate's frame on screen: what the field grows out of.
    let origin: CGRect
    /// Covered source controls retain their view while action authority
    /// belongs only to the current committed surface.
    var isAccessible = true
    var glassNamespace: Namespace.ID? = nil
    var showsGlass = true

    @State private var axis: Axis?
    /// When ≡ was last held: Reader went on, the lift isn't a tap.
    @State private var linesHeldAt: Date?

    var body: some View {
        let isPrivate = app.browser.space.isPrivate || tab?.isPrivate == true
        let state = app.currentPageState
        let actionsEnabled = isAccessible && !app.surfaces.pageSwiping && tab != nil
        ZStack {
            // The center retains the full plate's origin for its field morph.
            // Its two overlaid buttons own their touches independently.
            // The words' size and room follow the plate's own fold frame by
            // frame: switched at once, a host was cut to its end in the
            // narrow capsule and grew back as the plate widened.
            PlateFolding(fold: folded ? 1 : 0) { fold in
                ToolbarPlateControl(owner: ChromePlusOwner(app: app), readerAvailable: state.readerAvailable,
                                    readerEnabled: state.readerEnabled, translation: app.translation.plateWords(tab?.id),
                                    pagingActive: app.surfaces.pageSwiping,
                                    tab: tab, folded: folded, fold: fold, sourceAccessible: isAccessible, origin: origin)
            }
                .frame(maxWidth: .infinity, minHeight: Metrics.touch, maxHeight: .infinity)
                .overlay {
                    // Paging: this plate keeps its own words and rides
                    // with the page (SharedBottomToolbar); its neighbors
                    // are plates of their own.
                    if app.surfaces.pageSwiping {
                        PlateLabel(tab: tab, folded: folded, onDark: isPrivate)
                            .padding(.horizontal, folded ? 0 : Metrics.touch)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }

            HStack(spacing: 0) {
                // Safari's left-aligned lines, 15 from the plate's edge.
                // While a swipe pages, the plate is its words alone.
                // A tap: the page menu out of the plate; a hold: Reader.
                Button {
                    if let held = linesHeldAt, Date().timeIntervalSince(held) < 2 { linesHeldAt = nil; return }
                    app.openPageMenu()
                } label: {
                    Glyph(.plateLines, size: Metrics.PageMenu.glyph, color: isPrivate ? Ink.onDark : Ink.primary)
                        .frame(width: Metrics.touch, height: Metrics.Chrome.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.46, maximumDistance: 7).onEnded { _ in
                    linesHeldAt = Date()
                    app.holdPageLines()
                })
                .padding(.leading, Metrics.Chrome.pageGlyphInset)
                .accessibilityAction(named: "Reader") { app.holdPageLines() }
                .accessibilityIdentifier(isAccessible && !folded ? "chrome.pageMenu" : "")
                .accessibilityLabel("Page Menu")
                .accessibilityValue([state.readerEnabled ? "Reader on" : state.readerAvailable ? "Reader available" : nil,
                                     app.translation.plateWords(tab?.id)].compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint(state.readerAvailable ? "Reader is available for this page" : "Shows actions for this page")
                .disabled(!actionsEnabled)
                Spacer(minLength: 0)
                Button { app.reloadOrStopPage() } label: {
                    ReloadMark(stop: state.isLoading, size: Metrics.PageMenu.glyph, stopSize: Metrics.Chrome.stopGlyph,
                               color: isPrivate ? Ink.onDark : Ink.primary)
                        .frame(width: Metrics.touch, height: Metrics.Chrome.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuarterTurnPress(stop: state.isLoading))
                .accessibilityIdentifier(isAccessible && !folded ? "chrome.reload" : "")
                .accessibilityLabel(state.isLoading ? "Stop Loading" : "Reload Page")
                .accessibilityValue(state.isLoading ? "loading" : "ready")
                .disabled(!actionsEnabled)
                .padding(.trailing, Metrics.Chrome.pageGlyphInset)
            }
            // The empty page has no lines and no reload, only "+ New Tab".
            .opacity(!app.surfaces.pageSwiping && tab != nil ? 1 : 0)
            .animation(Motion.tabSwipe.animation, value: !app.surfaces.pageSwiping)
            // Folding, they go at once (Safari's are gone in two frames; a
            // fade let ↻ slide over the words as the plate narrowed);
            // unfolding, they come in over the fold's second half, once the
            // plate has room beside the words. The folded plate's own height.
            .frame(height: max(origin.height, Metrics.touch))
            .modifier(PlateGlyphsFade(fold: folded ? 1 : 0, folded: folded))
            .allowsHitTesting(!folded && tab != nil)
            .accessibilityHidden(folded || tab == nil)
        }
        .foregroundStyle(isPrivate ? Ink.onDark : Ink.primary)
        // Attach glass to the actual controls so their foreground remains
        // above the native material. A separate background plane refracts them.
        .frame(height: origin.height)
        // No loading line: ↻ turning to Stop says it.
        .modifier(PageControlsGlass(shape: Capsule(style: .continuous), namespace: glassNamespace, isPrivate: isPrivate, enabled: showsGlass))
        // The folded glass still draws 34 points inside its 44-point target.
        .frame(height: max(origin.height, Metrics.touch))
        .gesture(drag, isEnabled: !folded)
        .highPriorityGesture(foldedDrag, isEnabled: folded)
        .accessibilityHidden(!isAccessible)
        .allowsHitTesting(isAccessible)
        .environment(\.colorScheme, isPrivate ? .dark : colorScheme)
    }

    private func openSpaces() {
        Haptics.play(.light, reason: Haptics.Reason.columnOpened)
        app.field.openSpaces()
    }

    /// A folded movement belongs to the drag, not the address button. Keep
    /// its pose until lift so the button cannot be replaced under the finger.
    private var foldedDrag: some Gesture {
        DragGesture(minimumDistance: 7)
            .onEnded { value in
                guard abs(value.translation.height) >= abs(value.translation.width),
                      value.translation.height < -24 || value.velocity.height < -300 else { return }
                openSpaces()
            }
    }

    /// Up lifts the spaces; across is paging, the pager's to follow. Used
    /// only when PlateGestures isn't on the window.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 7)
            .onChanged { value in
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                    if axis == .horizontal { app.surfaces.paging?.began() }
                    if axis == .vertical, !PlateGestures.installed { app.field.beginLift() }
                }
                if axis == .horizontal { app.surfaces.paging?.moved(value.translation.width) }
                if axis == .vertical, !PlateGestures.installed { app.field.liftMoved(value.translation.height) }
            }
            .onEnded { value in
                defer { axis = nil }
                switch axis {
                case .horizontal:
                    app.surfaces.paging?.ended(value.translation.width, velocity: value.velocity.width)
                case .vertical:
                    if !PlateGestures.installed { app.field.liftEnded(value.translation.height, velocity: value.velocity.height) }
                case nil:
                    break
                }
            }
    }
}

/// The plate's fold as it moves, 0 open and 1 folded, handed to the native
/// address so its words follow the plate's own animation frame by frame.
private struct PlateFolding<Content: View>: View, Animatable {
    var fold: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { fold }
        set { fold = newValue }
    }

    var body: some View { content(fold) }
}

/// ≡ and ↻ unfolding: nothing until the words' room has stepped 30 of its
/// 44 points in from each edge (68 % of the way), then in by the end, so
/// neither lands on a long host still as wide as the plate (filmed
/// 2026-11-06: from 45 % ≡ sat on "news"). Folding: gone at once.
private struct PlateGlyphsFade: ViewModifier, Animatable {
    var fold: CGFloat
    let folded: Bool

    var animatableData: CGFloat {
        get { fold }
        set { fold = newValue }
    }

    func body(content: Content) -> some View {
        let share = min(1, max(0, (1 - fold - 0.68) / 0.32))
        content.opacity(folded ? 0 : share * share * (3 - 2 * share))
    }
}

/// One native material attaches to each complete source/destination control.
/// The namespace morphs glass geometry while preserving readable foreground.
struct PageControlsGlass<S: Shape>: ViewModifier {
    let shape: S
    let namespace: Namespace.ID?
    var isPrivate = false
    var enabled = true

    // Private controls use the existing dark tint of the native material;
    // white foreground cannot rely on an untinted pane over a light website.
    private var material: Glass { isPrivate ? GlassTone.privateTab.glass(for: .dark) : .regular }

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if let namespace {
            content
                .glassEffect(material.interactive(), in: shape)
                .glassEffectID("page-controls", in: namespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            content
                .glassEffect(material.interactive(), in: shape)
                .glassEffectTransition(.identity)
        }
    }
}

/// The address shown on the plate and its paging neighbors. Its native
/// callout scales with Dynamic Type while the fold interpolates the size.
struct PlateLabel: View, Animatable {
    let tab: Tab?
    /// 0 open, 1 folded, in between while it folds.
    var fold: CGFloat
    var onDark = false

    init(tab: Tab?, folded: Bool, onDark: Bool = false) {
        self.tab = tab
        self.fold = folded ? 1 : 0
        self.onDark = onDark
    }

    var animatableData: CGFloat {
        get { fold }
        set { fold = newValue }
    }

    private func size(_ open: CGFloat, _ folded: CGFloat) -> CGFloat { open + (folded - open) * fold }

    var body: some View {
        PlateWords(words: tab.map(Self.address) ?? "New Tab",
                   pointSize: size(Metrics.Chrome.labelFont, Metrics.Chrome.minLabelFont),
                   weight: Metrics.Chrome.labelWeight, ink: onDark ? Ink.onDark : Ink.primary)
            .lineLimit(1)
    }

    /// Display only the host and explicit port. The canonical URL remains
    /// untouched for loading, history, sync, Copy Link and the address field.
    static func address(_ tab: Tab) -> String {
        let url = tab.navigationURL
        var host = url?.host() ?? tab.addressHost
        if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
        if let port = url?.port { return "\(host):\(port)" }
        if let port = tab.port { return "\(host):\(port.trimmingCharacters(in: CharacterSet(charactersIn: ":")))" }
        return host
    }

}

/// Native words keep the callout's Dynamic Type metadata while the fold
/// interpolates its point size. The containing plate owns their spoken label.
struct PlateWords: UIViewRepresentable {
    let words: String
    let pointSize: CGFloat
    let weight: UIFont.Weight
    let ink: Color

    func makeUIView(context: Context) -> HeadFadeLabel {
        let view = HeadFadeLabel()
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.isUserInteractionEnabled = false
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: HeadFadeLabel, context: Context) {
        let font = Self.font(pointSize: pointSize, weight: weight, dynamicType: context.environment.dynamicTypeSize)
        let color = UIColor(ink)
        view.label.font = font
        view.label.textColor = color
        view.label.attributedText = NSAttributedString(string: words, attributes: [
            .font: font, .foregroundColor: color, .kern: -0.02 * font.pointSize,
        ])
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HeadFadeLabel, context: Context) -> CGSize? {
        let width = max(0, proposal.width ?? .greatestFiniteMagnitude)
        let size = uiView.label.intrinsicContentSize
        return CGSize(width: min(width, ceil(size.width)), height: ceil(max(size.height, uiView.label.font.lineHeight)))
    }

    static func font(pointSize: CGFloat, weight: UIFont.Weight, dynamicType: DynamicTypeSize) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: .callout,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return UIFontMetrics(forTextStyle: .callout).scaledFont(
            for: UIFont(descriptor: descriptor, size: pointSize),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: min(category(dynamicType), Metrics.Chrome.labelLargestText)))
    }

    private static func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

/// What the tabs branch gives the plate to page through tabs with a swipe
/// across it: the finger's travel as it moves, and where it let go.
@MainActor
protocol PlatePaging: AnyObject {
    func began()
    func moved(_ dx: CGFloat)
    func ended(_ dx: CGFloat, velocity: CGFloat)
    /// A page turn without a finger (VoiceOver): 1 the next tab, -1 the one before.
    func step(_ direction: Int)
}

extension PlatePaging {
    func step(_ direction: Int) {}
}

/// One line of words that never shows "…": wider than its room, it keeps
/// its end (a host's domain) and fades out at its start.
final class HeadFadeLabel: UIView {
    let label = UILabel()
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        label.accessibilityElementsHidden = true
        label.isUserInteractionEnabled = false
        clipsToBounds = true
        addSubview(label)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize { label.intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        let natural = ceil(label.intrinsicContentSize.width)
        let over = natural > bounds.width + 0.5
        // The fade grows with what is cut, two points per point, up to its
        // 26: a host just losing its first letter as the plate unfolds
        // fades it out over the frames, not all 26 points at once.
        let fadeWidth = min(Metrics.Chrome.labelFade, 2 * (natural - bounds.width))
        label.frame = CGRect(x: over ? bounds.width - natural : (bounds.width - natural) / 2, y: 0,
                             width: natural, height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if over {
            fade.frame = bounds
            fade.locations = [0, NSNumber(value: Double(min(1, fadeWidth / max(1, bounds.width))))]
            layer.mask = fade
        } else {
            layer.mask = nil
        }
        CATransaction.commit()
    }
}

/// The SwiftUI mask for the same fade: clear at the start, whole after
/// `labelFade`.
struct HeadFade: View {
    let on: Bool
    let width: CGFloat

    var body: some View {
        if on {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: min(1, Metrics.Chrome.labelFade / max(1, width)))],
                           startPoint: .leading, endPoint: .trailing)
        } else {
            Color.black
        }
    }
}
