import SwiftUI
import UIKit

/// A real UIButton replaces the plain SwiftUI button; no second AX control.
struct ColumnClearControl: UIViewRepresentable {
    let ink: Color
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ColumnClearButton {
        let button = ColumnClearButton(type: .custom)
        button.titleLabel?.font = .systemFont(ofSize: Metrics.Column.clearFont, weight: .medium)
        button.setTitle("Clear", for: .normal)
        button.backgroundColor = .clear
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "column.clear"
        button.accessibilityLabel = "Clear"
        button.accessibilityTraits = .button
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: ColumnClearButton, context: Context) {
        context.coordinator.action = action
        button.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        button.setTitleColor(UIColor(ink), for: .normal)
        button.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ColumnClearButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pressed() { action() }
    }
}

final class ColumnClearButton: UIButton {
    override var intrinsicContentSize: CGSize {
        let words = titleLabel?.intrinsicContentSize ?? .zero
        return CGSize(width: ceil(words.width) + Metrics.Column.clearOutset.width * 2,
                      height: Metrics.Column.lineHeight + Metrics.Column.clearOutset.height * 2)
    }
}
