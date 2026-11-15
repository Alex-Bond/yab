import Foundation
import Darwin
import YabCoreClient

actor EventLog {
    var rows: [YabCoreEvent] = []
    func append(_ event: YabCoreEvent) { rows.append(event) }
    func all() -> [YabCoreEvent] { rows }
    func count() -> Int { rows.count }
    func find(_ name: String, tab: String? = nil, after: Int = 0) -> YabCoreEvent? {
        rows.dropFirst(after).last { $0.name == name && (tab == nil || $0.tab == tab) }
    }
}
struct Failure: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}
func eventually(_ description: String, seconds: Double = 15, _ body: () async throws -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if try await body() { return }
        try await Task.sleep(nanoseconds: 30_000_000)
    }
    throw Failure(description: "Timed out: \(description)")
}
@main struct Probe {
    static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 || (args.count == 6 && args[5] == "persist") else { throw Failure(description: "YabCoreProbe SOCKET BASE_URL OUTPUT_DIR EXTENSION_DIR") }
        let client = try await YabCoreClient.connect(path: args[1])
        let base = args[2], out = URL(fileURLWithPath: args[3], isDirectory: true)
        let log = EventLog()
        let consumer = Task { for await event in client.events { await log.append(event) } }
        var checks: [String] = []
        func pass(_ name: String) { checks.append(name); print("PASS \(name)"); fflush(stdout) }
        func request(_ method: String, _ tab: String, _ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
            var params = extra; params["tab"] = .string(tab)
            return try await client.request(method, params: params)
        }
        func eval(_ tab: String, _ expression: String, world: String = "test") async throws -> JSONValue {
            try await client.evaluate(tab: tab, world: world, function: "function(arg){return (\(expression))}")
        }
        func ready(_ tab: String, _ suffix: String) async throws {
            try await eventually("navigation \(suffix)") {
                let state = try await request("tab.state", tab)
                return state["url"].string == base + suffix && state["loading"] == .bool(false) && state["hasDocument"] == .bool(true) && state["devToolsReady"] == .bool(true)
            }
        }
        func pixels(_ tab: String, _ token: String, _ color: String, width: Double = 800, height: Double = 600) async throws {
            try await eventually("layer \(token)") { await log.find("layer.changed", tab: tab)?.params["contextId"]?.number ?? 0 > 0 }
            guard let event = await log.find("layer.changed", tab: tab), let cid = event.params["contextId"]?.number else { throw Failure(description: "No context") }
            let value: [String: Any] = ["contextId": cid, "width": width, "height": height, "token": token]
            try JSONSerialization.data(withJSONObject: value).write(to: out.appendingPathComponent("host-state.json"), options: .atomic)
            let resultURL = out.appendingPathComponent(token + ".json")
            try await eventually("host pixels \(token)") { FileManager.default.fileExists(atPath: resultURL.path) }
            let result = try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as! [String: Any]
            let total = (result["total"] as? Double) ?? 0
            let count = (result[color] as? Double) ?? 0
            try require(total > 100 && count / total > 0.65, "Hosted \(token) is blank or wrong color: \(result)")
            pass("pixels-\(token)")
        }
        if args.count == 6 {
            var persistentTab: String?
            do {
                try await client.openProfile("space-a"); pass("reopened-profile")
                let tab = try await client.createTab(profile: "space-a", url: base + "/a")
                persistentTab = tab; pass("recreated-tab")
                try await ready(tab, "/a"); pass("persistent-document-ready")
                let state = try await request("tab.state", tab)
                try JSONEncoder().encode(state).write(to: out.appendingPathComponent("persistence-state.json"))
                try require(try await eval(tab, "localStorage.getItem('profile')") == .string("space-a"), "Persistent localStorage was lost after helper restart")
                pass("localstorage-after-helper-restart")
                try require(try await eval(tab, "document.cookie.includes('space=space-a')") == .bool(true), "Persistent session cookie was lost after helper restart")
                pass("session-cookie-after-helper-restart")
                try await client.closeTab(tab)
                _ = try await client.request("shutdown")
                consumer.cancel()
                try JSONSerialization.data(withJSONObject: ["passed": checks], options: .prettyPrinted).write(to: out.appendingPathComponent("persistence.json"))
                return
            } catch {
                let rows = await log.all()
                try? JSONEncoder().encode(rows.map { JSONValue.object(["event": .string($0.name), "params": .object($0.params)]) }).write(to: out.appendingPathComponent("persistence-events.json"))
                if let tab = persistentTab, let state = try? await client.request("tab.state", params: ["tab": .string(tab)], timeout: 2) {
                    try? JSONEncoder().encode(state).write(to: out.appendingPathComponent("persistence-state.json"))
                }
                _ = try? await client.request("shutdown", timeout: 2)
                await client.disconnect(); consumer.cancel(); throw error
            }
        }
        do {
            try await client.openProfile("space-a")
            try await client.openProfile("space-b")
            try await client.openProfile("private", privateMode: true)
            do { _ = try await client.request("profile.open", params: ["profile": .string("../escape")]); throw Failure(description: "Accepted invalid profile") }
            catch is YabCoreError { pass("profile-validation") }
            let a = try await client.createTab(profile: "space-a", url: base + "/a")
            let b = try await client.createTab(profile: "space-b", url: base + "/b")
            let secret = try await client.createTab(profile: "private", url: base + "/a")
            try await ready(a, "/a"); try await ready(b, "/b"); try await ready(secret, "/a")
            pass("three-profiles-three-tabs")
            _ = try await eval(a, "(localStorage.setItem('profile','space-a'),document.cookie='space=space-a; path=/',true)")
            try require(try await eval(b, "localStorage.getItem('profile')") == .null, "Storage leaked between spaces")
            try require(try await eval(secret, "document.cookie.includes('space-a')") == .bool(false), "Cookie leaked to private profile")
            pass("profile-storage-isolation")
            let value = try await client.evaluate(tab: a, world: "math", function: "function(arg){globalThis.privateValue=9;return {answer:arg.n*2,text:arg.text}}", arguments: .object(["n": .number(21), "text": .string("日本語\n\"")]))
            try require(value["answer"] == .number(42) && value["text"] == .string("日本語\n\""), "JSON arguments/results failed")
            try require(try await eval(a, "typeof globalThis.privateValue", world: "other") == .string("undefined"), "Worlds share globals")
            pass("isolated-worlds-json")
            do { _ = try await eval(a, "(()=>{throw new Error('expected')})()"); throw Failure(description: "Exception was swallowed") }
            catch is YabCoreError { pass("script-exception") }
            try await client.bind(tab: a, world: "test", name: "yabMessage")
            let mark = await log.count()
            _ = try await eval(a, "(yabMessage(JSON.stringify({kind:'hello',n:42})),true)")
            try await eventually("binding event") { await log.find("script.message", tab: a, after: mark)?.params["value"]?["n"] == .number(42) }
            pass("binding-message")
            try await eventually("page state") {
                let rows = await log.all()
                return rows.contains { $0.name == "page.state" && $0.tab == a && $0.params["title"] == .string("YabCore A") } &&
                    rows.contains { $0.name == "page.state" && $0.tab == a && $0.params["themeColor"] == .string("#12783c") } &&
                    rows.contains { $0.name == "page.state" && $0.tab == a && $0.params["faviconURL"]?.string?.contains("icon.svg") == true }
            }
            _ = try await eval(a, "(document.querySelector('meta[name=\"theme-color\"]').content='#123456',true)")
            try await eventually("theme mutation") { await log.all().contains { $0.tab == a && $0.params["themeColor"] == .string("#123456") } }
            pass("state-title-favicon-theme-loading")
            try await pixels(a, "green", "green")
            try await pixels(b, "red", "red")
            // Like the client, hand key status to the page first. Helpers whose CEF
            // lacks the external focus hook refuse the request; that is fine.
            _ = try? await request("tab.focus", a, ["focused": .bool(true)])
            _ = try await request("input.send", a, ["kind": .string("mouseDown"), "x": .number(100), "y": .number(110)])
            _ = try await request("input.send", a, ["kind": .string("mouseUp"), "x": .number(100), "y": .number(110)])
            _ = try await request("input.send", a, ["kind": .string("keyDown"), "keyCode": .number(0), "characters": .string("a"), "unmodified": .string("a")])
            _ = try await request("input.send", a, ["kind": .string("keyUp"), "keyCode": .number(0), "characters": .string("a"), "unmodified": .string("a")])
            _ = try await request("input.send", a, ["kind": .string("text"), "text": .string("日本語")])
            do {
                try await eventually("forwarded mouse/key/text") { try await eval(a, "document.querySelector('input').value") == .string("a日本語") }
            } catch {
                // Read only after the strict check fails. Preserve its event
                // ordering and expected value, and retain the original error.
                if let snapshot = try? await eval(a, "({value:document.querySelector('input').value,hasFocus:document.hasFocus(),active:document.activeElement?.tagName,visibility:document.visibilityState,rectangle:document.querySelector('input').getBoundingClientRect().toJSON()})"),
                   let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: out.appendingPathComponent("input-failure.json"))
                }
                throw error
            }
            pass("appkit-mouse-key-text")
            _ = try await request("input.send", a, ["kind": .string("wheel"), "x": .number(300), "y": .number(250), "deltaY": .number(-120), "deltaX": .number(0)])
            try await eventually("forwarded wheel") { try await eval(a, "Number(document.documentElement.dataset.wheels)>0") == .bool(true) }
            let wheelPoint = try await eval(a, "({x:Number(document.documentElement.dataset.wheelX),y:Number(document.documentElement.dataset.wheelY)})")
            try require(wheelPoint["x"] == .number(300) && wheelPoint["y"] == .number(250), "Wheel reached the wrong page point: \(wheelPoint)")
            try await eventually("wheel scroll offset") { try await eval(a, "scrollY>0") == .bool(true) }
            pass("appkit-wheel-at-page-point")
            _ = try await eval(a, "(scrollTo(0,0),true)")
            let resizeMark = await log.count()
            _ = try await client.resize(tab: a, width: 640, height: 480, scale: 1)
            try await eventually("resize layer event") { await log.find("layer.changed", tab: a, after: resizeMark)?.params["width"] == .number(640) }
            try require(try await eval(a, "innerWidth") == .number(640), "Browser did not resize")
            try await pixels(a, "resized", "green", width: 640, height: 480)
            _ = try await request("tab.visible", b, ["visible": .bool(false)])
            _ = try await request("tab.visible", b, ["visible": .bool(true)])
            pass("resize-and-visibility")
            try await client.navigate(tab: a, url: base + "/b"); try await ready(a, "/b")
            _ = try await request("tab.back", a); try await ready(a, "/a")
            _ = try await request("tab.forward", a); try await ready(a, "/b")
            _ = try await request("tab.reload", a); try await ready(a, "/b")
            _ = try await request("tab.stop", a)
            pass("navigation-history-reload-stop")
            // Bindings persist by world name, but globals must be recreated after navigation.
            let newMark = await log.count()
            _ = try await eval(a, "(yabMessage(JSON.stringify({n:43})),true)")
            try await eventually("binding after navigation") { await log.find("script.message", tab: a, after: newMark)?.params["value"]?["n"] == .number(43) }
            pass("binding-after-navigation")
            let dialogMark = await log.count()
            let prompt = Task { try await eval(a, "prompt('Protocol prompt','default')") }
            try await eventually("prompt event") { await log.find("dialog.open", tab: a, after: dialogMark) != nil }
            // JS dialogs belong to the client for both native host paths.
            // A helper widget would hide the question from Yab's agent/UI.
            guard let promptID = await log.find("dialog.open", tab: a, after: dialogMark)?.params["request"]?.string else {
                throw Failure(description: "Missing native dialog continuation")
            }
            try require(await log.find("popup.layer", after: dialogMark) == nil, "Native dialog unexpectedly created a helper widget")
            pass("native-dialog-left-to-client")
            _ = try await request("dialog.reply", a, ["request": .string(promptID), "accept": .bool(true), "text": .string("answer")])
            try require(try await prompt.value == .string("answer"), "Prompt reply lost")
            pass("prompt-and-reply")
            for kind in ["alert", "confirm"] {
                let before = await log.count()
                let action = Task { try await eval(a, "\(kind)('Protocol \(kind)')") }
                try await eventually("\(kind) event") { await log.find("dialog.open", tab: a, after: before) != nil }
                _ = try await request("dialog.reply", a, ["accept": .bool(true)])
                _ = try await action.value
            }
            pass("alert-confirm-and-replies")
            let popupMark = await log.count()
            _ = try await client.evaluate(tab: a, world: "test", function: "function(arg){window.open(arg);return true}", arguments: .string(base + "/a"), userGesture: true)
            try await eventually("new tab adoption") { await log.find("tab.created", after: popupMark) != nil }
            guard let popup = await log.find("tab.created", after: popupMark)?.tab else { throw Failure(description: "Missing popup tab") }
            _ = try await request("tab.adopt", popup, ["profile": .string("space-a"), "private": .bool(false)])
            try await client.closeTab(popup)
            pass("window-open-adoption")
            let crashMark = await log.count()
            // A validated renderer PID avoids macOS holding a deliberately
            // faulting process in crash reporting before CEF sees its exit.
            _ = try await request("page.killRenderer", a)
            try await eventually("renderer crash") { await log.find("page.crash", tab: a, after: crashMark) != nil }
            try await client.navigate(tab: a, url: base + "/a"); try await ready(a, "/a")
            try require(try await eval(a, "6*7") == .number(42), "Script failed after crash recovery")
            try await pixels(a, "recovered", "green", width: 640, height: 480)
            let recoveredMark = await log.count()
            _ = try await eval(a, "(yabMessage(JSON.stringify({n:44})),true)")
            try await eventually("binding after crash recovery") { await log.find("script.message", tab: a, after: recoveredMark)?.params["value"]?["n"] == .number(44) }
            pass("crash-recovery-and-binding-reattachment")
            // Keep an extension receipt as well as failing the job on regression.
            var extensionResult: [String: String] = [:]
            do {
                let management = try await client.createTab(profile: "space-a", url: "chrome://extensions/")
                try await eventually("extension management") {
                    let state = try await request("tab.state", management)
                    return state["url"].string?.hasPrefix("chrome://extensions") == true && state["loading"] == .bool(false) && state["hasDocument"] == .bool(true) && state["devToolsReady"] == .bool(true)
                }
                let before = try await request("extension.list", management)
                if case .array(let items) = before {
                    try require(!items.contains { $0["name"] == .string("YabCore Test") }, "Fixture was already loaded before IPC request")
                }
                let loaded = try await request("extension.load", management, ["path": .string(args[4])])
                extensionResult["dynamicLoad"] = String(describing: loaded)
                let list = try await request("extension.list", management)
                extensionResult["list"] = String(describing: list)
                guard case .array(let items) = list, let item = items.first(where: { $0["name"] == .string("YabCore Test") }), let extensionID = item["id"].string else { throw Failure(description: "Dynamically loaded extension absent from this profile's list") }
                _ = try await request("extension.setEnabled", management, ["extension": .string(extensionID), "enabled": .bool(false)])
                let disabled = try await request("extension.list", management)
                guard case .array(let disabledItems) = disabled else { throw Failure(description: "No extension list after disable") }
                try require(disabledItems.contains { $0["id"] == .string(extensionID) && $0["state"] == .string("DISABLED") }, "Extension did not disable")
                _ = try await request("extension.setEnabled", management, ["extension": .string(extensionID), "enabled": .bool(true)])
                let enabled = try await request("extension.list", management)
                guard case .array(let enabledItems) = enabled else { throw Failure(description: "No extension list after enable") }
                try require(enabledItems.contains { $0["id"] == .string(extensionID) && $0["state"] == .string("ENABLED") }, "Extension did not enable")
                _ = try await request("tab.reload", a)
                try await ready(a, "/a")
                try await eventually("extension content script") { try await eval(a, "document.documentElement.dataset.yabCoreExtension") == .string("loaded") }
                let otherManagement = try await client.createTab(profile: "space-b", url: "chrome://extensions/")
                try await eventually("other profile management") {
                    let state = try await request("tab.state", otherManagement)
                    return state["url"].string == "chrome://extensions/" && state["loading"] == .bool(false) && state["hasDocument"] == .bool(true) && state["devToolsReady"] == .bool(true)
                }
                let otherList = try await request("extension.list", otherManagement)
                guard case .array(let otherItems) = otherList else { throw Failure(description: "No extension list in other profile") }
                try require(!otherItems.contains { $0["id"] == .string(extensionID) }, "Extension leaked into another profile")
                _ = try await request("tab.reload", b)
                try await ready(b, "/b")
                try require(try await eval(b, "document.documentElement.dataset.yabCoreExtension??null") == .null, "Content script leaked into another profile")
                try await client.closeTab(otherManagement)
                extensionResult["otherProfile"] = "isolated"
                extensionResult["management"] = "passed"
                try await client.closeTab(management)
                pass("extension-dynamic-load-list-disable-enable-content-script")
                pass("extension-profile-isolation")
            } catch { extensionResult["managementError"] = String(describing: error) }
            try JSONSerialization.data(withJSONObject: extensionResult, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("extensions.json"))
            if let error = extensionResult["managementError"] { throw Failure(description: "Extensions: \(error)") }
            try await client.closeTab(secret); try await client.closeTab(b); try await client.closeTab(a)
            _ = try await client.request("shutdown")
            consumer.cancel()
            let rows = await log.all()
            let events = rows.map { row in JSONValue.object(["event": .string(row.name), "params": .object(row.params)]) }
            try JSONEncoder().encode(events).write(to: out.appendingPathComponent("events.json"))
            try JSONSerialization.data(withJSONObject: ["passed": checks], options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("summary.json"))
        } catch {
            let rows = await log.all()
            try? JSONEncoder().encode(rows.map { JSONValue.object(["event": .string($0.name), "params": .object($0.params)]) }).write(to: out.appendingPathComponent("events.json"))
            try? JSONSerialization.data(withJSONObject: ["passed": checks, "error": String(describing: error)], options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("summary.json"))
            await client.disconnect(); consumer.cancel(); throw error
        }
    }
}
