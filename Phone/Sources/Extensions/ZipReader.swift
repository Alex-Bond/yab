import Compression
import Foundation

/// A zip, read whole from memory: what a Chrome extension's package is once
/// its signed header is off. iOS has no `ditto`, so the central directory
/// is read here and each file is stored or deflated (the only two methods a
/// store package uses), raw DEFLATE through Compression's zlib.
enum ZipReader {
    enum Failure: Error { case notZip, unsupported, corrupt, unsafePath }

    struct Entry {
        let path: String
        let method: UInt16
        let compressed: Int
        let size: Int
        let localOffset: Int
    }

    static func entries(_ data: Data) throws -> [Entry] {
        let b = [UInt8](data)
        // The end of central directory record: its signature within the last
        // 64 KB (a comment may follow it).
        guard b.count >= 22 else { throw Failure.notZip }
        var end = -1
        var i = b.count - 22
        let floor = max(0, b.count - 22 - 65_535)
        while i >= floor {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw Failure.notZip }
        let count = Int(u16(b, end + 10))
        var at = Int(u32(b, end + 16))
        var out: [Entry] = []
        for _ in 0..<count {
            guard at + 46 <= b.count, u32(b, at) == 0x0201_4b50 else { throw Failure.corrupt }
            let method = u16(b, at + 10)
            let compressed = Int(u32(b, at + 20)), size = Int(u32(b, at + 24))
            let nameLength = Int(u16(b, at + 28)), extra = Int(u16(b, at + 30)), comment = Int(u16(b, at + 32))
            let local = Int(u32(b, at + 42))
            guard at + 46 + nameLength <= b.count else { throw Failure.corrupt }
            let name = String(decoding: b[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            out.append(Entry(path: name, method: method, compressed: compressed, size: size, localOffset: local))
            at += 46 + nameLength + extra + comment
        }
        return out
    }

    /// Every file of the zip into `folder` (made here). A path that would
    /// land outside it, absolute or through "..", refuses the whole package.
    /// The check is on the entry's own words, never on the folder's path as
    /// the file system spells it: `standardizedFileURL` drops "/private" from
    /// a folder that exists but not from a file not written yet, and an
    /// iPhone's temporary folder (where every package is opened first) is
    /// under /private/var, so a path check refused every package there.
    static func unpack(_ data: Data, into folder: URL) throws {
        let b = [UInt8](data)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in try entries(data) {
            guard isSafe(entry.path) else { throw Failure.unsafePath }
            let target = folder.appendingPathComponent(entry.path)
            if entry.path.hasSuffix("/") {
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let at = entry.localOffset
            guard at + 30 <= b.count, u32(b, at) == 0x0403_4b50 else { throw Failure.corrupt }
            let start = at + 30 + Int(u16(b, at + 26)) + Int(u16(b, at + 28))
            guard start + entry.compressed <= b.count else { throw Failure.corrupt }
            let body = Data(b[start..<(start + entry.compressed)])
            let bytes: Data
            switch entry.method {
            case 0: bytes = body
            case 8: bytes = try inflate(body, size: entry.size)
            default: throw Failure.unsupported
            }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
    }

    /// Relative, forward slashes only, no step up and no NUL: it stays
    /// inside whatever folder it is written under. Entries are written as
    /// plain files and folders (never links), so nothing inside can point out.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: true).contains { $0 == ".." }
    }

    private static func inflate(_ body: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.corrupt }
        return out
    }

    private static func u16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
}
