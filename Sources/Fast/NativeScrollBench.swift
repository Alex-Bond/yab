import AppKit
import WebKit
import SwiftUI

/// Reads and scrolls the real native controls in an isolated test profile.
/// Web pages and extension pages keep their own scroll bars.
@MainActor
enum NativeScrollBench {
    private static var fixture: NSWindow?

    static func run(_ request: [String: Any]) -> [String: Any] {
        guard Store.testing else { return ["error": "test profile only"] }
        if request["close"] as? Bool == true { fixture?.close(); fixture = nil }
        if let kind = request["fixture"] as? String {
            fixture?.close()
            let host = NSHostingView(rootView: Fixture(kind: kind))
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 600, height: 440),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Scroll bars: " + kind
            window.appearance = NSAppearance(named: request["dark"] as? Bool == true ? .darkAqua : .aqua)
            window.contentView = WindowHosting.measured(host)
            if let screen = Links.window?.screen { window.setFrameOrigin(screen.visibleFrame.origin) }
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            fixture = window
        }
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            .sorted { $0.windowNumber < $1.windowNumber }
        var found: [(NSWindow, NSScrollView)] = []
        var finders: [[String: Any]] = []
        func walk(_ view: NSView, window: NSWindow) {
            guard !view.isHidden, !(view is WKWebView) else { return }
            if view is ColumnThread.Finder {
                let r = view.convert(view.bounds, to: nil)
                finders.append(["window": window.windowNumber, "frame": [r.minX, r.minY, r.width, r.height]])
            }
            if let scroll = view as? NSScrollView { found.append((window, scroll)) }
            view.subviews.forEach { walk($0, window: window) }
        }
        for window in windows { walk(window.contentView!, window: window) }
        if let index = request["index"] as? Int, found.indices.contains(index) {
            let scroll = found[index].1
            var point = scroll.contentView.bounds.origin
            let by = request["by"] as? Double ?? 120
            if request["axis"] as? String == "horizontal" { point.x += by } else { point.y += by }
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func bar(_ bar: NSScroller?) -> [String: Any] {
            guard let bar else { return [:] }
            let shown = Mirror(reflecting: bar).children.first { $0.label == "shown" }?.value as? CGFloat
            let frame = bar.convert(bar.bounds, to: nil)
            return ["class": String(describing: type(of: bar)), "enabled": bar.isEnabled,
                    "alpha": bar.alphaValue, "shown": shown.map(Double.init) ?? -1,
                    "parent": bar.superview.map { String(describing: type(of: $0)) } ?? "",
                    "windowFrame": [frame.minX, frame.minY, frame.width, frame.height],
                    "hidden": bar.isHidden, "proportion": bar.knobProportion,
                    "frame": [bar.frame.minX, bar.frame.minY, bar.frame.width, bar.frame.height]]
        }
        return ["finders": finders, "fixtureWindow": fixture?.windowNumber ?? 0, "scrolls": found.enumerated().map { index, pair -> [String: Any] in
            let (window, scroll) = pair
            let frame = scroll.convert(scroll.bounds, to: nil)
            return ["index": index, "window": window.windowNumber, "title": window.title,
                    "document": scroll.documentView.map { String(describing: type(of: $0)) } ?? "",
                    "style": scroll.scrollerStyle == .overlay ? "overlay" : "legacy",
                    "frame": [frame.minX, frame.minY, frame.width, frame.height],
                    "offset": [scroll.contentView.bounds.minX, scroll.contentView.bounds.minY],
                    "vertical": scroll.hasVerticalScroller ? bar(scroll.verticalScroller) : [:],
                    "horizontal": scroll.hasHorizontalScroller ? bar(scroll.horizontalScroller) : [:]]
        }]
    }

    private struct Fixture: View {
        let kind: String
        @State private var text = (0..<120).map { "Line \($0): editable text that stays available while scrolling." }.joined(separator: "\n")

        @ViewBuilder var body: some View {
            switch kind {
            case "editor": ThreadTextEditor(text: $text).font(.system(size: 14)).padding(16) // design: test fixture keeps the same typography in before/after captures.
            case "nested-editor":
                ThreadForm {
                    Section("Notes") { ThreadTextEditor(text: $text).frame(height: 180) }
                    ForEach(0..<40) { Text("Setting \($0)") }
                }.formStyle(.grouped)
            case "code": NetCode(text: text + String(repeating: " long line", count: 200), mime: "text/plain", lines: true)
            case "table":
                DevApplicationGrid(columns: [.init(title: "Name", width: 800)],
                                   rows: (0..<100).map { ApplicationGridRow(id: String($0), cells: ["Row \($0)"]) },
                                   selected: "", pick: { _ in })
            case "horizontal":
                ThreadScrollView(.horizontal) {
                    HStack { ForEach(0..<80) { Text("Column \($0)").frame(width: 100, height: 180) } }
                }.padding(16)
            case "hidden":
                ThreadScrollView(showsIndicators: false) { Text(text).frame(maxWidth: .infinity) }.padding(16)
            default:
                ThreadScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
            }
        }
    }
}
