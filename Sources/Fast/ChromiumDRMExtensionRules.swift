import Foundation
import YabCoreClient

/// A bounded DNR adapter. Reuses the existing rule normalization and splitting.
/// Unsupported semantics fail explicitly, before replacing the installed list.
enum ChromiumDRMExtensionRules {
    static func rules(entry: [String: Any], snapshot: [String: Any]) throws -> [[String: Any]] {
        let manifest = entry["manifest"] as? [String: Any] ?? [:]
        let files = entry["files"] as? [String: String] ?? [:]
        let enabled = Set(snapshot["enabled"] as? [String] ?? [])
        var input = (snapshot["dynamic"] as? [[String: Any]] ?? []) + (snapshot["session"] as? [[String: Any]] ?? [])
        for resource in (manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [[String: Any]] ?? [] {
            guard let id = resource["id"] as? String, enabled.contains(id), let path = resource["path"] as? String,
                  let source = files[path], let data = source.data(using: .utf8), let rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            input += rules
        }
        let types = ["main_frame": "document", "sub_frame": "document", "stylesheet": "style-sheet", "script": "script", "image": "image", "font": "font", "media": "media", "xmlhttprequest": "fetch", "ping": "ping", "websocket": "websocket", "other": "other"]
        input = input.map { ExtensionRuleMends.mend($0, file: { _ in nil }) ?? $0 }
        if let split = ExtensionRuleMends.split(input) as? [[String: Any]] { input = split }
        let grants = entry["grants"] as? [String] ?? []
        let domains = try grants.map { pattern -> String in
            if pattern == "<all_urls>" || pattern == "*://*/*" { return ".*" }
            guard let sep = pattern.range(of: "://"), let slash = pattern[sep.upperBound...].firstIndex(of: "/") else { throw YabCoreError.remote("Unsupported DNR host grant") }
            let host = String(pattern[sep.upperBound..<slash])
            let scheme = String(pattern[..<sep.lowerBound])
            let path = NSRegularExpression.escapedPattern(for: String(pattern[slash...])).replacingOccurrences(of: "\\*", with: ".*")
            let hostRegex = host == "*" ? "[^/]+" : host.hasPrefix("*.") ? "([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: String(host.dropFirst(2))) : NSRegularExpression.escapedPattern(for: host)
            return "^" + (scheme == "*" ? "https?" : scheme) + "://" + hostRegex + "(:[0-9]+)?" + path
        }
        var result: [[String: Any]] = []
        // WebKit's ignore-previous-rules order represents DNR priority locally.
        for rule in input.sorted(by: { (($0["priority"] as? Int ?? 1), ($0["action"] as? [String: Any])?["type"] as? String == "allow" ? 1 : 0) < (($1["priority"] as? Int ?? 1), ($1["action"] as? [String: Any])?["type"] as? String == "allow" ? 1 : 0) }) {
            let condition = rule["condition"] as? [String: Any] ?? [:], action = rule["action"] as? [String: Any] ?? [:]
            let supported: Set<String> = ["urlFilter", "regexFilter", "isUrlFilterCaseSensitive", "resourceTypes", "excludedResourceTypes", "domainType"]
            guard Set(condition.keys).isSubset(of: supported), ["block", "allow", "upgradeScheme"].contains(action["type"] as? String ?? "") else { throw YabCoreError.remote("DNR rule needs an unsupported WebKit request condition or action") }
            let filter: String
            if let regex = condition["regexFilter"] as? String { filter = ExtensionRuleMends.uncaptured(regex) }
            else { filter = urlFilter(condition["urlFilter"] as? String ?? "*") }
            var trigger: [String: Any] = ["url-filter": filter, "url-filter-is-case-sensitive": condition["isUrlFilterCaseSensitive"] as? Bool ?? false]
            if !domains.contains(".*") { trigger["if-top-url"] = domains }
            if let domainType = condition["domainType"] as? String { trigger["load-type"] = [domainType == "thirdParty" ? "third-party" : "first-party"] }
            if let domains = condition["initiatorDomains"] as? [String] { trigger["if-domain"] = domains.map { "*" + $0 } }
            if let domains = condition["excludedInitiatorDomains"] as? [String] { trigger["unless-domain"] = domains.map { "*" + $0 } }
            if let resources = condition["resourceTypes"] as? [String] {
                guard resources.allSatisfy({ types[$0] != nil }), !(resources.contains("main_frame") != resources.contains("sub_frame")) else { throw YabCoreError.remote("DNR frame resource type needs native request filtering") }
                trigger["resource-type"] = Array(Set(resources.compactMap { types[$0] }))
            }
            if condition["excludedResourceTypes"] != nil { throw YabCoreError.remote("DNR excluded resource types need native request filtering") }
            let type = action["type"] as? String ?? ""
            result.append(["trigger": trigger, "action": ["type": type == "allow" ? "ignore-previous-rules" : type == "upgradeScheme" ? "make-https" : "block"]])
        }
        return result.isEmpty ? [["trigger": ["url-filter": "^https://yab-dnr-empty.invalid/$"], "action": ["type": "block"]]] : result
    }
    static func urlFilter(_ value: String) -> String {
        var body = value
        var start = "", end = ""
        if body.hasPrefix("||") { start = "^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+\\.)?"; body.removeFirst(2) }
        else if body.hasPrefix("|") { start = "^"; body.removeFirst() }
        if body.hasSuffix("|") { end = "$"; body.removeLast() }
        return start + body.map { character -> String in
            if character == "*" { return ".*" }
            if character == "^" { return "([^a-zA-Z0-9_.%-]|$)" }
            return NSRegularExpression.escapedPattern(for: String(character))
        }.joined() + end
    }
}
