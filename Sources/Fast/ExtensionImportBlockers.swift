import Foundation

// What an ad blocker kept in the other browser that people lose when they
// move: the sites where blocking is off, and the hiding rules they made
// (docs/ad-blocker-source.md, Bring In). Read from the profile's
// `Local Extension Settings/<id>`, chrome.storage.local, a LevelDB folder:
// its log of recent writes and its tables, whose blocks are sometimes
// Snappy-compressed. Copied as read, never written; Chrome may be open.
//
// What each keeps where is read loosely, since every blocker files it its
// own way: uBlock Origin's "netWhitelist", uBlock Origin Lite's
// "filteringModeDetails" (its "none" sites), and in any value, lines a
// filter list would hold: "@@||site^$document" (allowed) and
// "site##selector" (hidden).

/// A blocker's sites and hiding rules, from another browser.
struct BlockerKept: Hashable {
    /// Sites with blocking off.
    var sites: [String] = []
    /// Hiding rules: the site, and what is hidden there.
    var hiding: [Hide] = []
    /// Its own blocking rules, which stay where they are.
    var blocking = 0

    struct Hide: Hashable {
        let host: String
        let selector: String
    }

    var isEmpty: Bool { sites.isEmpty && hiding.isEmpty }

    /// "With its 12 trusted sites and 8 hiding rules."
    var line: String { "With its \(BlockerWords.brought(sites.count, hiding.count))." }

    /// What a profile's copy of this extension kept, or nil for none.
    static func read(_ id: String, in profile: URL) -> BlockerKept? {
        let folder = profile.appendingPathComponent("Local Extension Settings", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        let values = LevelDB.read(folder)
        guard !values.isEmpty else { return nil }
        let kept = from(values)
        return kept.isEmpty && kept.blocking == 0 ? nil : kept
    }

    /// From chrome.storage.local's keys and their JSON values.
    static func from(_ values: [String: Data]) -> BlockerKept {
        var sites = Set<String>()
        var hiding: [Hide] = []
        var seen = Set<Hide>()
        var blocking = 0
        for (key, raw) in values {
            let text = String(decoding: raw, as: UTF8.self)
            let value = (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]))
            switch key {
            case "netWhitelist":
                // uBlock Origin: one a line, a site, a page or a pattern.
                let lines = (value as? String).map { $0.components(separatedBy: "\n") } ?? (value as? [String]) ?? []
                for line in lines { if let host = plainHost(line) { sites.insert(host) } }
                continue
            case "filteringModeDetails":
                // uBlock Origin Lite: sites by filtering mode, "none" off.
                if let modes = value as? [String: Any], let none = modes["none"] as? [String] {
                    for line in none { if let host = plainHost(line) { sites.insert(host) } }
                }
                continue
            default:
                break
            }
            for line in lines(of: value ?? text) {
                let line = line.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
                if let host = allowedSite(line) {
                    sites.insert(host)
                } else if let hides = hidingRule(line) {
                    for hide in hides where seen.insert(hide).inserted { hiding.append(hide) }
                } else if isBlockingRule(line) {
                    blocking += 1
                }
            }
        }
        return BlockerKept(sites: sites.sorted(), hiding: hiding, blocking: blocking)
    }

    /// Every string in a value, split into lines: filter texts are kept as
    /// one string, or as arrays of them.
    private static func lines(of value: Any) -> [String] {
        switch value {
        case let text as String:
            return text.contains("\n") || text.contains("##") || text.hasPrefix("@@") || text.hasPrefix("||")
                ? text.components(separatedBy: .newlines) : []
        case let list as [Any]:
            return list.flatMap { lines(of: $0) }
        case let map as [String: Any]:
            return map.values.flatMap { lines(of: $0) }
        default:
            return []
        }
    }

    /// "@@||example.com^$document" and its kin: the whole site allowed.
    static func allowedSite(_ line: String) -> String? {
        guard line.hasPrefix("@@||"), let dollar = line.lastIndex(of: "$") else { return nil }
        let options = line[line.index(after: dollar)...].split(separator: ",").map(String.init)
        guard options.contains(where: { ["document", "doc", "all"].contains($0) }) else { return nil }
        let body = line.dropFirst(4)[..<dollar]
        let host = body.prefix { $0 != "^" && $0 != "/" && $0 != "*" && $0 != "|" && $0 != "$" }
        guard body.dropFirst(host.count).allSatisfy({ $0 == "^" || $0 == "|" }) else { return nil }
        return plainHost(String(host))
    }

    /// "example.com,www.example.com##.banner": the sites, less "~" ones,
    /// each with the selector. Generic ("##.ad"), exception ("#@#") and
    /// script rules ("##+js") aren't hiding Yab can take.
    static func hidingRule(_ line: String) -> [Hide]? {
        guard let mark = line.range(of: "##") else { return nil }
        let head = line[..<mark.lowerBound], selector = line[mark.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !selector.isEmpty, !selector.hasPrefix("+js"), !selector.hasPrefix("^"),
              !head.contains("#"), !head.contains("$") else { return nil }
        let hosts = head.split(separator: ",").map(String.init).filter { !$0.hasPrefix("~") }.compactMap(plainHost)
        return hosts.isEmpty ? nil : hosts.map { Hide(host: $0, selector: selector) }
    }

    /// A network rule of its own: "||ads.example^", "/banner/*$image".
    static func isBlockingRule(_ line: String) -> Bool {
        guard !line.hasPrefix("@@"), !line.contains("##"), !line.contains("#@#"), !line.contains("#?#") else { return false }
        return line.hasPrefix("||") || line.hasPrefix("|http") || (line.contains("$") && !line.contains(" "))
    }

    /// A site's name alone, as Yab keeps them: lowercased, no "www.", no
    /// scheme or path; nil for a pattern.
    static func plainHost(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let url = URL(string: text), let host = url.host(), url.scheme != nil { text = host }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        guard text.contains("."), text.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil,
              !text.hasPrefix("."), !text.hasSuffix(".") else { return nil }
        return text
    }
}

/// A LevelDB folder read whole: every key's latest value, deletions
/// applied. Only what chrome.storage.local needs: the log's write batches
/// and the tables' data blocks, plain or Snappy-compressed.
enum LevelDB {
    static func read(_ folder: URL) -> [String: Data] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var latest: [Data: (sequence: UInt64, value: Data?)] = [:]
        func note(_ key: Data, _ sequence: UInt64, _ value: Data?) {
            if let seen = latest[key], seen.sequence > sequence { return }
            latest[key] = (sequence, value)
        }
        for name in names.sorted() {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { continue }
            if name.hasSuffix(".ldb") || name.hasSuffix(".sst") {
                for (key, value) in table(data) {
                    // A table's key ends in 8 bytes: sequence << 8 | kind.
                    guard key.count >= 8 else { continue }
                    let tail = key.suffix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                    let user = Data(key.prefix(key.count - 8))
                    note(user, tail >> 8, (tail & 0xff) == 1 ? value : nil)
                }
            } else if name.hasSuffix(".log") {
                for batch in log(data) {
                    for (sequence, key, value) in entries(batch) { note(key, sequence, value) }
                }
            }
        }
        var out: [String: Data] = [:]
        for (key, item) in latest {
            guard let value = item.value, let name = String(data: key, encoding: .utf8) else { continue }
            out[name] = value
        }
        return out
    }

    // MARK: the log

    /// The log's records, reassembled from its 32 KB blocks.
    static func log(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var records: [Data] = []
        var partial = Data()
        var at = 0
        let block = 32768
        while at + 7 <= bytes.count {
            let left = block - at % block
            if left < 7 { at += left; continue }
            let length = Int(bytes[at + 4]) | Int(bytes[at + 5]) << 8
            let kind = bytes[at + 6]
            let start = at + 7
            guard start + length <= bytes.count else { break }
            let piece = Data(bytes[start..<(start + length)])
            switch kind {
            case 1: records.append(piece); partial = Data()
            case 2: partial = piece
            case 3: partial.append(piece)
            case 4: partial.append(piece); records.append(partial); partial = Data()
            default: break
            }
            at = start + length
            if kind == 0 && length == 0 { at += left - 7 }
        }
        return records
    }

    /// A write batch: its first sequence number, then puts and deletes.
    static func entries(_ batch: Data) -> [(UInt64, Data, Data?)] {
        let bytes = [UInt8](batch)
        guard bytes.count >= 12 else { return [] }
        var sequence = bytes[0..<8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        var at = 12
        var out: [(UInt64, Data, Data?)] = []
        while at < bytes.count {
            let kind = bytes[at]
            at += 1
            guard let keyLength = varint(bytes, &at), at + keyLength <= bytes.count else { break }
            let key = Data(bytes[at..<(at + keyLength)])
            at += keyLength
            if kind == 1 {
                guard let valueLength = varint(bytes, &at), at + valueLength <= bytes.count else { break }
                out.append((sequence, key, Data(bytes[at..<(at + valueLength)])))
                at += valueLength
            } else {
                out.append((sequence, key, nil))
            }
            sequence += 1
        }
        return out
    }

    // MARK: the tables

    /// Every key and value in a table's data blocks.
    static func table(_ data: Data) -> [(Data, Data)] {
        let bytes = [UInt8](data)
        guard bytes.count >= 48 else { return [] }
        var at = bytes.count - 48
        guard varint64(bytes, &at) != nil, varint64(bytes, &at) != nil,
              let indexOffset = varint(bytes, &at), let indexSize = varint(bytes, &at),
              let index = block(bytes, offset: indexOffset, size: indexSize)
        else { return [] }
        var out: [(Data, Data)] = []
        for (_, handle) in entries(block: index) {
            var place = 0
            let handleBytes = [UInt8](handle)
            guard let offset = varint(handleBytes, &place), let size = varint(handleBytes, &place),
                  let data = block(bytes, offset: offset, size: size) else { continue }
            out += entries(block: data)
        }
        return out
    }

    /// A block's contents, uncompressed when its trailer says Snappy.
    static func block(_ bytes: [UInt8], offset: Int, size: Int) -> [UInt8]? {
        guard offset >= 0, size >= 0, offset + size + 5 <= bytes.count else { return nil }
        let raw = Array(bytes[offset..<(offset + size)])
        switch bytes[offset + size] {
        case 0: return raw
        case 1: return Snappy.decompress(raw)
        default: return nil
        }
    }

    /// A block's entries, each key shared in part with the one before.
    static func entries(block: [UInt8]) -> [(Data, Data)] {
        guard block.count >= 4 else { return [] }
        let restarts = Int(block[block.count - 4]) | Int(block[block.count - 3]) << 8 | Int(block[block.count - 2]) << 16 | Int(block[block.count - 1]) << 24
        let end = block.count - 4 - 4 * restarts
        guard end >= 0 else { return [] }
        var at = 0
        var key = [UInt8]()
        var out: [(Data, Data)] = []
        while at < end {
            guard let shared = varint(block, &at), let unshared = varint(block, &at), let valueLength = varint(block, &at),
                  shared <= key.count, at + unshared + valueLength <= end else { break }
            key = Array(key.prefix(shared)) + block[at..<(at + unshared)]
            at += unshared
            out.append((Data(key), Data(block[at..<(at + valueLength)])))
            at += valueLength
        }
        return out
    }

    static func varint(_ bytes: [UInt8], _ at: inout Int) -> Int? {
        varint64(bytes, &at).flatMap { $0 <= UInt64(Int.max) ? Int($0) : nil }
    }

    static func varint64(_ bytes: [UInt8], _ at: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while at < bytes.count, shift < 64 {
            let byte = bytes[at]
            at += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}

/// Snappy's raw format, decompressing only.
enum Snappy {
    static func decompress(_ input: [UInt8]) -> [UInt8]? {
        var at = 0
        guard let length = LevelDB.varint(input, &at), length < 64 << 20 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(length)
        while at < input.count {
            let tag = input[at]
            at += 1
            switch tag & 3 {
            case 0:
                var count = Int(tag >> 2)
                if count >= 60 {
                    let extra = count - 59
                    guard at + extra <= input.count else { return nil }
                    count = 0
                    for index in 0..<extra { count |= Int(input[at + index]) << (8 * index) }
                    at += extra
                }
                count += 1
                guard at + count <= input.count else { return nil }
                out += input[at..<(at + count)]
                at += count
            case 1:
                guard at < input.count else { return nil }
                let count = 4 + Int((tag >> 2) & 7)
                let offset = Int(tag >> 5) << 8 | Int(input[at])
                at += 1
                guard copy(&out, offset: offset, count: count) else { return nil }
            case 2:
                guard at + 2 <= input.count else { return nil }
                let count = 1 + Int(tag >> 2)
                let offset = Int(input[at]) | Int(input[at + 1]) << 8
                at += 2
                guard copy(&out, offset: offset, count: count) else { return nil }
            default:
                guard at + 4 <= input.count else { return nil }
                let count = 1 + Int(tag >> 2)
                let offset = Int(input[at]) | Int(input[at + 1]) << 8 | Int(input[at + 2]) << 16 | Int(input[at + 3]) << 24
                at += 4
                guard copy(&out, offset: offset, count: count) else { return nil }
            }
        }
        return out.count == length ? out : nil
    }

    private static func copy(_ out: inout [UInt8], offset: Int, count: Int) -> Bool {
        guard offset > 0, offset <= out.count else { return false }
        let start = out.count - offset
        for index in 0..<count { out.append(out[start + index]) }
        return true
    }
}
