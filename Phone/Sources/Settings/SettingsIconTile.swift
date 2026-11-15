import SwiftUI
import UIKit

/// The current Mac's paper, marker and pen art, painted at the actual native
/// tile size. Settings' glass controls and its navigation remain separate.
struct SettingsIconTile: UIViewRepresentable {
    let mark: String
    let tint: UIColor?
    let side: CGFloat

    func makeUIView(context: Context) -> SettingsIconView { SettingsIconView() }
    func updateUIView(_ view: SettingsIconView, context: Context) {
        view.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        view.configure(mark: mark, tint: tint, side: side)
    }
}

@MainActor
final class SettingsIconView: UIView {
    private var mark = ""
    private var tint: UIColor?
    private var side: CGFloat = Metrics.Settings.indexTile

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SettingsIconView, _) in view.setNeedsDisplay() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(mark: String, tint: UIColor?, side: CGFloat) {
        self.mark = mark; self.tint = tint; self.side = side
        invalidateIntrinsicContentSize(); setNeedsDisplay()
    }
    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        SettingsPenArt.drawTile(mark, tint: tint?.resolvedColor(with: traitCollection), in: bounds,
                                dark: traitCollection.userInterfaceStyle == .dark, context: context)
    }
}
