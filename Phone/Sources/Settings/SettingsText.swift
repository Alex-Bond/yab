import SwiftUI
import UIKit

/// The actual words carry native text-style metadata and their drawn bounds.
/// A hero's tile or a row's hit region must not become its text's audit frame.
struct SettingsText: UIViewRepresentable {
    let words: String
    var style: UIFont.TextStyle = .body
    var weight: UIFont.Weight = .regular
    var ink: Color = SettingsInk.text
    var ground: Color = SettingsInk.pageGround
    var alignment: NSTextAlignment = .natural
    var identifier: String? = nil
    var isHeader = false
    @Environment(\.settingsRowPressed) private var pressed

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = true
        label.isUserInteractionEnabled = false
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let traits = UITraitCollection(preferredContentSizeCategory: SettingsNativeType.category(context.environment.dynamicTypeSize))
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        let descriptor = base.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
        label.font = UIFont(descriptor: descriptor, size: base.pointSize)
        label.text = words
        label.textAlignment = alignment
        label.textColor = UIColor(ink)
        label.backgroundColor = pressed ? .clear : UIColor(ground)
        label.accessibilityIdentifier = identifier
        label.accessibilityTraits = isHeader ? [.staticText, .header] : .staticText
        label.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = max(0, proposal.width ?? .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(width, ceil(size.width)), height: ceil(max(size.height, uiView.font.lineHeight)))
    }
}

enum SettingsNativeType {
    static func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
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
