import AppKit
import os

// copy: what an agent put on the clipboard for you. Words ("Copy all the
// emails on this page"), a link that pastes as its title where a page takes
// rich text (a link to a paragraph is a #:~:text= address), or a file of
// its task's folder, the file itself as Finder copies one. Under the answer
// the chat says "Copied · 14 addresses" and Copy Again (⌘C) puts it back,
// from the clip kept here. Plan: docs/agent-asks.md.

struct AgentClip: Codable, Equatable {
    var id: String
    var text: String?
    var url: String?
    var title: String?
    var file: String?
    /// What it is, in words: "14 addresses", "Link to Room for ambition".
    var what: String
    var at = Date()

    /// The most text a clip takes.
    static let limit = 2 << 20

    enum Trouble: Error, Equatable {
        case nothing, two, tooBig, badLink, quoteNeedsPage, noFile(String), outside(String), folder(String)

        var said: String {
            switch self {
            case .nothing: "copy needs text, url or file"
            case .two: "copy takes one of text, url or file"
            case .tooBig: "copy takes up to 2 MB of text: save it with save_file instead"
            case .badLink: "copy's url must be a whole http(s) or mailto: address"
            case .quoteNeedsPage: "quote makes a link to a paragraph of a web page: url must be http(s)"
            case .noFile(let path): "no file at \(path)"
            case .outside(let path): "copy gives the clipboard files of this task's folder only (save_page, save_file and download put them there), and \(path) isn't in it"
            case .folder(let name): "\(name) is a folder"
            }
        }
    }

    /// A clip from what copy was given; `folder` is the task's, the only
    /// place a file may come from.
    static func make(text: String?, url: String?, title: String?, quote: String?, file: String?, what: String?,
                     folder: URL?) throws(Trouble) -> AgentClip {
        let given = [text, url, file].compactMap { $0 }.filter { !$0.isEmpty }
        guard !given.isEmpty else { throw .nothing }
        guard given.count == 1 else { throw .two }
        let said = what.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }.flatMap { $0.isEmpty ? nil : $0 }
        let id = String(UUID().uuidString.lowercased().prefix(8))
        if let text, !text.isEmpty {
            guard text.utf8.count <= limit else { throw .tooBig }
            return AgentClip(id: id, text: text, what: said ?? words(text))
        }
        if let url, !url.isEmpty {
            guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = parsed.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { throw .badLink }
            var address = parsed.absoluteString
            if let quote, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard scheme != "mailto" else { throw .quoteNeedsPage }
                address = fragment(address, quote: quote)
            }
            let named = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            let place = named ?? parsed.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? address
            return AgentClip(id: id, url: address, title: named, what: said ?? ((quote?.isEmpty ?? true) ? "Link to " + place : "Link to the paragraph"))
        }
        let path = (AgentLines.localPath(file ?? "") as NSString).expandingTildeInPath
        let real = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDir) else { throw .noFile(path) }
        guard let folder, real.path.hasPrefix(folder.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { throw .outside(path) }
        guard !isDir.boolValue else { throw .folder(real.lastPathComponent) }
        return AgentClip(id: id, file: real.path, what: said ?? real.lastPathComponent)
    }

    /// What a text is, said shortly: itself when short and one line,
    /// else how many lines or words.
    static func words(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count > 1 { return SaveFile.plural(lines.count, "line") }
        let one = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if one.count <= 40 { return one }
        return SaveFile.plural(one.split(whereSeparator: \.isWhitespace).count, "word")
    }

    /// The address of a paragraph on a page: `#:~:text=` with the quote,
    /// its first and last words for a long one, the standard text-fragment
    /// form. Major browsers and Yab scroll to it and mark it.
    static func fragment(_ address: String, quote: String) -> String {
        let said = quote.split(whereSeparator: \.isWhitespace).map(String.init)
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~")
        func encoded(_ words: ArraySlice<String>) -> String {
            words.joined(separator: " ").addingPercentEncoding(withAllowedCharacters: ascii) ?? ""
        }
        let directive = said.count > 8 ? encoded(said.prefix(4)) + "," + encoded(said.suffix(4)) : encoded(said[...])
        // A fragment already there keeps its place; an old text one goes.
        var base = address
        if let old = base.range(of: ":~:") { base = String(base[..<old.lowerBound]) }
        if base.hasSuffix("#") { base.removeLast() }
        return base + (base.contains("#") ? ":~:text=" : "#:~:text=") + directive
    }

    /// Onto a pasteboard: words as words; a link as its address, and as
    /// its title linked where rich text is taken; a file as the file.
    func put(on board: NSPasteboard) {
        board.clearContents()
        if let file {
            board.writeObjects([URL(fileURLWithPath: file) as NSURL])
            return
        }
        if let url {
            let item = NSPasteboardItem()
            item.setString(url, forType: .string)
            item.setString(url, forType: .URL)
            if let title, let link = URL(string: url) {
                item.setString(title, forType: NSPasteboard.PasteboardType("public.url-name"))
                let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                let href = url.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                item.setString("<a href=\"\(href)\">\(escaped)</a>", forType: .html)
                let rich = NSAttributedString(string: title, attributes: [.link: link])
                if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
                    item.setData(rtf, forType: .rtf)
                }
            }
            board.writeObjects([item])
            return
        }
        board.setString(text ?? "", forType: .string)
    }

    /// The answer copy gives the agent; ChatItem.copied reads its first
    /// line. The clip's id stays Yab's (`recent`): an agent echoes what it
    /// is told, and an id has no place in its answer or the corner's line.
    var answer: String {
        "Copied: \(what)\nThe user sees \"Copied · \(what)\" under your answer, with Copy Again: say in a few words what you copied, don't paste it into your answer unless they asked to see it."
    }

    /// The newest clip for each `what`, for the step that made it to find
    /// it by (ChatItem.copied) when its answer comes back.
    static let recent = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    func remember() {
        AgentClip.recent.withLock { $0[what] = id }
    }
}

/// The clips agents made, for Copy Again, newest kept: a few dozen, in the
/// world's own folder, so Copy Again works after Yab starts again.
@MainActor
final class AgentClips {
    static let shared = AgentClips()
    static let kept = 40

    private var clips: [AgentClip]
    private let file: URL?

    init(file: URL? = Store.unitTests ? nil : Store.file("agent-clips.json")) {
        self.file = file
        clips = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([AgentClip].self, from: $0) } ?? []
    }

    func clip(_ id: String) -> AgentClip? { clips.last { $0.id == id } }

    func keep(_ clip: AgentClip) {
        clips.removeAll { $0.id == clip.id }
        clips.append(clip)
        if clips.count > Self.kept { clips.removeFirst(clips.count - Self.kept) }
        guard let file, let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Copy Again: the clip back on the clipboard; whether it was there.
    @discardableResult
    func again(_ id: String, on board: NSPasteboard = .general) -> Bool {
        guard let clip = clip(id) else { return false }
        if let file = clip.file, !FileManager.default.fileExists(atPath: file) { return false }
        clip.put(on: board)
        return true
    }
}
