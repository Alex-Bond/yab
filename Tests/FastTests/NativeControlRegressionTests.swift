import AppKit
import Testing
@testable import Fast
@testable import MailCore

/// Regression coverage for the eight defects reproduced during native-control review.
extension NativeControlTests {
    @Suite(.serialized)
    struct NativeControlRegressionTests {
        @MainActor private func call(_ control: NativeControl, _ verb: String, _ browser: Browser,
                                    _ session: Agents.Session, _ values: [String: Any] = [:]) -> [String: Any] {
            var request = values; request["session"] = session.id
            var result: [String: Any] = [:]
            control.handle("agent-native-" + verb, request: request, browser: browser) { result = $0 }
            return result
        }

        @MainActor private func fixture(_ body: (NativeControl, Browser, Agents.Session) throws -> Void) rethrows {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let window = UUID(), browser = Browser(windowID: window)
            _ = browser.open(URL(string: "about:blank#native-review")!, foreground: true)
            let session = Agents.shared.attach(name: "Native review")
            let keys = ["spaces", "agents.asking", "zoom.native-review.test", "mail", MailExperiment.key, "mail.pin", "mail.pin.asked",
                        "backdrop.transparency", "backdrop.swatch", "backdrop.color", "backdrop.colors", "backdrop.grain", "backdrop.grain.amount"]
            let saved = keys.map { Store.settings.object(forKey: $0) }
            let file = Store.file("spaces.json"), spaces = try? Data(contentsOf: file)
            browser.prefs.agentsAsking = .bypass
            defer {
                for (key, value) in zip(keys, saved) { Store.settings.set(value, forKey: key) }
                if let spaces { try? spaces.write(to: file) } else { try? FileManager.default.removeItem(at: file) }
                for tab in browser.tabs + browser.parkedTabs { tab.close() }
                Agents.shared.detach(session.id)
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
            }
            try body(NativeControl(file: folder.appendingPathComponent("operations.json")), browser, session)
        }

        @MainActor private func request(_ action: String, _ kind: String, _ id: String, _ args: [String: Any] = [:]) -> [String: Any] {
            ["action": action, "target": ["kind": kind, "id": id], "arguments": args, "requestId": UUID().uuidString]
        }

        /// These positive scenarios model the person's requested operation.
        /// Answer an actual confirmation only when the current policy requires one.
        @MainActor private func afterRequiredConfirmation(_ control: NativeControl, _ browser: Browser,
                                             _ session: Agents.Session, _ values: [String: Any]) throws -> [String: Any] {
            let pending = call(control, "apply", browser, session, values)
            guard pending["status"] as? String == "needs_user" else { return pending }
            let operation = try #require(pending["operationId"] as? String)
            let anchor = try #require(browser.active)
            let permit = try #require(anchor.permit)
            guard case .native(_, let shown) = permit.kind else {
                Issue.record("The fixture must answer the actual native confirmation")
                return pending
            }
            try #require(permit.session == session.id && shown == operation)
            anchor.permit = nil
            Agents.shared.handBack(anchor)
            control.decide(operation, session: session.id, yes: true)
            return try #require(control.changes.receipt(operation, session: session.id)?.result?.any as? [String: Any])
        }

        @MainActor @Test func pinUndoRestoresFolderSplitAndOrder() throws {
            try fixture { control, browser, session in
                let first = try #require(browser.active), second = Tab(), third = Tab()
                for (i, tab) in [first, second, third].enumerated() {
                    tab.restore(url: URL(string: "https://native-review.test/\(i)")!, title: "Review \(i)")
                    browser.prepare(tab)
                }
                let folder = Nest(name: "Original folder")
                second.kept = true; second.nest = folder
                third.kept = true; third.nest = folder
                browser.lay([second, third, first])
                browser.pairs = [Pair(first: second.id, second: third.id)]
                let original = browser.tabs.map(\.id)
                let applied = try afterRequiredConfirmation(control, browser, session, request("tabs.pin", "tab", second.id.uuidString, ["value": true]))
                #expect(applied["status"] as? String == "verified")
                let undone = call(control, "undo", browser, session, ["changeId": applied["operationId"]!])
                #expect(undone["undone"] as? Bool == true)
                #expect(second.kept && second.nest === folder)
                #expect(browser.pairs == [Pair(first: second.id, second: third.id)])
                #expect(browser.tabs.map(\.id) == original)
            }
        }

        /// #1857: the request is small, but its two whole-space snapshots
        /// exceed the incoming request limit. Success, retry and Undo agree.
        @MainActor @Test func largeFolderResultsStayVerifiedAndUndoable() throws {
            try fixture { control, browser, session in
                let outer = Nest(name: "Design"), inner = Nest(name: "Inspiration")
                inner.parent = outer
                let tabs = (0..<130).map { index -> Tab in
                    let tab = Tab()
                    tab.restore(url: URL(string: "https://native-review.test/\(index)/" + String(repeating: "page", count: 30))!,
                                title: "Design inspiration \(index) " + String(repeating: "reference ", count: 12))
                    tab.kept = true; tab.nest = inner
                    browser.prepare(tab)
                    return tab
                }
                browser.lay(tabs)
                let original = tabs.map(\.id)
                for action in ["tabs.move_to_folder", "tabs.group"] {
                    for count in [1, 2, 5, 19] {
                        for expected in [false, true] {
                            let selected = Array(tabs.prefix(count))
                            var values = request(action, action == "tabs.group" ? "space" : "folder",
                                                 action == "tabs.group" ? browser.spaceID.uuidString : outer.id.uuidString,
                                                 action == "tabs.group" ? ["tabs": selected.map { $0.id.uuidString }, "name": "New group"]
                                                     : ["tabs": selected.map { $0.id.uuidString }])
                            if expected {
                                values["expectedVersion"] = try #require(call(control, "context", browser, session, values)["resourceVersion"] as? String)
                            }
                            let applied = try afterRequiredConfirmation(control, browser, session, values)
                            try #require(applied["status"] as? String == "verified", "\(action), \(count) tabs: \(applied["error"] ?? "")")
                            #expect(try JSONSerialization.data(withJSONObject: applied).count > 65_536)
                            #expect(selected.allSatisfy { $0.kept && $0.nest !== inner })
                            let operation = try #require(applied["operationId"] as? String)
                            let folders = browser.nests.map(\.id)
                            let retry = call(control, "apply", browser, session, values)
                            #expect(retry["status"] as? String == "verified")
                            #expect(retry["operationId"] as? String == operation)
                            #expect(browser.nests.map(\.id) == folders)
                            let stored = try #require(control.changes.receipt(operation, session: session.id))
                            #expect(stored.status == "verified" && stored.after != nil)
                            let reopened = NativeChanges(file: control.changes.file)
                            #expect(reopened.receipt(operation, session: session.id)?.result == stored.result)
                            let undone = call(control, "undo", browser, session, ["changeId": operation])
                            #expect(undone["undone"] as? Bool == true)
                            #expect(tabs.allSatisfy { $0.kept && $0.nest === inner })
                            #expect(browser.tabs.map(\.id) == original)
                            #expect(inner.parent === outer)
                        }
                    }
                }
                let rejected = call(control, "apply", browser, session,
                                    request("tabs.group", "space", browser.spaceID.uuidString,
                                            ["tabs": [tabs[0].id.uuidString], "name": String(repeating: "x", count: 65_537)]))
                #expect(rejected["code"] as? String == "invalid_arguments")
                #expect(rejected["error"] as? String == "The request is too large")
                #expect(tabs.allSatisfy { $0.nest === inner })
            }
        }

        @MainActor @Test func zoomUndoPreservesLaterManualSiteZoomFromAnotherTab() throws {
            try fixture { control, browser, session in
                let first = try #require(browser.active), second = Tab()
                for (i, tab) in [first, second].enumerated() {
                    tab.restore(url: URL(string: "https://native-review.test/\(i)")!, title: "Zoom \(i)")
                    browser.prepare(tab)
                }
                browser.lay([first, second])
                let applied = try afterRequiredConfirmation(control, browser, session, request("site.set_zoom", "tab", first.id.uuidString, ["value": 1.5]))
                #expect(applied["status"] as? String == "verified")
                second.magnify(to: 2)
                #expect(Store.settings.double(forKey: "zoom.native-review.test") == 2)
                let undone = call(control, "undo", browser, session, ["changeId": applied["operationId"]!])
                #expect(undone["status"] as? String == "conflict")
                #expect(Store.settings.double(forKey: "zoom.native-review.test") == 2)
            }
        }

        @MainActor @Test func disabledSpacesSwitchReportsFailureWithoutSwitching() throws {
            try fixture { control, browser, session in
                let target = browser.addSpace(named: "Disabled review", ownSignIns: false, show: false)
                browser.prefs.usesSpaces = false
                let before = browser.spaceID
                let result = try afterRequiredConfirmation(control, browser, session, request("space.switch", "space", target.uuidString))
                #expect(result["code"] as? String == "spaces_disabled")
                #expect(browser.spaceID == before && browser.spaceID != target)
            }
        }

        @MainActor @Test func deletionConfirmationRejectsNewTabsInTargetSpace() throws {
            try fixture { control, browser, session in
                browser.prefs.usesSpaces = true
                let target = browser.addSpace(named: "Delete review", ownSignIns: false, show: false)
                let pending = call(control, "apply", browser, session, request("space.delete", "space", target.uuidString))
                #expect(pending["status"] as? String == "needs_user")
                let added = Tab(); added.restore(url: URL(string: "https://native-review.test/new-work")!, title: "New work")
                browser.prepare(added); browser.lay(browser.tabs + [added])
                #expect(browser.moveTabs([added], to: target, say: false) != nil)
                let operation = try #require(pending["operationId"] as? String)
                if let anchor = browser.active { anchor.permit = nil; Agents.shared.handBack(anchor) }
                control.decide(operation, session: session.id, yes: true)
                #expect(control.changes.receipt(operation, session: session.id)?.status == "conflict")
                #expect(browser.spaces.contains { $0.id == target })
                #expect(browser.parkedTabs.contains { $0 === added })
            }
        }

        @MainActor @Test func movingRecentlyTouchedUserTabIsBlocked() throws {
            try fixture { control, browser, session in
                browser.prefs.usesSpaces = true
                let target = browser.addSpace(named: "Move review", ownSignIns: false, show: false)
                let tab = try #require(browser.active)
                tab.restore(url: URL(string: "https://native-review.test/editing")!, title: "Editing")
                let previous = AgentFeed.shared.browser
                AgentFeed.shared.browser = browser
                defer { AgentFeed.shared.browser = previous }
                PageView.person?(tab.page)
                #expect(AgentFeed.shared.touchedLately(tab))
                let result = call(control, "apply", browser, session, request("tabs.move", "space", target.uuidString, ["tabs": [tab.id.uuidString]]))
                #expect(result["status"] as? String == "conflict")
                #expect(browser.tabs.contains { $0 === tab })
            }
        }

        @MainActor @Test func mailUnpinIsRejectedBeforeClosingTheTab() throws {
            try fixture { control, browser, session in
                let tab = try #require(browser.active)
                tab.restore(url: MailPage.url, title: "Mail")
                browser.pin(tab)
                let result = call(control, "apply", browser, session, request("tabs.pin", "tab", tab.id.uuidString, ["value": false]))
                #expect(result["code"] as? String == "unsupported")
                #expect(browser.tabs.contains { $0 === tab })
                #expect(result["effectsMayHaveApplied"] == nil)
            }
        }

        @MainActor @Test func spaceAppearanceUpdatesEveryWindowWithoutStaleOverwrite() throws {
            try fixture { control, browser, session in
                let id = UUID(), other = Browser(windowID: id)
                defer {
                    for tab in other.tabs + other.parkedTabs { tab.close() }
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                }
                #expect(browser.spaceID == other.spaceID)
                let old = SpacePaint(other.prefs)
                let color = old.color == "13579B" ? "#2468AC" : "#13579B"
                let result = call(control, "apply", browser, session,
                                  request("space.set_appearance", "space", browser.spaceID.uuidString, ["color": color, "grain": 0.123]))
                #expect(result["status"] as? String == "verified")
                let changed = SpacePaint(browser.prefs)
                #expect(changed != old)
                #expect(SpacePaint(other.prefs) == changed)
                #expect(other.space.paint == changed)
                other.keepPaint()
                #expect(browser.space.paint == changed)
            }
        }

        @MainActor @Test func switchingOutOfMailCanBeUndone() throws {
            try fixture { control, browser, session in
                browser.prefs.usesSpaces = true
                browser.prefs.usesMail = true
                browser.enterMail()
                #expect(browser.inMail)
                let result = try afterRequiredConfirmation(control, browser, session,
                                  request("space.switch", "space", Space.firstID.uuidString))
                #expect(result["status"] as? String == "verified")
                #expect((result["undo"] as? [String: Any])?["available"] as? Bool == true)
                let undone = call(control, "undo", browser, session, ["changeId": result["operationId"]!])
                #expect(undone["undone"] as? Bool == true)
                #expect(browser.inMail)
            }
        }

        @MainActor @Test func pinUndoPreservesLaterRowChangesAndSplitRoundTrips() throws {
            try fixture { control, browser, session in
                let tab = try #require(browser.active), other = Tab()
                tab.restore(url: URL(string: "https://native-review.test/pin")!, title: "Pin")
                other.restore(url: URL(string: "https://native-review.test/other")!, title: "Other")
                browser.prepare(other); browser.lay([tab, other])
                let applied = try afterRequiredConfirmation(control, browser, session, request("tabs.pin", "tab", tab.id.uuidString, ["value": true]))
                #expect(applied["status"] as? String == "verified")
                browser.pairs = [Pair(first: tab.id, second: other.id)]
                browser.pairs = []
                #expect(call(control, "undo", browser, session, ["changeId": applied["operationId"]!])["status"] as? String == "conflict")
                #expect(tab.pin != nil)
            }
            try fixture { control, browser, session in
                let tab = try #require(browser.active)
                tab.restore(url: URL(string: "https://native-review.test/pin")!, title: "Pin")
                let applied = try afterRequiredConfirmation(control, browser, session, request("tabs.pin", "tab", tab.id.uuidString, ["value": true]))
                let added = browser.blankTab(); browser.lay(browser.tabs + [added])
                #expect(call(control, "undo", browser, session, ["changeId": applied["operationId"]!])["status"] as? String == "conflict")
                #expect(browser.tabs.contains { $0 === added })
            }
        }

        @MainActor @Test(arguments: [false, true]) func zoomUndoRestoresTheOriginalRememberedValue(hasSavedZoom: Bool) throws {
            try fixture { control, browser, session in
                let tab = try #require(browser.active)
                tab.restore(url: URL(string: "https://native-review.test/zoom")!, title: "Zoom")
                PageAppearance.rememberZoom(nil, host: "native-review.test")
                if hasSavedZoom { tab.magnify(to: 1.25) }
                let original = tab.zoom
                let applied = try afterRequiredConfirmation(control, browser, session, request("site.set_zoom", "tab", tab.id.uuidString, ["value": 1.5]))
                #expect(applied["status"] as? String == "verified")
                #expect(call(control, "undo", browser, session, ["changeId": applied["operationId"]!])["undone"] as? Bool == true)
                #expect(tab.zoom == original)
                if hasSavedZoom { #expect(Store.settings.double(forKey: "zoom.native-review.test") == 1.25) }
                else { #expect(Store.settings.object(forKey: "zoom.native-review.test") == nil) }
            }
        }

        @MainActor @Test func zoomUndoDetectsManualRoundTripInAnotherTab() throws {
            try fixture { control, browser, session in
                let first = try #require(browser.active), second = Tab()
                for tab in [first, second] { tab.restore(url: URL(string: "https://native-review.test/zoom")!, title: "Zoom"); browser.prepare(tab) }
                browser.lay([first, second])
                let applied = try afterRequiredConfirmation(control, browser, session, request("site.set_zoom", "tab", first.id.uuidString, ["value": 1.5]))
                second.magnify(to: 2); second.magnify(to: 1.5)
                #expect(call(control, "undo", browser, session, ["changeId": applied["operationId"]!])["status"] as? String == "conflict")
                #expect(Store.settings.double(forKey: "zoom.native-review.test") == 1.5)
            }
        }

        @MainActor @Test func zoomUndoPreservesManualResetInAnotherTab() throws {
            try fixture { control, browser, session in
                let first = try #require(browser.active), second = Tab()
                for tab in [first, second] { tab.restore(url: URL(string: "https://native-review.test/zoom")!, title: "Zoom"); browser.prepare(tab) }
                browser.lay([first, second])
                let applied = try afterRequiredConfirmation(control, browser, session, request("site.set_zoom", "tab", first.id.uuidString, ["value": 1.5]))
                second.resetZoom()
                #expect(call(control, "undo", browser, session, ["changeId": applied["operationId"]!])["status"] as? String == "conflict")
                #expect(Store.settings.object(forKey: "zoom.native-review.test") == nil)
            }
        }

        @MainActor @Test func deletionRechecksSavedRowsOfClosedWindows() throws {
            try fixture { control, browser, session in
                browser.prefs.usesSpaces = true
                let target = browser.addSpace(named: "Closed window review", ownSignIns: false, show: false)
                let window = UUID()
                let file = Store.file("session-window-\(window.uuidString)-\(target.uuidString).json")
                defer { try? FileManager.default.removeItem(at: file) }
                let pending = call(control, "apply", browser, session, request("space.delete", "space", target.uuidString))
                #expect(pending["status"] as? String == "needs_user")
                Session.write(now: true, space: target, window: window,
                              Session.Shape(tabs: [Session.Entry(url: "https://native-review.test/private-path?token=secret", title: "New work")], active: 0))
                let operation = try #require(pending["operationId"] as? String)
                if let anchor = browser.active { anchor.permit = nil; Agents.shared.handBack(anchor) }
                control.decide(operation, session: session.id, yes: true)
                #expect(control.changes.receipt(operation, session: session.id)?.status == "conflict")
                #expect(FileManager.default.fileExists(atPath: file.path))
                let preview = call(control, "context", browser, session, ["action": "space.delete", "target": ["kind": "space", "id": target.uuidString], "arguments": [:]])
                let json = String(decoding: try JSONSerialization.data(withJSONObject: preview), as: UTF8.self)
                #expect(!json.contains("private-path") && !json.contains("token=secret"))
            }
        }

        @MainActor @Test func moveRechecksUserActivityAfterConfirmation() throws {
            try fixture { control, browser, session in
                browser.prefs.usesSpaces = true; browser.prefs.agentsAsking = .ask
                let target = browser.addSpace(named: "Activity review", ownSignIns: false, show: false)
                let tab = try #require(browser.active)
                tab.restore(url: URL(string: "https://native-review.test/editing")!, title: "Editing")
                let pending = call(control, "apply", browser, session, request("tabs.move", "space", target.uuidString, ["tabs": [tab.id.uuidString]]))
                #expect(pending["status"] as? String == "needs_user")
                let previous = AgentFeed.shared.browser; AgentFeed.shared.browser = browser
                defer { AgentFeed.shared.browser = previous }
                PageView.person?(tab.page)
                tab.permit = nil; Agents.shared.handBack(tab)
                let operation = try #require(pending["operationId"] as? String)
                control.decide(operation, session: session.id, yes: true)
                #expect(control.changes.receipt(operation, session: session.id)?.status == "conflict")
                #expect(browser.tabs.contains { $0 === tab })
            }
        }
    }
}
