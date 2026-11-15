import AppKit

/// Isolated acceptance only; the ordinary bench keeps its existing behavior.
@MainActor
enum ChromiumDRMBench {
    static func respond(_ request: [String: Any], tab: Tab?, answer: @escaping ([String: Any]) -> Void) {
        if Store.testing, request["op"] as? String == "switch-isolation" {
            answer(["isolated": Store.websites.identifier == Store.probeStore(1)])
            return
        }
        if Store.testing, request["op"] as? String == "global-engine", let raw = request["engine"] as? String,
           let kind = PageEngineKind(rawValue: raw) {
            do {
                try EngineSwitchGlobal.choose(kind)
                answer(["engine": kind.rawValue, "tabs": BrowserWindows.shared.browsers.flatMap(\.everyTab).filter { !$0.gone }.map {
                    ["id": $0.id.uuidString, "engine": $0.engineKind.rawValue, "sleeping": $0.builtPage == nil] as [String: Any]
                }])
            } catch { answer(["error": String(describing: error)]) }
            return
        }
        guard Store.testing, let tab else { answer(["error": "DRM probe needs an isolated test tab"]); return }
        if request["op"] as? String == "reload" {
            tab.reload()
            answer(["ok": true])
            return
        }
        if request["op"] as? String == "windows" {
            // This process's windows on screen (menus and popovers included), for a picture by window number.
            let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
            answer(["windows": mine.map { entry -> [String: Any] in
                let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
                return ["number": entry[kCGWindowNumber as String] ?? 0, "layer": entry[kCGWindowLayer as String] ?? 0,
                        "name": entry[kCGWindowName as String] ?? "", "bounds": bounds]
            }])
            return
        }
        if request["op"] as? String == "site-engine" {
            if let raw = request["choice"] as? String {
                guard let choice = SiteEngineChoice(rawValue: raw) else { answer(["error": "Unknown site engine choice"]); return }
                Task { @MainActor in
                    do {
                        try await tab.setSiteEngineChoice(choice)
                        answer(siteEngineState(tab))
                    } catch { answer(["error": String(describing: error)]) }
                }
            } else { answer(siteEngineState(tab)) }
            return
        }
        let page = tab.page
        if request["op"] as? String == "extension-install", let path = request["path"] as? String, let web = page.webKit {
            Task { @MainActor in
                do {
                    // This explicit isolated install opts into Chromium. A
                    // normal WK view no longer starts a native bridge eagerly.
                    let bridge = try tab.chromiumDRMExtensions ?? ChromiumDRMExtensions(tab: tab, web: web)
                    tab.chromiumDRMExtensions = bridge
                    answer(["extensions": try await bridge.installForTesting(path: path)])
                } catch { answer(["error": String(describing: error)]) }
            }
            return
        }
        if request["op"] as? String == "extension-script", let id = request["extension"] as? String, let body = request["body"] as? String, let bridge = tab.chromiumDRMExtensions {
            Task { @MainActor in
                do { answer(["value": try await bridge.inspectForTesting(id, frame: request["frame"] as? Int ?? 0, body: body)]) }
                catch { answer(["error": String(describing: error)]) }
            }
            return
        }
        if request["op"] as? String == "cookies", let url = tab.address {
            Task { @MainActor in
                do { answer(["checks": try await ChromiumDRMCookies.of(tab).roundTripForTesting(at: url)]) }
                catch { answer(["error": String(describing: error)]) }
            }
            return
        }
        if request["op"] as? String == "script" {
            page.call(request["body"] as? String ?? "return document.title", in: .page) { result in
                switch result {
                case .success(let value): answer(["value": value ?? NSNull()])
                case .failure(let error): answer(["error": String(describing: error)])
                }
            }
            return
        }
        answer(["engine": tab.engineKind.rawValue, "tab": tab.id.uuidString,
                "url": page.url?.absoluteString ?? "", "title": page.title ?? "",
                "loading": page.isLoading, "window": page.window?.windowNumber ?? 0,
                "context": (page as? ChromiumPage)?.contextID ?? 0,
                "diagnosticFailure": (page as? ChromiumPage)?.diagnosticFailure ?? "",
                "failure": tab.failure ?? ""])
    }

    /// The persisted choice, the live engine, and what the panel's row says.
    private static func siteEngineState(_ tab: Tab) -> [String: Any] {
        var out: [String: Any] = ["choice": tab.siteEngineChoice.rawValue, "engine": tab.engineKind.rawValue,
                                  "tab": tab.id.uuidString, "recommended": tab.recommendedSiteEngine.rawValue,
                                  "offered": tab.offersSiteEngine]
        out["foot"] = tab.engineFoot ?? ""
        out["actions"] = tab.engineActionTitles
        if let row = tab.siteEngineRowFacts { out["row"] = ["title": row.title, "said": row.said, "chosen": row.chosen] }
        return out
    }
}
