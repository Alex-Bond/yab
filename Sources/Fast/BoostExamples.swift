import Foundation

/// A deliberately small YAML subset: a sequence of ask/tool/args mappings.
/// args uses JSON (also valid YAML). No aliases, tags or executable fixtures.
struct BoostExample: Equatable {
    let ask: String
    let tool: String
    let arguments: String

    static func read(_ source: String?, tools: [BoostPlugin.Tool]) throws -> [BoostExample] {
        guard let source else { return [] }
        guard source.utf8.count <= 32_000 else { throw BoostPackage.Invalid("evals.yaml exceeds 32 KB.") }
        var rows: [[String: String]] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let first = line.hasPrefix("- ")
            let content = first ? String(line.dropFirst(2)) : line
            guard let colon = content.firstIndex(of: ":"), first || raw.hasPrefix("  ") else { throw BoostPackage.Invalid("Use a YAML list of ask, tool and args in evals.yaml.") }
            if first { rows.append([:]) }
            let key = String(content[..<colon])
            let value = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !rows.isEmpty, rows.count <= 20, ["ask", "tool", "args"].contains(key), rows[rows.count - 1][key] == nil, !value.isEmpty else { throw BoostPackage.Invalid("Invalid or duplicate eval field.") }
            let decoded: String
            if key != "args", value.hasPrefix("\"") {
                guard let text = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else { throw BoostPackage.Invalid("Quote eval text with JSON double quotes.") }
                decoded = text
            } else { decoded = value }
            rows[rows.count - 1][key] = decoded
        }
        return try rows.map { row in
            guard let ask = row["ask"], !ask.isEmpty, ask.count <= 1000,
                  let name = row["tool"], let tool = tools.first(where: { $0.name == name }),
                  let args = row["args"], let object = try JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any] else { throw BoostPackage.Invalid("Each eval needs an ask, a declared tool and JSON object args.") }
            try tool.validate(object)
            return Self(ask: ask, tool: name, arguments: BoostScript.json(object))
        }
    }
}
