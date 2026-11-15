import Foundation

// Who issued a card, from its first six digits: the bank and the card's
// level, "Chase", "Capital One · World". Read from a table that ships with
// the app (Resources/bins.dat, packed by Resources/bins-pack.py from
// venelinkochev/bin-list-data, CC-BY-4.0), so a card's number never leaves
// this Mac to be looked up. The table is about a megabyte, deflated, and is
// read the first time a card is saved or shown, off the main thread.

enum Bins {
    struct Found: Equatable {
        /// "Chase", or empty when the table doesn't say.
        let issuer: String
        /// "Signature", "World Elite", "Business", or empty for the plain ones.
        let level: String
        let credit: Bool?
    }

    static func lookup(_ digits: String) -> Found? {
        guard digits.count >= 6, let bin = UInt32(digits.prefix(6)), let table else { return nil }
        var low = 0, high = table.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let at = table.bin(mid)
            if at == bin {
                let row = table.row(mid)
                return Found(issuer: table.issuers[Int(row.issuer)], level: table.levels[Int(row.level)],
                             credit: row.kind == 1 || row.kind == 3 ? true : row.kind == 2 ? false : nil)
            }
            if at < bin { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    private struct Table {
        let issuers: [String]
        let levels: [String]
        let records: Data
        let count: Int

        func bin(_ i: Int) -> UInt32 {
            records.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self) }
        }

        func row(_ i: Int) -> (issuer: UInt16, level: UInt8, kind: UInt8) {
            records.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt16.self),
                 $0.load(fromByteOffset: i * 8 + 6, as: UInt8.self),
                 $0.load(fromByteOffset: i * 8 + 7, as: UInt8.self))
            }
        }
    }

    private static let table: Table? = {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let places = [Bundle.main.resourceURL?.appendingPathComponent("bins.dat"), repo.appendingPathComponent("Resources/bins.dat")]
        guard let file = places.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let packed = try? Data(contentsOf: file),
              let raw = try? (packed as NSData).decompressed(using: .zlib) as Data
        else { return nil }
        return read(raw)
    }()

    /// "BIN1", the issuers and the levels as length-prefixed strings, then
    /// eight bytes a BIN: the number, the issuer, the level, the kind.
    private static func read(_ raw: Data) -> Table? {
        guard raw.prefix(4) == Data("BIN1".utf8) else { return nil }
        var at = 4
        func u32() -> Int? {
            guard at + 4 <= raw.count else { return nil }
            defer { at += 4 }
            return Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) })
        }
        func strings() -> [String]? {
            guard let count = u32() else { return nil }
            var out: [String] = []
            out.reserveCapacity(count)
            for _ in 0..<count {
                guard at + 2 <= raw.count else { return nil }
                let length = Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self) })
                at += 2
                guard at + length <= raw.count else { return nil }
                out.append(String(decoding: raw[raw.startIndex + at ..< raw.startIndex + at + length], as: UTF8.self))
                at += length
            }
            return out
        }
        guard let issuers = strings(), let levels = strings(), let count = u32(), at + count * 8 <= raw.count else { return nil }
        return Table(issuers: issuers, levels: levels, records: raw.subdata(in: raw.startIndex + at ..< raw.startIndex + at + count * 8), count: count)
    }
}
