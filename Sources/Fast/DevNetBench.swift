import AppKit

// Network for the bench (DevNet.swift): the probe's `dev.net` says what the
// panel holds and shows, and `{"do":"ui","net":{…}}` does what a hand would
// do in it, for evals/devmode/network_parity.py.

extension Browser {
    /// The log of the tab in front and the panel over it.
    func netProbe() -> [String: Any] {
        guard let tab = active else { return [:] }
        let log = tab.netLog
        let panel = netPanel
        let prefs = NetPrefs.shared
        let origin = log.origin ?? 0
        let shown = panel.shown(log, page: tab.address)
        return [
            "rows": log.rows.map { row -> [String: Any] in
                var out: [String: Any] = [
                    "id": row.id, "resource": row.resource.id, "url": row.url, "method": row.method, "status": row.status,
                    "statusLabel": row.statusLabel, "statusText": row.statusText, "type": row.typeLabel, "kind": row.resource.type,
                    "category": row.category.rawValue, "transferred": row.transferred, "size": row.size,
                    "time": row.duration ?? -1, "start": (row.span.start - origin) * 1000,
                    "initiator": row.initiatorLabel.place, "initiatorKind": row.initiatorLabel.kind,
                    "initiatorResource": row.resource.initiator.resource ?? -1, "stack": row.resource.initiator.stack.count,
                    "proto": row.resource.proto, "remote": row.resource.remote, "priority": row.resource.priority,
                    "connection": row.resource.connection, "source": row.resource.source, "hop": row.hop ?? -1,
                    "pending": row.pending, "failed": row.failed, "failure": row.resource.failure,
                    "frames": row.resource.frames.count, "events": row.resource.events.count,
                    "throttled": row.resource.throttledBy ?? "", "blocked": row.resource.blockedBy ?? "",
                    "requestHeaders": row.requestHeaders.map { [$0.name, $0.value] },
                    "responseHeaders": row.responseHeaders.map { [$0.name, $0.value] },
                    "postData": row.resource.postData ?? "", "frame": row.resource.frame,
                    "security": row.resource.security,
                ]
                if let phases = row.phases {
                    out["phases"] = Dictionary(uniqueKeysWithValues: NetPhases.Phase.allCases.map { ($0.rawValue, phases.value($0)) })
                }
                return out
            },
            "shown": shown.map(\.id),
            "selected": panel.selected ?? -1,
            "detail": panel.detail.rawValue,
            // The picked row's body, as Preview and Response show it.
            "body": panel.selected.flatMap { id in log.rows.first { $0.id == id } }.flatMap { row -> [String: Any]? in
                guard let body = log.bodies[row.resource.id] else { return nil }
                let pretty = Store.settings.object(forKey: NetPretty.key) as? Bool ?? true
                let shown = body.base64 ? "" : pretty ? (NetPretty.auto(body.text, mime: row.resource.mime.lowercased()) ?? body.text) : body.text
                return ["preview": NetPreviewKind.of(row, body).rawValue, "base64": body.base64, "pretty": pretty,
                        "shown": String(shown.prefix(800)), "lines": shown.split(separator: "\n", omittingEmptySubsequences: false).count]
            } ?? [:],
            "recording": log.recording,
            "unavailable": log.unavailable,
            "contentLoaded": log.contentLoaded.map { ($0 - origin) * 1000 } ?? -1,
            "loaded": log.loaded.map { ($0 - origin) * 1000 } ?? -1,
            "shots": log.shots.count,
            "bodies": log.bodies.count,
            "keepLog": prefs.keepLog, "noCache": prefs.noCache, "throttle": prefs.throttle,
            "rules": prefs.rules.map { [$0.pattern, $0.condition, $0.on ? "on" : "off"] }, "rulesOn": prefs.rulesOn,
            "warns": prefs.warns,
            "search": panel.searchOpen, "query": panel.query, "found": Array(panel.found(log)),
            "searchHits": panel.query.isEmpty ? 0 : NetSearchSide.search(panel.query, in: log, matchCase: panel.matchCase, regex: panel.regex).count,
            "drawer": panel.drawer?.rawValue ?? "",
            "columns": prefs.columns,
            "filterActive": panel.filter.isActive,
            "sort": panel.sort.map { [$0.column, $0.ascending ? "ascending" : "descending"] } ?? [],
            "overridden": panel.overridden,
            "ticks": Browser.netTicks,
            "laid": Double(panel.laid), "room": Double(panel.room),
            "splits": panel.splits.mapValues(Double.init),
        ]
    }

    /// One thing done in the panel, as a hand would; the answer says what
    /// came of it where there is something to say.
    func netBench(_ ask: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard let tab = toolsFront else { answer(["error": "no page"]); return }
        let log = tab.netLog
        let panel = netPanel
        let prefs = NetPrefs.shared
        if !devOpen { openDevTools(.network) } else if devPane != .network { pickDevPane(.network) }
        func row(_ key: String) -> NetRow? {
            if let id = ask[key] as? Int { return log.rows.first { $0.id == id } }
            if let end = ask[key] as? String { return log.rows.last { $0.url.hasSuffix(end) } }
            return panel.selected.flatMap { id in log.rows.first { $0.id == id } }
        }
        if ask["select"] is NSNull { panel.selected = nil } else if ask["select"] != nil { panel.selected = row("select")?.id }
        if let name = ask["detail"] as? String, let detail = NetDetailTab(rawValue: name) { panel.detail = detail }
        if let on = ask["pretty"] as? Bool { Store.settings.set(on, forKey: NetPretty.key) }
        if let text = ask["filter"] as? String { panel.filter.text = text }
        if let invert = ask["invert"] as? Bool { panel.filter.invert = invert }
        if let types = ask["types"] as? [String] { panel.filter.types = Set(types.compactMap(NetCategory.init)) }
        if let more = ask["more"] as? [String: Bool] {
            panel.filter.hideData = more["data"] ?? panel.filter.hideData
            panel.filter.hideExtensions = more["extensions"] ?? panel.filter.hideExtensions
            panel.filter.onlyBlocked = more["blocked"] ?? panel.filter.onlyBlocked
            panel.filter.onlyThirdParty = more["third"] ?? panel.filter.onlyThirdParty
        }
        if ask["range"] is NSNull { panel.filter.range = nil }
        if let range = ask["range"] as? [Double], range.count == 2, let origin = log.origin { panel.filter.range = (origin + range[0] / 1000)...(origin + range[1] / 1000) }
        if let on = ask["record"] as? Bool { log.recording = on }
        if ask["clear"] as? Bool == true { netClear() }
        if let on = ask["keep"] as? Bool { prefs.keepLog = on }
        if let on = ask["nocache"] as? Bool { prefs.noCache = on }
        if let id = ask["throttle"] as? String { prefs.throttle = id }
        if let rule = ask["rule"] as? [String: Any], let pattern = rule["pattern"] as? String {
            prefs.rules.append(NetPrefs.Rule(on: rule["on"] as? Bool ?? true, pattern: pattern, condition: rule["condition"] as? String ?? "block"))
        }
        if ask["rules"] as? [Any] != nil, (ask["rules"] as? [Any])?.isEmpty == true { prefs.rules = [] }
        if let on = ask["rulesOn"] as? Bool { prefs.rulesOn = on }
        if let agent = ask["userAgent"] as? String { prefs.userAgent = agent.isEmpty ? nil : agent }
        if let save = ask["saveData"] as? String { prefs.saveData = save == "default" ? nil : save }
        if let query = ask["search"] as? String { panel.searchOpen = true; panel.query = query }
        if ask["search"] is NSNull { panel.searchOpen = false }
        if let drawer = ask["drawer"] as? String { panel.drawer = NetDrawer(rawValue: drawer) }
        if let column = ask["sort"] as? String { panel.sort = column.isEmpty ? nil : NetSort(column: column, ascending: ask["ascending"] as? Bool ?? true) }
        if let columns = ask["columns"] as? [String] { prefs.columns = columns }
        if let on = ask["big"] as? Bool { prefs.bigRows = on }
        if let on = ask["group"] as? Bool { prefs.groupByFrame = on }
        if let on = ask["overview"] as? Bool { prefs.overview = on }
        if let on = ask["screenshots"] as? Bool { prefs.screenshots = on }
        if let on = ask["filterBar"] as? Bool { panel.filterBar = on }
        if let on = ask["settings"] as? Bool { panel.settingsOpen = on }
        if ask["splits"] is NSNull { panel.splits = [:] }

        // What answers later or with something to say.
        if let format = ask["copy"] as? String, let row = row("row") {
            let rows = panel.shown(log, page: tab.address)
            switch format {
            case "url": copyForAgent(row.url, "Copied URL")
            case "curl": copyForAgent(NetCopy.curl(row), "Copied as cURL")
            case "powershell": copyForAgent(NetCopy.powerShell(row), "Copied as PowerShell")
            case "fetch": copyForAgent(NetCopy.fetch(row, node: false), "Copied as fetch")
            case "fetch-node": copyForAgent(NetCopy.fetch(row, node: true), "Copied as fetch (Node.js)")
            case "preload": copyForAgent(NetCopy.preload(row) ?? "", "Copied as preload element")
            case "request-headers": copyForAgent(NetCopy.headers(row.requestHeaders), "Copied request headers")
            case "response-headers": copyForAgent(NetCopy.headers(row.responseHeaders), "Copied response headers")
            case "agent": netCopyForAgent([row]); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { answer(["copied": Browser.benchCopied]) }; return
            case "har", "har-sensitive":
                netHAR(rows, sanitized: format == "har") { text in
                    self.copyForAgent(text, "Copied as HAR")
                    answer(["copied": Browser.benchCopied])
                }
                return
            case "response":
                netBody(row) { body in answer(["copied": body.text, "base64": body.base64, "error": body.error ?? ""]) }
                return
            default: break
            }
            answer(["copied": Browser.benchCopied])
            return
        }
        if ask["menu"] != nil, let row = row("menu") {
            let menu = netRowMenu(row, shown: panel.shown(log, page: tab.address))
            func titles(_ menu: NSMenu) -> [Any] {
                menu.items.map { item -> Any in
                    if item.isSeparatorItem { return "-" }
                    if let sub = item.submenu { return [item.title: titles(sub)] }
                    return item.isEnabled ? item.title : "(" + item.title + ")"
                }
            }
            answer(["menu": titles(menu)])
            return
        }
        if ask["headMenu"] as? Bool == true {
            answer(["menu": netHeadMenu().items.map { $0.isSeparatorItem ? "-" : ($0.state == .on ? "✓ " : "") + $0.title }])
            return
        }
        if ask["resend"] as? Bool == true, let row = row("row") { netResend(row) }
        if let headers = ask["overrideHeaders"] as? [String: String], let row = row("row") { netOverrideHeaders(row, headers) }
        if ask["overrideContent"] as? Bool == true, let row = row("row") { netOverrideContent(row) }
        if let path = ask["exportHar"] as? String {
            netHAR(panel.shown(log, page: tab.address), sanitized: ask["sanitized"] as? Bool ?? true) { text in
                try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
                answer(["written": path])
            }
            return
        }
        if let path = ask["importHar"] as? String {
            guard let data = FileManager.default.contents(atPath: path), let resources = NetHAR.resources(from: data) else { answer(["error": "unreadable"]); return }
            log.bring(resources)
            answer(["imported": resources.count])
            return
        }
        if ask["bodies"] as? Bool == true {
            netLoadBodies(log.rows.filter { $0.hop == nil && $0.finished && !$0.failed }, limit: 400) { _ in answer(["bodies": log.bodies.count]) }
            return
        }
        if let js = ask["bridge"] as? String {
            netRun(js) { answer(["value": $0.map { "\($0)" } ?? ""]) }
            return
        }
        answer(["ok": true])
    }
}
