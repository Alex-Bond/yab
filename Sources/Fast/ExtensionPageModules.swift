import Foundation
import CryptoKit

/// One module graph for adjacent entries in an extension page. WebKit can
/// run a second entry before their shared async dependency has finished,
/// exposing uninitialized exports (Vimium C's Option class, request #422).
/// WebKit: https://bugs.webkit.org/show_bug.cgi?id=242740
/// Static imports leave each module's URL, scope and dependency order intact.
enum ExtensionPageModules {
    nonisolated static func join(_ html: String, page: URL, folder: URL) throws -> String {
        // A base element changes HTML URL resolution, not module resolution.
        // Keep pages using one, async entries, inline scripts, and scripts
        // with integrity, handlers or other attributes exactly as supplied.
        guard html.range(of: "<base\\b", options: [.regularExpression, .caseInsensitive]) == nil else { return html }
        let root = folder.standardizedFileURL.path + "/"
        let canonicalRoot = folder.resolvingSymlinksInPath()
        func local(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { return false }
            let relative = String(path.dropFirst(root.count))
            return url.resolvingSymlinksInPath().path == canonicalRoot.appendingPathComponent(relative).path
        }
        guard local(page) else { return html }
        let pattern = #"(?is)<!--.*?-->|<script\b([^>]*)>\s*</script\s*>"#
        let tags = try NSRegularExpression(pattern: pattern)
        let attributes = try NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s'"=<>`]+))"#)
        let text = html as NSString
        var groups: [[(NSRange, String, String)]] = []
        var group: [(NSRange, String, String)] = []
        for match in tags.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            guard match.range(at: 1).location != NSNotFound else { continue }
            let raw = text.substring(with: match.range(at: 1)) as NSString
            let found = attributes.matches(in: raw as String, range: NSRange(location: 0, length: raw.length))
            var values: [String: String] = [:]
            var remainder = raw as String
            var valid = true
            for attribute in found.reversed() {
                let key = raw.substring(with: attribute.range(at: 1)).lowercased()
                let value = (2...4).first { attribute.range(at: $0).location != NSNotFound }!
                if values[key] != nil { valid = false }
                values[key] = raw.substring(with: attribute.range(at: value))
                remainder = (remainder as NSString).replacingCharacters(in: attribute.range, with: "")
            }
            let src = values["src"] ?? ""
            let allowed: Set<String> = ["type", "src", "blocking", "defer"]
            valid = valid && remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Set(values.keys).isSubset(of: allowed) && values["type"]?.lowercased() == "module"
                && !src.isEmpty && !src.hasPrefix("//") && !src.contains("&") && !src.contains("\\")
            let resolved = URL(string: src, relativeTo: page)?.absoluteURL
            // No remote, missing or symlinked package resources.
            if let resolved, resolved.isFileURL, resolved.query == nil, resolved.fragment == nil {
                let path = src.hasPrefix("/") ? folder.appendingPathComponent(String(src.dropFirst())) : resolved
                valid = valid && local(path)
                    && FileManager.default.fileExists(atPath: path.path)
            } else { valid = false }
            let extras = values.filter { $0.key != "src" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let gap = group.last.map { text.substring(with: NSRange(location: NSMaxRange($0.0), length: match.range.location - NSMaxRange($0.0))) } ?? ""
            if !valid || !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || group.last.map({ $0.2 != extras }) == true {
                if group.count > 1 { groups.append(group) }
                group = []
            }
            if valid { group.append((match.range, src, extras)) }
        }
        if group.count > 1 { groups.append(group) }
        var result = html
        for (index, group) in groups.enumerated().reversed() {
            let key = SHA256.hash(data: Data(page.lastPathComponent.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let name = "yab-modules-\(key)-\(index).js"
            let target = page.deletingLastPathComponent().appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            let imports = try group.map { entry -> String in
                let src = entry.1.hasPrefix("/") || entry.1.hasPrefix("./") || entry.1.hasPrefix("../") ? entry.1 : "./" + entry.1
                let json = try JSONSerialization.data(withJSONObject: [src], options: [.withoutEscapingSlashes])
                let array = String(decoding: json, as: UTF8.self)
                return "import " + array.dropFirst().dropLast() + ";"
            }.joined(separator: "\n") + "\n"
            try imports.write(to: target, atomically: true, encoding: .utf8)
            let first = group[0].0
            let original = text.substring(with: first)
            let replacement = try NSRegularExpression(pattern: #"(?i)(\bsrc\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s'"=<>`]+)"#)
                .stringByReplacingMatches(in: original, range: NSRange(location: 0, length: (original as NSString).length), withTemplate: "$1\"\(name)\"")
            let last = group.last!.0
            result = (result as NSString).replacingCharacters(in: NSRange(location: first.location, length: NSMaxRange(last) - first.location), with: replacement)
        }
        return result
    }
}
