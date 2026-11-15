import AppKit

// Console and the card's shell for the bench: the probe's `dev.console`
// says what Console holds and shows, the drawer, the command menu and the
// protocol monitor; `{"do":"ui","console":{…}}` does what a hand would do,
// for evals/devmode/console_parity.py.

extension Browser {
    func consoleProbe() -> [String: Any] {
        guard let tab = toolsFront else { return [:] }
        let log = tab.devModel(ConsoleLog.self)
        let panel = consolePanel
        let prefs = ConsolePrefs.shared
        let shown = panel.shown(log)
        func value(_ v: ConsoleValue) -> [String: Any] {
            ["type": v.type, "subtype": v.subtype ?? "", "description": v.description ?? "", "text": ConsoleFormat.plainValue(v, top: false),
             "object": v.isObject, "objectId": v.objectId ?? "", "target": v.target, "string": v.string ?? "", "number": v.number.map { $0 as Any } ?? NSNull()]
        }
        func message(_ m: ConsoleMessage) -> [String: Any] {
            ["id": m.id, "kind": "\(m.kind)", "level": m.level, "type": m.type, "source": m.source, "text": m.text, "words": m.words,
             "url": m.url, "line": m.line, "count": m.count, "groups": m.groups, "values": m.values.map(value), "stack": m.stack.count,
             "place": m.place?.short ?? "", "target": m.target, "saved": m.saved]
        }
        let protocolLog = tab.devModel(ProtocolLog.self)
        return [
            "messages": log.messages.map(message),
            "errors": log.counts.errors, "warnings": log.counts.warnings,
            "shown": shown.map(\.id),
            "hidden": panel.hidden,
            "live": log.live.map { ["expression": $0.expression, "value": $0.value.map(value) ?? [:]] as [String: Any] },
            "contexts": log.contexts.map { ["id": $0.id, "title": $0.title, "type": $0.type, "on": $0.on] as [String: Any] },
            "filter": panel.filter.text, "group": panel.group.rawValue, "levels": prefs.levels.map(\.rawValue).sorted(),
            "levelsTitle": prefs.levelsTitle, "shut": Array(log.shut), "opened": Array(log.opened),
            "keepLog": prefs.keepLog, "networkMessages": prefs.networkMessages, "logXHR": prefs.logXHR, "eager": prefs.eager,
            "drawer": ["open": toolDrawer.open, "tool": toolDrawer.tool.rawValue, "tools": toolDrawer.tools.map(\.rawValue)] as [String: Any],
            "command": devCommand.query ?? NSNull(), "settings": devCommand.settings?.rawValue ?? NSNull(),
            "settingsWindow": devCommand.settingsWindow?.windowNumber ?? 0,
            "settingsParent": devCommand.settingsWindow?.parent?.windowNumber ?? 0,
            "devWindow": devWindow?.windowNumber ?? 0,
            "devSheet": devWindow?.attachedSheet?.windowNumber ?? 0,
            "settingsVisible": devCommand.settingsWindow?.isVisible ?? false,
            "protocol": ["recording": protocolLog.recording, "count": protocolLog.messages.count,
                         "methods": Array(protocolLog.messages.suffix(200).map(\.method))] as [String: Any],
            "history": Array(prefs.history.suffix(20)),
            "promptText": ConsolePromptView.latest?.string ?? "",
            "promptSize": ConsolePromptView.latest.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? [],
            "promptFocused": devWindow?.firstResponder is PromptTextView,
            "promptResponder": devWindow?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none",
            "promptWindow": ConsolePromptView.latest?.window?.windowNumber ?? 0,
            "browserWindow": BrowserWindows.shared.window(for: self)?.windowNumber ?? 0,
            "pageWindow": tab.builtPage?.window?.windowNumber ?? 0,
        ]
    }

    func consoleBench(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard let tab = toolsFront else { answer(["error": "no tab"]); return }
        let log = tab.devModel(ConsoleLog.self)
        let panel = consolePanel
        let prefs = ConsolePrefs.shared
        if Store.testing, let window = devWindow {
            if request["focusWindow"] as? Bool == true { window.makeFirstResponder(nil) }
            if request["focus"] as? Bool == true { ConsolePromptView.focusLatest(in: window) }
            if let text = request["type"] as? String {
                for character in text {
                    Bench.post(window, code: Bench.keyCode(for: character), chars: String(character), flags: [], queued: true)
                }
            }
            if let keys = request["key"] as? String, let (flags, name, typed) = Bench.chord(keys) {
                Bench.send(flags, name, typed, to: window, queued: true)
            }
        }
        if let text = request["run"] as? String { consoleRun(text) }
        if request["clear"] as? Bool == true { consoleClear() }
        if let text = request["filter"] as? String { panel.filter.text = text }
        if let levels = request["levels"] as? [String] { prefs.levels = Set(levels.compactMap(ConsoleLevel.init(rawValue:))) }
        if let name = request["group"] as? String, let group = ConsoleGroup(rawValue: name) { panel.group = group; panel.groupSource = request["source"] as? String }
        if let settings = request["prefs"] as? [String: Bool] {
            for (name, on) in settings {
                switch name {
                case "keepLog": prefs.keepLog = on
                case "networkMessages": prefs.networkMessages = on
                case "logXHR": prefs.logXHR = on; wire("console.prefs", ["xhr": on])
                case "eager": prefs.eager = on
                case "timestamps": prefs.timestamps = on
                case "groupSimilar": prefs.groupSimilar = on
                case "corsErrors": prefs.corsErrors = on
                case "selectedContextOnly": prefs.selectedContextOnly = on
                case "sidebar": prefs.sidebar = on
                default: break
                }
            }
        }
        if let list = request["live"] as? [String] {
            log.live = []
            list.forEach { log.addLive($0) }
            consoleLive()
        }
        if let title = request["context"] as? String, let context = log.contexts.first(where: { $0.title == title || "\($0.id)" == title }) { consoleSetContext(context) }
        if request["contexts"] as? Bool == true { consoleContexts() }
        if let id = request["shut"] as? Int { if log.shut.contains(id) { log.shut.remove(id) } else { log.shut.insert(id) } }
        if let words = request["prefill"] as? String { panel.prefill = words }
        if let on = request["copyPicker"] as? Bool { panel.copying = on }
        if let name = request["copyLit"] as? String, let way = ConsoleCopyWay(rawValue: name) { panel.copyLit = way }
        if let name = request["preview"] as? String, let way = ConsoleCopyWay(rawValue: name) {
            let shown = panel.shown(log)
            consoleObjectsJSON(shown) { json in
                let piece = way.text(shown, json: json, browser: self)
                answer(["text": piece, "lines": piece.isEmpty ? 0 : piece.split(separator: "\n", omittingEmptySubsequences: false).count, "bytes": piece.utf8.count, "messages": shown.count])
            }
            return
        }
        if let what = request["copy"] as? String {
            let shown = panel.shown(log)
            switch what {
            case "all": consoleCopyForAgent(shown)
            case "brief": consoleCopy(shown)
            case "details": consoleCopyDetails(shown)
            case "file": consoleSaveAndCopyPath(shown)
            default: if let id = Int(what), let m = log.messages.first(where: { $0.id == id }) { consoleCopyForAgent([m]) }
            }
        }
        // The shell: the drawer, the command menu, Settings, the monitor.
        if let what = request["drawer"] as? String {
            if what == "toggle" { toggleToolDrawer() } else if let tool = DevTool(rawValue: what) { showTool(tool) } else if what == "close" { toolDrawer.open = false }
        }
        if let query = request["command"] as? String { openDevCommand(query) }
        if request["commandClose"] as? Bool == true { devCommand.query = nil }
        if let title = request["runCommand"] as? String {
            guard let command = devCommands().first(where: { $0.title == title }) else { answer(["error": "no command " + title]); return }
            command.run()
        }
        if request["commands"] as? Bool == true {
            answer(["commands": devCommands().map { $0.category + ": " + $0.title }, "files": devFiles().map(\.url)])
            return
        }
        if let tab = request["settings"] as? String { devCommand.settings = tab == "close" ? nil : DevSettingsTab(rawValue: tab) }
        if let on = request["protocol"] as? Bool { protocolRecord(on) }
        // Asked of the inspector's page, its answer back: an object's
        // properties, names to complete, what eager evaluation says.
        if let props = request["props"] as? [String: Any], let id = props["message"] as? Int, let index = props["value"] as? Int {
            guard let m = log.messages.first(where: { $0.id == id }), m.values.indices.contains(index), let object = m.values[index].objectId else { answer(["error": "no object"]); return }
            wire("console.props", ["id": object, "tg": m.values[index].target]) { answer(["props": $0 ?? []]) }
            return
        }
        if let complete = request["complete"] as? [String: Any] {
            wire("console.complete", ["base": complete["base"] as? String ?? "", "prefix": complete["prefix"] as? String ?? "", "ctx": panel.context]) { answer(["names": $0 ?? []]) }
            return
        }
        if let text = request["eager"] as? String {
            guard ConsoleEager.safe(text) else { answer(["safe": false]); return }
            wire("console.eager", ["expr": text, "ctx": panel.context]) { raw in
                answer(["safe": true, "value": (raw as? [String: Any]).map { ConsoleFormat.plainValue(ConsoleValue(json: $0), top: false) } ?? NSNull()])
            }
            return
        }
        if let raw = request["wire"] as? [String: Any], let method = raw["method"] as? String {
            final class Why { var text: String? }
            let why = Why()
            wire(method, raw["params"] as? [String: Any] ?? [:], failed: { why.text = $0 }) { value in
                answer(why.text.map { ["error": $0] } ?? ["value": value ?? NSNull()])
            }
            return
        }
        answer(["ok": true])
    }
}
