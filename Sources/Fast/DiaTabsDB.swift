import CommonCrypto
import CryptoKit
import Foundation
import os
import SQLite3

// Dia's sidebar as Dia keeps it now: each profile's tabs.db, a SQLCipher 4
// database, its favorites, its pinned tabs in their folders and folders in
// folders, and what each window has open, groups and all. Dia's scripting
// has no folders, so read that way every pinned tab came flat (Horizon S
// on X, 2026-10-16: "Pinned › Basics, VUE, ICCWIN" came as one list).
//
// The key, as Dia makes it (docs/evidence/dia-folders-2026-10-17):
//
//     root    = PBKDF2-HMAC-SHA1(Dia Safe Storage, "saltysalt", 1003, 16)
//     context = "profile/<profile folder>/tabs"
//     salt    = HMAC-SHA256(key: 32 bytes Dia's executable holds as base64, context)
//     key     = HKDF-SHA256(root, salt, info: context, 32 bytes)
//
// The 32 bytes are found by trying each base64 literal of that length in
// Dia's executable against the database's first page, never by a version's
// file offset, so a Dia that moves it still opens. Anything that doesn't
// add up, no keychain answer, no literal that opens the first page, a page
// whose HMAC is wrong, tables of a shape this doesn't know, gives nil, and
// the import goes on as before: Dia's scripting, then its files.
//
// Read only: Dia's files are read into memory, the database put together
// with its WAL there, decrypted there and opened there (sqlite3_deserialize).
// Nothing decrypted is written anywhere.

enum DiaTabsDB {
    /// Every profile's places, each Dia space one, Default first, or nil
    /// when the database can't be read. `ask`: Bring In was pressed, so the
    /// keychain may ask about Dia's key; otherwise only a quiet read.
    static func places(_ source: Chromium.Source, ask: Bool) -> [TabImport.Place]? {
        let order = TabImport.profileOrder(in: source)
        let folders = order.isEmpty ? source.profiles.map(\.lastPathComponent) : order
        let files = folders.compactMap { folder -> (String, URL)? in
            let file = source.root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("tabs.db")
            return FileManager.default.fileExists(atPath: file.path) ? (folder, file) : nil
        }
        // No database, no keychain asked.
        guard !files.isEmpty, let executable = source.app.flatMap({ Bundle(url: $0)?.executableURL }) else { return nil }
        let literals = constants(in: executable)
        guard !literals.isEmpty, let passphrase = Chromium.safeStorage(source, quiet: !ask) else { return nil }
        let root = Chromium.stretch(passphrase)
        let names = TabImport.profileNames(in: source)
        var places: [TabImport.Place] = []
        for (folder, file) in files {
            guard let plain = open(file, context: "profile/\(folder)/tabs", root: root, constants: literals),
                  let spaces = sidebar(plain) else { return nil }
            places += self.places(spaces, folder: folder, names: names)
        }
        guard places.contains(where: { !$0.isEmpty }) else { return nil }
        return DiaContainers.adding(order, names: names, to: places)
    }

    // MARK: - the sidebar

    /// One of Dia's spaces, what its sidebar shows.
    struct Space: Equatable {
        var id: String
        var title: String
        /// The row of icons at the top.
        var favorites: [TabImport.Entry] = []
        /// Pinned, above the line, in their folders.
        var pinned: [TabImport.Entry] = []
        /// What its windows have open, below the line; a group's tabs
        /// with the group's name.
        var open: [TabImport.Entry] = []
        var splits: [TabImport.Split] = []
    }

    /// A profile's spaces as places: the first one is the profile, as
    /// Dia's scripting and its file brought it ("Dia:Profile 1"), so a
    /// second Bring In finds the space it made; others after it.
    static func places(_ spaces: [Space], folder: String, names: [String: String]) -> [TabImport.Place] {
        spaces.enumerated().map { index, space in
            var seen = Set<String>()
            let first = index == 0
            return TabImport.Place(
                id: first ? "Dia:" + folder : "Dia:\(folder):\(space.id)",
                name: first && spaces.count == 1 ? (names[folder] ?? space.title) : space.title,
                profile: folder, shared: folder == "Default", isProfile: first,
                pinned: TabImport.once(space.favorites, seen: &seen),
                kept: TabImport.once(space.pinned, seen: &seen),
                open: TabImport.once(space.open, seen: &seen),
                splits: space.splits)
        }
    }

    /// A decrypted tabs.db's spaces, or nil for tables of a shape this
    /// doesn't know. Live nodes only: a closed window, a deleted folder,
    /// Dia's "Cleaned up" groups stay behind.
    static func sidebar(_ plain: Data) -> [Space]? {
        guard let db = memory(plain) else { return nil }
        defer { sqlite3_close(db) }
        guard let nodes = rows(db, "SELECT id, kind, entity_id, parent_id, \"order\", space_id FROM nodes WHERE deleted_at IS NULL"),
              let groups = rows(db, "SELECT node_id, title FROM tab_groups"),
              let panes = rows(db, "SELECT node_id, custom_title, id FROM content_panes"),
              let pages = rows(db, "SELECT c.node_id, w.url, w.title FROM web_contents w JOIN content_panes c ON c.id = w.content_pane_id ORDER BY w.id"),
              let titled = rows(db, "SELECT id, title FROM spaces ORDER BY creation_date, id")
        else { return nil }

        struct Node { let id: Int64; let kind: String; let parent: Int64?; let order: Int64; let space: String }
        var children: [Int64?: [Node]] = [:]
        for row in nodes {
            guard let id = row[0].int, let kind = row[1].text else { continue }
            let node = Node(id: id, kind: kind, parent: row[3].int, order: row[4].int ?? 0, space: row[5].text ?? "")
            children[node.parent, default: []].append(node)
        }
        for key in children.keys { children[key]?.sort { ($0.order, $0.id) < ($1.order, $1.id) } }
        var folderName: [Int64: String] = [:]
        for row in groups { if let id = row[0].int { folderName[id] = row[1].text } }
        var renamed: [Int64: String] = [:]
        for row in panes {
            if let id = row[0].int, let name = row[1].text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { renamed[id] = name }
        }
        // A pane's page: its last web contents.
        var shown: [Int64: (String, String)] = [:]
        for row in pages { if let id = row[0].int, let url = row[1].text { shown[id] = (url, row[2].text ?? "") } }

        var visited = Set<Int64>()
        var splits: [TabImport.Split] = []
        func walk(_ parent: Int64, path: [String]) -> [TabImport.Entry] {
            // Nodes name their parents; a loop in a damaged file stops here.
            guard path.count < 32, visited.insert(parent).inserted else { return [] }
            var found: [TabImport.Entry] = []
            for node in children[parent] ?? [] {
                switch node.kind {
                case "tab":
                    // A tab of two panes is a split: both pages, side by side.
                    let made = (children[node.id] ?? []).filter { $0.kind == "content_pane" }.compactMap { pane -> TabImport.Entry? in
                        guard let (url, title) = shown[pane.id], var entry = TabImport.entry(url, title) else { return nil }
                        if let name = renamed[pane.id], name != title { entry.name = name }
                        entry.folder = path.isEmpty ? nil : path.joined(separator: " › ")
                        entry.path = path.count > 1 ? path : nil
                        return entry
                    }
                    if made.count == 2, made[0].url != made[1].url { splits.append(TabImport.Split(first: made[0].url, second: made[1].url)) }
                    found += made
                case "group":
                    let name = (folderName[node.id]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Folder"
                    found += walk(node.id, path: path + [name])
                default:
                    continue
                }
            }
            return found
        }

        // Each space's three parts: the nodes at the top, which say whose
        // space they are; their order is the space's.
        var spaces: [Space] = titled.compactMap { row in row[0].text.map { Space(id: $0, title: row[1].text ?? "Dia") } }
        for top in children[nil] ?? [] where ["favorites", "pinned_container", "window"].contains(top.kind) {
            if !spaces.contains(where: { $0.id == top.space }) { spaces.append(Space(id: top.space, title: "Dia")) }
            let at = spaces.firstIndex { $0.id == top.space }!
            splits = []
            switch top.kind {
            case "favorites":
                spaces[at].favorites += walk(top.id, path: []).map { entry in
                    var entry = entry
                    entry.folder = nil
                    entry.path = nil
                    return entry
                }
            case "pinned_container": spaces[at].pinned += walk(top.id, path: [])
            default: spaces[at].open += walk(top.id, path: [])
            }
            spaces[at].splits += splits
        }
        return spaces
    }

    // MARK: - the key

    /// Dia's 32-byte literals, base64 in its executable, read once a build.
    private static let found = OSAllocatedUnfairLock<[String: [Data]]>(initialState: [:])

    static func constants(in executable: URL) -> [Data] {
        let stamp = (try? executable.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])).map {
            "\(executable.path)|\($0.fileSize ?? 0)|\($0.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        } ?? executable.path
        if let known = found.withLock({ $0[stamp] }) { return known }
        guard let data = try? Data(contentsOf: executable, options: .alwaysMapped) else { return [] }
        let literals = constants(inBytes: data)
        found.withLock { $0[stamp] = literals }
        return literals
    }

    /// Every C string of 43 base64 characters and "=", which is 32 bytes.
    static func constants(inBytes data: Data) -> [Data] {
        var out: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            func letter(_ c: UInt8) -> Bool {
                (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2B || c == 0x2F
            }
            var at = 43
            while at + 1 < count {
                // Each "=" from here on, by memchr.
                guard let hit = memchr(base + at, 0x3D, count - at - 1) else { break }
                let equals = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                at = equals + 1
                guard equals >= 43, base[equals + 1] == 0 else { continue }
                let start = equals - 43
                if start > 0, letter(base[start - 1]) || base[start - 1] == 0x3D { continue }
                var all = true
                for i in start..<equals where !letter(base[i]) { all = false; break }
                guard all, let text = String(bytes: UnsafeBufferPointer(start: base + start, count: 44), encoding: .ascii),
                      let value = Data(base64Encoded: text), value.count == 32, !out.contains(value) else { continue }
                out.append(value)
            }
        }
        return out
    }

    /// The database's raw SQLCipher key for one context.
    static func key(root: [UInt8], context: String, constant: Data) -> [UInt8] {
        let info = Data(context.utf8)
        let salt = Data(HMAC<SHA256>.authenticationCode(for: info, using: SymmetricKey(data: constant)))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), salt: salt, info: info, outputByteCount: 32)
        return key.withUnsafeBytes { Array($0) }
    }

    // MARK: - SQLCipher 4, read

    /// tabs.db and its WAL as they are now, decrypted: the WAL read on
    /// both sides of the database so a checkpoint between them is seen
    /// and read again.
    static func open(_ file: URL, context: String, root: [UInt8], constants: [Data]) -> Data? {
        let walFile = URL(fileURLWithPath: file.path + "-wal")
        for _ in 0..<3 {
            let before = try? Data(contentsOf: walFile)
            guard let db = try? Data(contentsOf: file) else { return nil }
            let wal = try? Data(contentsOf: walFile)
            guard before == wal else { continue }
            for constant in constants {
                if let plain = decrypt(db: db, wal: wal, key: key(root: root, context: context, constant: constant)) { return plain }
            }
            return nil
        }
        return nil
    }

    /// The pages SQLCipher 4 writes: from the first page's sixteen bytes of
    /// salt on, AES-256-CBC, each page ending in its IV and an HMAC-SHA512
    /// of the page, IV and page number, keyed by PBKDF2-HMAC-SHA512 of the
    /// key over the salt XOR 0x3a, twice. Nil for a key that doesn't open
    /// the first page, or any page that doesn't check.
    static func decrypt(db: Data, wal: Data?, key: [UInt8]) -> Data? {
        for size in [4096, 8192, 16384, 1024, 2048, 32768, 65536] {
            let pages = merged(db: db, wal: wal, size: size)
            guard let first = pages.first, first.count == size else { continue }
            let salt = Array(first.prefix(16))
            let hmacKey = pbkdf2(key, salt: salt.map { $0 ^ 0x3A }, rounds: 2)
            guard let opened = page(first, number: 1, key: key, hmacKey: hmacKey) else { continue }
            // The header says the page size it was written in.
            let said = Int(opened[16]) << 8 | Int(opened[17])
            guard (said == 1 ? 65536 : said) == size else { continue }
            var plain = Data(capacity: pages.count * size)
            plain.append(contentsOf: opened)
            for (index, raw) in pages.enumerated().dropFirst() {
                guard let opened = page(raw, number: UInt32(index + 1), key: key, hmacKey: hmacKey) else { return nil }
                plain.append(contentsOf: opened)
            }
            // A WAL database's header, read from memory: as a rollback
            // journal's, or SQLite looks for a WAL beside it.
            plain[18] = 1
            plain[19] = 1
            return plain
        }
        return nil
    }

    static let reserve = 80

    private static func page(_ raw: Data, number: UInt32, key: [UInt8], hmacKey: [UInt8]) -> [UInt8]? {
        let bytes = [UInt8](raw)
        let size = bytes.count
        let offset = number == 1 ? 16 : 0
        let end = size - reserve
        guard end > offset else { return nil }
        var signed = Array(bytes[offset..<(end + 16)])
        withUnsafeBytes(of: number.littleEndian) { signed.append(contentsOf: $0) }
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA512), hmacKey, hmacKey.count, signed, signed.count, &mac)
        guard mac == Array(bytes[(end + 16)..<(end + 80)]) else { return nil }
        let iv = Array(bytes[end..<(end + 16)])
        let body = Array(bytes[offset..<end])
        var out = [UInt8](repeating: 0, count: body.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                             key, key.count, iv, body, body.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved == body.count else { return nil }
        var opened = [UInt8](repeating: 0, count: size)
        if number == 1 { opened.replaceSubrange(0..<16, with: Array("SQLite format 3\0".utf8)) }
        opened.replaceSubrange(offset..<end, with: out)
        return opened
    }

    private static func pbkdf2(_ key: [UInt8], salt: [UInt8], rounds: UInt32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        key.withUnsafeBufferPointer { k in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     UnsafeRawPointer(k.baseAddress!).assumingMemoryBound(to: Int8.self), key.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds, &out, out.count)
        }
        return out
    }

    /// The database's pages, still encrypted, with the WAL's committed
    /// frames over them: frames whose salts match the WAL's header and
    /// whose running checksums hold, up to the last commit.
    static func merged(db: Data, wal: Data?, size: Int) -> [Data] {
        var pages: [Data] = stride(from: 0, to: db.count - db.count % size, by: size).map { db.subdata(in: $0..<($0 + size)) }
        guard let wal, wal.count >= 32 + 24 + size else { return pages }
        let w = [UInt8](wal)
        func big(_ at: Int) -> UInt32 { UInt32(w[at]) << 24 | UInt32(w[at + 1]) << 16 | UInt32(w[at + 2]) << 8 | UInt32(w[at + 3]) }
        let magic = big(0)
        guard magic == 0x377F0682 || magic == 0x377F0683, Int(big(8)) == size || (big(8) == 1 && size == 65536) else { return pages }
        let bigWords = magic & 1 == 1
        func sum(_ s: (UInt32, UInt32), _ from: Int, _ count: Int) -> (UInt32, UInt32) {
            var (a, b) = s
            var at = from
            while at < from + count {
                let x = bigWords ? big(at) : UInt32(w[at]) | UInt32(w[at + 1]) << 8 | UInt32(w[at + 2]) << 16 | UInt32(w[at + 3]) << 24
                let y = bigWords ? big(at + 4) : UInt32(w[at + 4]) | UInt32(w[at + 5]) << 8 | UInt32(w[at + 6]) << 16 | UInt32(w[at + 7]) << 24
                a = a &+ x &+ b
                b = b &+ y &+ a
                at += 8
            }
            return (a, b)
        }
        var check = sum((0, 0), 0, 24)
        guard check == (big(24), big(28)) else { return pages }
        let salts = (big(16), big(20))
        var pending: [(Int, Data)] = []
        var at = 32
        while at + 24 + size <= w.count {
            guard (big(at + 8), big(at + 12)) == salts else { break }
            check = sum(sum(check, at, 8), at + 24, size)
            guard check == (big(at + 16), big(at + 20)) else { break }
            let number = Int(big(at))
            guard number > 0 else { break }
            pending.append((number, wal.subdata(in: (at + 24)..<(at + 24 + size))))
            let commit = Int(big(at + 4))
            if commit > 0 {
                for (number, data) in pending {
                    while pages.count < number { pages.append(Data(count: size)) }
                    pages[number - 1] = data
                }
                pending = []
                if pages.count > commit { pages.removeLast(pages.count - commit) }
            }
            at += 24 + size
        }
        return pages
    }

    // MARK: - SQLite, in memory

    private static func memory(_ plain: Data) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        guard let buffer = sqlite3_malloc64(sqlite3_uint64(plain.count)) else { sqlite3_close(db); return nil }
        plain.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: plain.count)
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
        guard sqlite3_deserialize(db, "main", buffer.assumingMemoryBound(to: UInt8.self),
                                  sqlite3_int64(plain.count), sqlite3_int64(plain.count), flags) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    enum Value {
        case int(Int64), text(String), null
        var int: Int64? { if case .int(let v) = self { return v }; if case .text(let t) = self { return Int64(t) }; return nil }
        var text: String? { if case .text(let t) = self { return t }; if case .int(let v) = self { return String(v) }; return nil }
    }

    private static func rows(_ db: OpaquePointer, _ sql: String) -> [[Value]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var out: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            out.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
                case SQLITE_NULL: return .null
                default: return sqlite3_column_text(statement, column).map { Value.text(String(cString: $0)) } ?? Value.null
                }
            })
        }
        return out
    }
}
