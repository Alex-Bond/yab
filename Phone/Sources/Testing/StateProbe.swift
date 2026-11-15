import Foundation
import UIKit
import WebKit
import os

/// What the comparison with the prototype reads from a named state, besides
/// its picture (Phone/tools/README.md, "compare"):
///
///   - `-YabState catalog` writes every registered state's name and title to
///     yab-ready/catalog.json and sets nothing up: `shot --all` and the atlas
///     test learn the list from the app itself, not from a grep.
///   - `-YabFrames YES` (or YAB_FRAMES=1, or YAB_READY_DIR set by a UI test)
///     writes, once the state has settled and before its ready marker, every
///     accessibility element with an identifier and its frame on screen in
///     points to yab-ready/<state>.frames.json, the same names proto-shot.js
///     reads from the prototype's markup (Phone/tools/ax-map).
///   - YAB_READY_DIR, a folder on the Mac running the simulator: the ready
///     marker and the frames go there too, where a UI test can read them.
///   - `-YabState perf.paging` brings every tab of the world in front in
///     turn, one every YAB_PAGING_MS (600 ms), round and round until the app
///     quits: PerfTests' memory of paging, web views made and let go the way
///     paging and the column do (WebPool keeps three live).
///
/// Test runs only: nothing here runs for people (no world named, no XCTest).
@MainActor
enum StateProbe {
    private static let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "state")

    static var readyDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["YAB_READY_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var wantsFrames: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-YabFrames"), i + 1 < arguments.count,
           ["yes", "true", "1"].contains(arguments[i + 1].lowercased()) { return true }
        return ProcessInfo.processInfo.environment["YAB_FRAMES"] == "1" || readyDirectory != nil
    }

    // MARK: - the catalog

    /// Handles the probe's own state names; true when `name` was one of them.
    static func handles(_ name: String, in app: AppModel) -> Bool {
        switch name {
        case "catalog":
            let states = StateCatalog.all.map { ["name": $0.name, "title": $0.title, "note": $0.note] }
            write(json: ["states": states], named: "catalog.json")
            StateRunner.ready("catalog", ["states=\(states.count)"])
            return true
        case "perf.paging":
            page(app)
            return true
        default:
            return false
        }
    }

    /// Every tab of every space in front in turn, for as long as the app runs.
    private static func page(_ app: AppModel) {
        let tabs = app.browser.allTabs
        let gap = Int(ProcessInfo.processInfo.environment["YAB_PAGING_MS"] ?? "") ?? 600
        StateRunner.ready("perf.paging", ["settled=yes", "tabs=\(tabs.count)", "every=\(gap) ms"])
        guard tabs.count > 1 else { return }
        Task { @MainActor in
            var i = 0
            while true {
                try? await Task.sleep(for: .milliseconds(gap))
                i = (i + 1) % tabs.count
                app.browser.select(tabs[i].id)
            }
        }
    }

    // MARK: - frames

    /// The state is being set up: SwiftUI only builds its accessibility tree
    /// for an assistive client, so a frames run asks for one first.
    static func began() {
        guard wantsFrames else { return }
        Automation.enable()
    }

    /// The state has settled; called before its ready marker is written.
    static func settled(_ name: String, _ notes: [String]) {
        guard name != "catalog" else { return }
        if wantsFrames && name != "perf.paging" {
            let elements = AXWalk.elements()
            let screen = UIScreen.main.bounds.size
            var json: [String: Any] = [
                "state": name,
                "source": "app",
                "screen": ["w": screen.width, "h": screen.height],
                "scale": UIScreen.main.scale,
                "elements": elements.map(\.json),
            ]
            // Nothing found: how the walk went, to see why.
            if elements.isEmpty { json["walk"] = AXWalk.lastWalk }
            write(json: json, named: "\(name).frames.json")
            log.info("frames: \(name, privacy: .public), \(elements.count) elements")
            Automation.restore()
        }
        if let folder = readyDirectory {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data((notes.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

    /// Writes beside the ready markers, and into YAB_READY_DIR when a UI test set one.
    private static func write(json: [String: Any], named file: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        var folders: [URL] = []
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            folders.append(caches.appendingPathComponent("yab-ready"))
        }
        if let folder = readyDirectory { folders.append(folder) }
        for folder in folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent(file), options: .atomic)
        }
    }
}

/// An element of the accessibility tree with an identifier, in screen points.
struct ProbedElement {
    let id: String
    let frame: CGRect
    let label: String
    let value: String
    let traits: [String]

    var json: [String: Any] {
        func r(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }
        return ["id": id, "x": r(frame.minX), "y": r(frame.minY), "w": r(frame.width), "h": r(frame.height),
                "label": label, "value": value, "traits": traits]
    }
}

/// Walks the key window's accessibility tree the way an assistive client
/// does: views, then each container's elements (SwiftUI's nodes live there),
/// never into a web view's own page.
@MainActor
enum AXWalk {
    /// How the last walk went, for when it finds nothing: windows, nodes, the top classes.
    static var lastWalk: [String: Any] = [:]
    private static var trail: [String] = []

    static func elements() -> [ProbedElement] {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows).filter { !$0.isHidden }
        var out: [ProbedElement] = []
        var seen = Set<String>()
        var visited = Set<ObjectIdentifier>()
        trail = []
        for window in windows { visit(window, &out, &seen, &visited, depth: 0) }
        lastWalk = ["scenes": scenes.count, "windows": windows.count, "nodes": visited.count, "trail": Array(trail.prefix(60))]
        return out
    }

    private static func visit(_ node: NSObject, _ out: inout [ProbedElement], _ seen: inout Set<String>,
                              _ visited: inout Set<ObjectIdentifier>, depth: Int) {
        guard depth < 80, visited.insert(ObjectIdentifier(node)).inserted else { return }
        if trail.count < 200 {
            let id = identifier(node)
            trail.append("\(depth) \(type(of: node))\(id.isEmpty ? "" : " #\(id)") ax=\(node.isAccessibilityElement) n=\(node.accessibilityElementCount())")
        }
        if let view = node as? UIView, view.isHidden || view.alpha < 0.01 { return }
        if node.accessibilityElementsHidden { return }
        let id = identifier(node)
        if !id.isEmpty {
            let frame = node.accessibilityFrame
            // A lazy page off screen can report an infinite frame.
            func n(_ v: CGFloat) -> String { v.isFinite ? String(Int(v.rounded())) : "inf" }
            let key = "\(id)|\(n(frame.minX))|\(n(frame.minY))|\(n(frame.width))|\(n(frame.height))"
            let finite = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            if finite, seen.insert(key).inserted {
                out.append(ProbedElement(id: id, frame: frame, label: node.accessibilityLabel ?? "",
                                         value: node.accessibilityValue ?? "", traits: names(node.accessibilityTraits)))
            }
        }
        // The page's own markup is the web process's, and not ours to compare.
        if node is WKWebView { return }
        if let elements = node.accessibilityElements as? [NSObject] {
            for element in elements { visit(element, &out, &seen, &visited, depth: depth + 1) }
        } else {
            let count = node.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<min(count, 2000) {
                    if let element = node.accessibilityElement(at: i) as? NSObject {
                        visit(element, &out, &seen, &visited, depth: depth + 1)
                    }
                }
            }
        }
        if let view = node as? UIView {
            for sub in view.subviews { visit(sub, &out, &seen, &visited, depth: depth + 1) }
        }
    }

    /// The identifier of a view or of an element that isn't one (SwiftUI's
    /// nodes): a cast to UIAccessibilityIdentification misses those.
    private static func identifier(_ node: NSObject) -> String {
        if let view = node as? UIView { return view.accessibilityIdentifier ?? "" }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard node.responds(to: selector) else { return "" }
        return node.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }

    private static func names(_ traits: UIAccessibilityTraits) -> [String] {
        let known: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"), (.image, "image"), (.selected, "selected"),
            (.staticText, "text"), (.searchField, "search"), (.adjustable, "adjustable"), (.notEnabled, "disabled"),
            (.tabBar, "tabBar"), (.toggleButton, "toggle"),
        ]
        return known.filter { traits.contains($0.0) }.map(\.1)
    }
}

/// The simulator's "an assistive client is here" switch, which XCTest turns
/// on for its own runs: SwiftUI builds no accessibility nodes without it.
/// Private, so debug builds only, and put back as it was once read.
@MainActor
private enum Automation {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void
    private static var previous: Int32?

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        #if DEBUG
        if let found = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return found } // RTLD_DEFAULT
        var paths = ["/usr/lib/libAccessibility.dylib"]
        if let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] { paths.insert(root + "/usr/lib/libAccessibility.dylib", at: 0) }
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW), let found = dlsym(handle, name) { return found }
        }
        #endif
        return nil
    }

    static func enable() {
        guard previous == nil,
              let get = symbol("_AXSAutomationEnabled"), let set = symbol("_AXSSetAutomationEnabled") else { return }
        let was = unsafeBitCast(get, to: Getter.self)()
        previous = was
        if was == 0 { unsafeBitCast(set, to: Setter.self)(1) }
    }

    static func restore() {
        guard let was = previous, was == 0, let set = symbol("_AXSSetAutomationEnabled") else { return }
        unsafeBitCast(set, to: Setter.self)(0)
        previous = nil
    }
}
