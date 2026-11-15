import AppKit
import SyncKit

extension Bench {
    /// The app's own accessibility tree and actual switch action. Kept inside
    /// a disposable test process, without OS event injection or TCC grants.
    func syncCategoryControls(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing, let window = SettingsWindow.shared.window, let root = window.contentView else {
            answer(["error": "category controls need test Settings"]); return
        }
        if let size = request["size"] as? [Double], size.count == 2 {
            var frame = window.frame
            let available = window.screen?.visibleFrame ?? frame
            frame.size = NSSize(width: size[0], height: min(size[1], available.height - 24))
            frame.origin.y = max(available.minY, min(window.frame.maxY - frame.height, available.maxY - frame.height))
            window.setFrame(frame, display: true)
        }
        let kinds = SyncWhatPage.kinds
        var controls: [String: any NSAccessibilityProtocol] = [:]
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: Any) {
            guard let node = object as? any NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
            let label = node.accessibilityLabel() ?? node.accessibilityTitle() ?? ""
            if let kind = kinds.first(where: { "Sync " + $0.title == label }) {
                controls[kind.category.rawValue] = node
            }
            for child in node.accessibilityChildren() ?? [] { walk(child) }
        }
        walk(root)
        if let category = request["press"] as? String {
            guard let control = controls[category] else {
                answer(["error": "no category switch " + category, "controls": controls.keys.sorted()]); return
            }
            answer(["pressed": control.accessibilityPerformPress()])
        } else {
            answer(["controls": controls.keys.sorted()])
        }
    }
}
