import SwiftUI
import UIKit

/// Settings queries are literal. Disable native prediction as well as
/// autocorrection so an empty prediction strip is not left above the keys.
struct SettingsSearchField: UIViewRepresentable {
    @Binding var text: String
    /// History's search is the same field with its own words.
    var placeholder = "Search"
    var identifier = "settings.search"

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> LiteralSettingsTextField {
        let field = LiteralSettingsTextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.accessibilityIdentifier = identifier
        field.accessibilityLabel = placeholder
        field.placeholder = placeholder
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.inlinePredictionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .search
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    func updateUIView(_ field: LiteralSettingsTextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text { field.text = text }
        field.textColor = UIColor(SettingsInk.text)
        // The system's placeholder gray is too faint over the glass in dark:
        // the rows' value ink reads at 4.5:1 and more.
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(SettingsInk.value)])
        field.keyboardAppearance = context.environment.colorScheme == .dark ? .dark : .light
        field.updateBodyFont()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LiteralSettingsTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(Metrics.touch, uiView.intrinsicContentSize.height))
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

/// The actual native field follows the current preferred body font without
/// a font cap, preserving the search viewport's natural Dynamic Type height.
final class LiteralSettingsTextField: UITextField {
    override init(frame: CGRect) {
        super.init(frame: frame)
        adjustsFontForContentSizeCategory = true
        updateBodyFont()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (field: LiteralSettingsTextField, _: UITraitCollection) in field.updateBodyFont()
        }
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }
    func updateBodyFont() {
        let preferred = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        if font != preferred { font = preferred; invalidateIntrinsicContentSize() }
    }
}
