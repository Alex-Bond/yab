import CryptoKit
import Foundation

/// Media and diff helpers shared by live agent chats.
enum AgentLines {
    static let pasteMark = "\u{1E}"

    /// An image sent inline, kept as a file by what it holds, once.
    private static var kept: [String: String] = [:]
    private static let keptLock = NSLock()

    static func keep(_ base64: String, in folder: URL?) -> String? {
        // Read again as a chat grows: known by its size and ends, never decoded and hashed twice.
        let key = "\(base64.count):\(base64.prefix(64)):\(base64.suffix(64))"
        keptLock.lock()
        let known = kept[key]
        keptLock.unlock()
        if let known, folder.map({ known.hasPrefix($0.path) }) ?? false { return known }
        guard let made = keepNew(base64, in: folder) else { return nil }
        keptLock.lock()
        if kept.count > 4000 { kept.removeAll() }
        kept[key] = made
        keptLock.unlock()
        return made
    }

    private static func keepNew(_ base64: String, in folder: URL?) -> String? {
        guard let folder, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), data.count < 8_000_000 else { return nil }
        let name = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
        let file = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file)
        }
        return file.path
    }

    static func lineCount(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// A path as Codex wrote it, maybe as a file URL, as a path.
    static func localPath(_ path: String) -> String {
        guard path.hasPrefix("file://") else { return path }
        if let url = URL(string: path), url.isFileURL { return url.path(percentEncoded: false) }
        let bare = String(path.dropFirst("file://".count))
        return bare.removingPercentEncoding ?? bare
    }

    /// A unified diff's lines added and taken out.
    static func counts(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

}
