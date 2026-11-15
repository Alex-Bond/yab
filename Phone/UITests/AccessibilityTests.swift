import XCTest

/// Xcode's accessibility audit on every registered state: contrast, element
/// descriptions, hit regions, Dynamic Type, clipped text, traits. Each issue
/// is written to YAB_OUT/a11y/report.json with its state and element, and
/// the counts per state print in the log. The test reports and passes; with
/// YAB_A11Y_STRICT=1 an issue in any state fails it (for when the screens are
/// done, M9). A state whose page never drew isn't audited (a blank page has
/// nothing to say) and fails the test.
///
/// An issue is the web page's when its element lies inside the web view in
/// the accessibility tree, and the app's otherwise, hidden elements of the
/// app's included: what decides is where the element hangs, not where it is
/// drawn.
///
///     Phone/scripts/remote a11y [STATE...]
final class AccessibilityTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testEveryStateAudit() throws {
        let app = XCUIApplication()
        let states = Atlas.states(app)
        XCTAssertFalse(states.isEmpty, "no states: neither YAB_STATES nor the app's catalog")
        let strict = Atlas.environment["YAB_A11Y_STRICT"] == "1"
        let ready = Atlas.readyFolder()
        var report: [[String: Any]] = []
        var lines: [String] = []
        var unsettled: [String] = []
        for (name, title) in states {
            let outcome = Atlas.open(app, state: name, ready: ready)
            guard outcome == .settled else {
                report.append(["state": name, "title": title, "error": outcome.words])
                lines.append("\(name): not audited, \(outcome.words)")
                print("a11y: \(lines.last!)")
                unsettled.append(name)
                continue
            }
            var issues: [[String: Any]] = []
            let page = Self.pageElements(app)
            let keyboard = Self.keyboardElements(app)
            do {
                try app.performAccessibilityAudit(for: .all) { issue in
                    issues.append(Self.describe(issue, page: page, keyboard: keyboard))
                    // Recorded here, judged below: the audit itself never fails the test.
                    return true
                }
            } catch {
                issues.append(["type": "audit failed", "description": "\(error)", "where": "app"])
            }
            // Ours are what the app draws; the rest is the web page in it, a
            // fixture standing for someone else's site.
            let mine = issues.filter { $0["where"] as? String != "page" }
            let kinds = Dictionary(grouping: mine, by: { $0["type"] as? String ?? "?" }).mapValues(\.count)
            let summary = kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let inPage = issues.count - mine.count
            lines.append("\(name): \(mine.count) in the app\(mine.isEmpty ? "" : " (\(summary))"), \(inPage) in the web page")
            print("a11y: \(lines.last!)")
            report.append(["state": name, "title": title, "issues": issues])
            if strict && !mine.isEmpty { XCTFail("\(name): \(mine.count) accessibility issues (\(summary))") }
        }
        Atlas.write(Atlas.json(["world": Atlas.world, "model": Atlas.model, "states": report]), to: "a11y/report.json")
        Atlas.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: "a11y/summary.txt")
        XCTAssertTrue(unsettled.isEmpty, "not audited, the page never drew: \(unsettled.joined(separator: ", "))")
    }

    /// Every element inside the state's web views, as one snapshot of the
    /// tree has them: the web view and all it holds are the page's.
    private static func pageElements(_ app: XCUIApplication) -> Set<String> {
        guard let root = try? app.snapshot() else { return [] }
        var out = Set<String>()
        func visit(_ node: XCUIElementSnapshot, inPage: Bool) {
            let inside = inPage || node.elementType == .webView
            if inside { out.insert(signature(node)) }
            node.children.forEach { visit($0, inPage: inside) }
        }
        visit(root, inPage: false)
        return out
    }

    /// An element told apart by what the tree says of it: its type, frame and words.
    private static func signature(_ e: XCUIElementAttributes) -> String {
        let f = e.frame
        return "\(e.elementType.rawValue)|\(Int(f.minX.rounded()))|\(Int(f.minY.rounded()))|\(Int(f.width.rounded()))|\(Int(f.height.rounded()))|\(e.identifier)|\(e.label)"
    }

    /// Evidence only. System keyboard ownership does not change the strict
    /// result until a specific native issue has been investigated.
    private static func keyboardElements(_ app: XCUIApplication) -> Set<String> {
        var out = Set<String>()
        func visit(_ node: XCUIElementSnapshot) {
            out.insert(signature(node))
            node.children.forEach(visit)
        }
        for element in app.keyboards.allElementsBoundByIndex {
            if let snapshot = try? element.snapshot() { visit(snapshot) }
        }
        return out
    }

    private static func describe(_ issue: XCUIAccessibilityAuditIssue, page: Set<String>, keyboard: Set<String>) -> [String: Any] {
        var out: [String: Any] = [
            "type": name(issue.auditType),
            "description": issue.compactDescription,
            "detail": issue.detailedDescription,
            "where": "app",
        ]
        // One snapshot of the element answers everything (each property of an
        // XCUIElement is a query of its own, seconds each on a busy Mac); one
        // that is gone by now throws instead of failing the test.
        if let element = issue.element, let snap = try? element.snapshot() {
            let f = snap.frame
            out["element"] = [
                "id": snap.identifier, "label": snap.label, "type": snap.elementType.rawValue,
                "x": Double(f.minX), "y": Double(f.minY), "w": Double(f.width), "h": Double(f.height),
            ] as [String: Any]
            // Inside a web view in the tree: the page's, a fixture standing for someone else's site.
            if snap.elementType == .webView || page.contains(signature(snap)) { out["where"] = "page" }
            if keyboard.contains(signature(snap)) { out["systemKeyboard"] = true }
        }
        return out
    }

    private static func name(_ type: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "element detection"), (.hitRegion, "hit region"),
            (.sufficientElementDescription, "element description"), (.dynamicType, "dynamic type"),
            (.textClipped, "text clipped"), (.trait, "trait"),
        ]
        return names.first { type.contains($0.0) }?.1 ?? "type \(type.rawValue)"
    }
}
