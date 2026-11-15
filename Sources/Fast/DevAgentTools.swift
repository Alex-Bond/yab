import Foundation

extension Tab {
    func devtoolsRead(_ kind: String, limit: Int = 100) -> [String: Any] {
        func safe(_ text: String) -> String {
            DevCopy.clean(text).replacingOccurrences(of: "(?i)(bearer\\s+)[A-Za-z0-9._~+/-]+", with: "$1[redacted]", options: .regularExpression)
                .replacingOccurrences(of: "(?i)((?:access_token|refresh_token|api_key|authorization|password|secret|session_token)[=:]\\s*)[^\\s&,;]+", with: "$1[redacted]", options: .regularExpression)
        }
        func url(_ text: String) -> String {
            guard var u = URLComponents(string: text) else { return "" }
            u.user = nil; u.password = nil; u.fragment = nil
            let hidden = ["token", "key", "auth", "secret", "password", "session", "signature", "code"]
            u.queryItems = u.queryItems?.map { item in hidden.contains(where: { item.name.lowercased().contains($0) }) ? URLQueryItem(name: item.name, value: "[redacted]") : item }
            return u.string ?? ""
        }
        let model = devModel(DevWorkbench.self)
        switch kind {
        case "devtools_comments":
            return ["comments": model.comments.map { ["url": url($0.url), "selector": safe($0.selector), "text": safe($0.text), "html": safe($0.html)] }]
        case "devtools_console":
            return ["messages": devModel(ConsoleLog.self).messages.suffix(limit).map { ["level": $0.level, "text": safe($0.words), "url": url($0.url), "line": $0.line, "count": $0.count] as [String: Any] }]
        case "devtools_network":
            return ["requests": netLog.rows.suffix(limit).map { ["url": url($0.url), "status": $0.status, "method": $0.method, "type": $0.resource.type] as [String: Any] }]
        case "devtools_trace":
            return ["recording": model.recording, "events": model.trace.suffix(limit).map { ["name": $0.name, "durationMs": $0.duration, "depth": $0.depth] as [String: Any] }]
        case "devtools_styles":
            return ["selectedNode": model.selectedNode, "styles": model.styles.map { ["selector": safe($0.selector), "declarations": safe($0.text)] }, "computed": model.computed.map { ["name": $0.name, "value": safe($0.value)] }]
        default: return ["error": "Unknown Developer Tools reader"]
        }
    }
}
