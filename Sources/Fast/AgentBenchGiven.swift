import AppKit
import ImageIO
import UniformTypeIdentifiers

// files_read for what the person gave a chat. A file they attached, pasted
// or dropped is named by its path in their message (ChatAttachment.said),
// and a task kept to the browser has no file reader of its own: a pasted
// screenshot sat in Yab's temporary folder, the agent was told to open it,
// and it answered that it couldn't. Yab reads such a file for the agent,
// as `upload` may already put it on a page (AgentFiles.refuse), and shows
// a picture as a picture, whatever the file came from.

extension Bench {
    func handleAgentFilesReadShowing(_ c: AgentCall) {
        let id = (c.request["id"] as? String ?? c.request["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let url = URL(fileURLWithPath: (id as NSString).expandingTildeInPath)
        if id.hasPrefix("/") || id.hasPrefix("~"), let session = c.session, let asker = c.agents.session(session),
           Bench.personGave(url, to: asker), AgentFiles.shared.refuse(url, session: session, full: true) == nil {
            c.agents.touch(session, "files")
            let answer = c.answer
            Task { @MainActor in
                var words = await Task.detached(priority: .userInitiated) { FileShelf.read(url) }.value
                if words == nil, ChatAttachment.picture(url) { words = await MailAgent.pictureWords(url) }
                answer(await Bench.showing(MailAgent.given(url, head: "File \(url.lastPathComponent), which the person gave this chat.", words: words)))
            }
            return
        }
        // Anything else Files lists: its own answer, a picture shown in it.
        let answer = c.answer
        handleAgentFilesRead(AgentCall(bench: c.bench, verb: c.verb, request: c.request, browser: c.browser) { got in
            Task { @MainActor in answer(await Bench.showing(got)) }
        })
    }

    /// Whether the person gave this chat the file: named by its path in
    /// their words (where said() puts what they attach), or among what
    /// went with their messages.
    static func personGave(_ url: URL, to session: Agents.Session) -> Bool {
        if AgentFiles.named(url, in: session.told) { return true }
        let real = url.standardizedFileURL.resolvingSymlinksInPath().path
        return (session.sent.values.flatMap { $0 } + session.attaching.flatMap { $0 }).contains {
            $0.file?.standardizedFileURL.resolvingSymlinksInPath().path == real
        }
    }

    /// An answer that gives a picture's path, with the picture in it for
    /// the agent to look at (`image`, base64, and its `mime`).
    nonisolated static func showing(_ got: [String: Any]) async -> [String: Any] {
        guard got["error"] == nil, let path = got["path"] as? String, ChatAttachment.picture(URL(fileURLWithPath: path)) else { return got }
        let url = URL(fileURLWithPath: path)
        guard let (data, mime) = await Task.detached(priority: .userInitiated, operation: { ChatAttachment.shown(url) }).value else { return got }
        var out = got
        out["image"] = data.base64EncodedString()
        out["mime"] = mime
        return out
    }
}

extension ChatAttachment {
    /// A picture as an agent is shown it in a tool's answer: its first
    /// frame upright, the long side at most 2048 px (what the models look
    /// at), a screen's as a PNG for its text, a photo's as a JPEG. A PNG
    /// over 3.6 MB, past the 5 MB a model takes once in base64, goes as a
    /// JPEG too.
    static func shown(_ url: URL) -> (Data, String)? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        func encoded(_ kind: UTType) -> Data? {
            let data = NSMutableData()
            guard let out = CGImageDestinationCreateWithData(data as CFMutableData, kind.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            return CGImageDestinationFinalize(out) ? data as Data : nil
        }
        let photo = ["jpg", "jpeg", "heic", "heif", "avif"].contains(url.pathExtension.lowercased())
        if !photo, let png = encoded(.png), png.count <= 3_600_000 { return (png, "image/png") }
        return encoded(.jpeg).map { ($0, "image/jpeg") }
    }
}
