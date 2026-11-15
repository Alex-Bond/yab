import SwiftUI
import UIKit

/// Appearance's three choices are native controls. The drawn title, its
/// ground and selected state belong to the same UIButton accessibility owns.
struct AppearanceChoiceButton: UIViewRepresentable {
    let words: String
    let selected: Bool
    let identifier: String
    let minimumHeight: CGFloat
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> AppearanceChoiceControl {
        let button = AppearanceChoiceControl(frame: .zero)
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: AppearanceChoiceControl, context: Context) {
        context.coordinator.action = action
        button.setTitle(words, for: .normal)
        let ink = UIColor(SettingsInk.text)
        let check = selected ? UIImage(named: GlyphName.checkmark1Small.rawValue)?.withRenderingMode(.alwaysTemplate) : nil
        let states: [UIControl.State] = [.normal, .highlighted, .selected, [.selected, .highlighted]]
        for state in states {
            button.setTitleColor(ink, for: state)
            button.setImage(check, for: state)
        }
        button.tintColor = ink
        button.imageView?.contentMode = .scaleAspectFit
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .callout,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category(context.environment.dynamicTypeSize)))
        button.minimumHeight = max(Metrics.touch, minimumHeight)
        button.ground = UIColor(SettingsInk.group)
        button.pressedGround = UIColor(SettingsInk.pressed)
        button.isSelected = selected
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = words
        button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        button.refreshGround()
        button.invalidateIntrinsicContentSize()
        button.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AppearanceChoiceControl, context: Context) -> CGSize? {
        uiView.fittingSize(width: proposal.width ?? uiView.intrinsicContentSize.width)
    }

    private func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
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

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}

/// Left-aligned words, an optional check at the right, and the same quiet
/// pressed fill as the other Settings rows. The check reserves its width
/// without an invisible image when this choice is not selected.
final class AppearanceChoiceControl: UIButton {
    var minimumHeight: CGFloat = Metrics.touch
    var ground: UIColor = .white
    var pressedGround: UIColor = .clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentHorizontalAlignment = .left
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { refreshGround() }
    }

    func refreshGround() {
        backgroundColor = isHighlighted ? pressedGround : ground
    }

    func fittingSize(width: CGFloat) -> CGSize {
        let wordsWidth = max(1, width - Metrics.Settings.rowPadding * 2 - Metrics.Settings.rowGap - Metrics.Settings.check)
        let size = titleLabel?.sizeThatFits(CGSize(width: wordsWidth, height: .greatestFiniteMagnitude)) ?? .zero
        return CGSize(width: width, height: max(minimumHeight, ceil(size.height)))
    }

    override var intrinsicContentSize: CGSize {
        let words = titleLabel?.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) ?? .zero
        return CGSize(width: words.width + Metrics.Settings.rowPadding * 2 + Metrics.Settings.rowGap + Metrics.Settings.check,
                      height: max(minimumHeight, ceil(words.height)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let wordsWidth = max(1, bounds.width - Metrics.Settings.rowPadding * 2 - Metrics.Settings.rowGap - Metrics.Settings.check)
        let wordsHeight = min(bounds.height, titleLabel?.sizeThatFits(CGSize(width: wordsWidth, height: .greatestFiniteMagnitude)).height ?? 0)
        titleLabel?.frame = CGRect(x: Metrics.Settings.rowPadding, y: (bounds.height - wordsHeight) / 2,
                                  width: wordsWidth, height: wordsHeight)
        imageView?.frame = CGRect(x: bounds.width - Metrics.Settings.rowPadding - Metrics.Settings.check,
                                  y: (bounds.height - Metrics.Settings.check) / 2,
                                  width: Metrics.Settings.check, height: Metrics.Settings.check)
    }
}
