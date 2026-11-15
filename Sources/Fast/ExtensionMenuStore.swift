import Foundation
import CoreFoundation

/// Static menu definitions only. Older stores may contain selected words,
/// so they are discarded rather than migrated to this format.
enum ExtensionMenuStore {
    static let limit = 64
    static let byteLimit = 128 * 1024
    private static let fields: Set<String> = [
        "id", "title", "type", "contexts", "parentId", "checked", "enabled", "visible",
        "documentUrlPatterns", "targetUrlPatterns",
    ]

    static func encode(_ text: String, version: String) -> String? {
        guard let items = items(text) else { return nil }
        return json(["schema": 1, "version": version, "items": items])
    }

    static func decode(_ text: String, version: String) -> String? {
        guard text.utf8.count <= byteLimit,
              let data = text.data(using: .utf8),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              saved["schema"] as? Int == 1, saved["version"] as? String == version,
              let list = saved["items"], let text = json(list), let items = items(text) else { return nil }
        return json(items)
    }

    private static func items(_ text: String) -> [[Any]]? {
        guard text.utf8.count <= byteLimit,
              let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return nil }
        var kept: [[Any]] = []
        var seen: Set<String> = []
        for pair in list {
            guard pair.count == 2, let key = identity(pair[0]),
                  var props = pair[1] as? [String: Any] else { return nil }
            guard seen.insert(key).inserted else { continue }
            props = props.filter { fields.contains($0.key) }
            props["id"] = pair[0]
            kept.append([pair[0], props])
            if kept.count == limit { break }
        }
        return kept
    }

    private static func identity(_ id: Any) -> String? {
        if let text = id as? String { return "s:" + text }
        if let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite { return "n:" + number.stringValue }
        return nil
    }

    private static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              data.count <= byteLimit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
