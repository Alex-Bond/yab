import SwiftUI
import UIKit

/// The search clear action is the same real 44-point button that is drawn
/// and hit-tested, including while the native keyboard is visible.
struct SettingsSearchClear: UIViewRepresentable {
    var identifier = "settings.search.clear"
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        let image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.Settings.rowIcon, weight: .medium))
        button.setImage(image, for: .normal)
        button.isAccessibilityElement = true
        button.accessibilityLabel = "Clear search"
        button.accessibilityIdentifier = identifier
        button.accessibilityTraits = .button
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        button.tintColor = UIColor(SettingsInk.text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: Metrics.touch, height: Metrics.touch)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}
