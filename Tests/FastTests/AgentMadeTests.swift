import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fast

// save_file and copy (docs/agent-asks.md, wave 1): names cleaned, the task's
// folder only, what the file card says, what lands on the clipboard for
// each kind, and the "Copied" line read off a step's answer. With
// YAB_FARM_OUT set, pictures of the card and the line, light and dark.
@MainActor
struct AgentMadeTests {
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("made-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func named(_ said: String) -> String {
        let name = SaveFile.name(said)
        return name.base + "|" + name.ext
    }

    static func board() -> NSPasteboard { NSPasteboard(name: .init("yab-test-\(UUID().uuidString)")) }

    // MARK: - save_file

    @Test func namesAreCleaned() {
        #expect(Self.named("Contacts.csv") == "Contacts|csv")
        #expect(Self.named("../../.ssh/config") == "config|txt")
        #expect(Self.named("/Users/x/Desktop/Team.ICS") == "Team|ics")
        #expect(Self.named("a\\b\\notes.md") == "notes|md")
        #expect(Self.named(".hidden") == "hidden|txt")
        #expect(Self.named("run.command") == "run.command|txt")
        #expect(Self.named("setup.sh") == "setup.sh|txt")
        #expect(Self.named("Q3 report") == "Q3 report|txt")
        #expect(Self.named("weird.ext with space") == "weird.ext with space|txt")
        #expect(Self.named("data.tar.gz") == "data.tar|gz")
    }

    @Test func writesIntoTheFolderOnlyAndNeverOver() throws {
        let folder = try Self.folder()
        let first = try SaveFile.write("a,b\n1,2\n", named: "../../Contacts.csv", in: folder)
        #expect(first.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        #expect(first.lastPathComponent == "Contacts.csv")
        let second = try SaveFile.write("a,b\n3,4\n", named: "Contacts.csv", in: folder)
        #expect(second.lastPathComponent == "Contacts 2.csv")
        #expect(try String(contentsOf: first, encoding: .utf8) == "a,b\n1,2\n")
        let named = try SaveFile.write("x", named: "rm -rf.command", in: folder)
        #expect(named.lastPathComponent == "rm -rf.command.txt")
        let bare = try SaveFile.write("x", named: "", in: folder)
        #expect(bare.lastPathComponent == "File.txt")
        #expect(throws: SaveFile.Trouble.empty) { try SaveFile.write("", named: "a.txt", in: folder) }
        let big = String(repeating: "x", count: SaveFile.limit + 1)
        #expect(throws: SaveFile.Trouble.tooBig(SaveFile.limit + 1)) { try SaveFile.write(big, named: "a.txt", in: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Contacts 2.csv", "Contacts.csv", "File.txt", "rm -rf.command.txt"])
    }

    @Test func theCardSaysWhatIsInside() throws {
        let folder = try Self.folder()
        let rows = (1...48).map { "Person \($0),p\($0)@example.com,\"Line one\nline two\"" }.joined(separator: "\n")
        let csv = try SaveFile.write("name,email,note\n" + rows + "\n", named: "Team.csv", in: folder)
        #expect(SaveFile.counted(csv) == "48 rows")
        #expect(ChatFileCard.About.line(csv).hasPrefix("48 rows · "))
        let events = (1...4).map { "BEGIN:VEVENT\r\nSUMMARY:Talk \($0)\r\nEND:VEVENT\r\n" }.joined()
        let ics = try SaveFile.write("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + events + "END:VCALENDAR\r\n", named: "Talks.ics", in: folder)
        #expect(ChatFileCard.About.line(ics).hasPrefix("4 events · "))
        let json = try SaveFile.write("[{\"a\":1},{\"a\":2},{\"a\":3}]", named: "Items.json", in: folder)
        #expect(ChatFileCard.About.line(json).hasPrefix("3 items · "))
        let one = try SaveFile.write("{\"a\":1}", named: "One.json", in: folder)
        #expect(SaveFile.counted(one) == "1 field")
        let md = try SaveFile.write("# Notes\n\nThree words here\n", named: "Notes.md", in: folder)
        #expect(ChatFileCard.About.line(md).hasPrefix("5 words · "))
        #expect(ChatFileCard.format(csv)?.word == "CSV")
        #expect(ChatFileCard.format(ics)?.word == "ICS")
        #expect(ChatFileCard.format(json)?.word == "JSON")
    }

    @Test func savedFileStepsShowTheirFile() {
        #expect(ChatItem.savedFile("save_file", "Saved: /Users/a/Downloads/yab/T 1a2b/Team.csv (3 KB)") == "/Users/a/Downloads/yab/T 1a2b/Team.csv")
        #expect(ChatItem.marks("save_file", "Saved: /x/Team.csv (3 KB)") == ["file": "/x/Team.csv"])
    }

    // MARK: - copy

    @Test func textGoesOnAsWords() throws {
        let clip = try AgentClip.make(text: "a@x.com\nb@y.com", url: nil, title: nil, quote: nil, file: nil, what: "2 addresses", folder: nil)
        let board = Self.board()
        clip.put(on: board)
        #expect(board.string(forType: .string) == "a@x.com\nb@y.com")
        #expect(clip.what == "2 addresses")
        #expect(try AgentClip.make(text: "a\nb\n\nc", url: nil, title: nil, quote: nil, file: nil, what: nil, folder: nil).what == "3 lines")
        #expect(try AgentClip.make(text: "jane@example.com", url: nil, title: nil, quote: nil, file: nil, what: "  ", folder: nil).what == "jane@example.com")
    }

    @Test func aLinkWithATitleGoesOnRich() throws {
        let clip = try AgentClip.make(text: nil, url: "https://www.example.com/post?a=1&b=2", title: "Room for <ambition>", quote: nil, file: nil, what: nil, folder: nil)
        #expect(clip.what == "Link to Room for <ambition>")
        let board = Self.board()
        clip.put(on: board)
        #expect(board.string(forType: .string) == "https://www.example.com/post?a=1&b=2")
        #expect(board.string(forType: .URL) == "https://www.example.com/post?a=1&b=2")
        #expect(board.string(forType: .html) == "<a href=\"https://www.example.com/post?a=1&amp;b=2\">Room for &lt;ambition&gt;</a>")
        #expect(board.string(forType: NSPasteboard.PasteboardType("public.url-name")) == "Room for <ambition>")
        let rtf = try #require(board.data(forType: .rtf))
        let rich = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
        #expect(rich.string == "Room for <ambition>")
        #expect((rich.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.absoluteString == "https://www.example.com/post?a=1&b=2")
        let bare = try AgentClip.make(text: nil, url: "https://www.example.com/a", title: nil, quote: nil, file: nil, what: nil, folder: nil)
        #expect(bare.what == "Link to example.com")
        #expect(throws: AgentClip.Trouble.badLink) { try AgentClip.make(text: nil, url: "javascript:alert(1)", title: nil, quote: nil, file: nil, what: nil, folder: nil) }
        #expect(throws: AgentClip.Trouble.two) { try AgentClip.make(text: "a", url: "https://a.com", title: nil, quote: nil, file: nil, what: nil, folder: nil) }
        #expect(throws: AgentClip.Trouble.nothing) { try AgentClip.make(text: "", url: nil, title: nil, quote: nil, file: nil, what: nil, folder: nil) }
    }

    @Test func aParagraphIsATextFragment() throws {
        #expect(AgentClip.fragment("https://a.com/p", quote: "Room for ambition") == "https://a.com/p#:~:text=Room%20for%20ambition")
        #expect(AgentClip.fragment("https://a.com/p#intro", quote: "well-made, things") == "https://a.com/p#intro:~:text=well%2Dmade%2C%20things")
        #expect(AgentClip.fragment("https://a.com/p#:~:text=old", quote: "new") == "https://a.com/p#:~:text=new")
        let long = "The team that leaves room for ambition ships the things nobody planned for this year"
        #expect(AgentClip.fragment("https://a.com/p", quote: long) == "https://a.com/p#:~:text=The%20team%20that%20leaves,planned%20for%20this%20year")
        let clip = try AgentClip.make(text: nil, url: "https://a.com/p", title: "P", quote: "Room for ambition", file: nil, what: nil, folder: nil)
        #expect(clip.url == "https://a.com/p#:~:text=Room%20for%20ambition")
        #expect(clip.what == "Link to the paragraph")
        #expect(throws: AgentClip.Trouble.quoteNeedsPage) { try AgentClip.make(text: nil, url: "mailto:a@b.com", title: nil, quote: "x", file: nil, what: nil, folder: nil) }
    }

    @Test func aFileOfTheTaskGoesOnAsTheFile() throws {
        let folder = try Self.folder()
        let file = try SaveFile.write("a,b\n", named: "Team.csv", in: folder)
        let clip = try AgentClip.make(text: nil, url: nil, title: nil, quote: nil, file: file.path, what: nil, folder: folder)
        #expect(clip.what == "Team.csv")
        let board = Self.board()
        clip.put(on: board)
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map { $0.resolvingSymlinksInPath().path } == [file.resolvingSymlinksInPath().path])
        // Nothing outside the task's folder, however it is named.
        let other = try Self.folder()
        let outside = other.appendingPathComponent("secret.txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        #expect(throws: AgentClip.Trouble.outside(outside.path)) { try AgentClip.make(text: nil, url: nil, title: nil, quote: nil, file: outside.path, what: nil, folder: folder) }
        let sneaky = folder.path + "/../" + other.lastPathComponent + "/secret.txt"
        #expect(throws: (any Error).self) { try AgentClip.make(text: nil, url: nil, title: nil, quote: nil, file: sneaky, what: nil, folder: folder) }
        #expect(throws: AgentClip.Trouble.noFile(folder.path + "/none.txt")) { try AgentClip.make(text: nil, url: nil, title: nil, quote: nil, file: folder.path + "/none.txt", what: nil, folder: folder) }
    }

    @Test func copyAgainPutsItBack() throws {
        let clips = AgentClips(file: nil)
        let clip = try AgentClip.make(text: "a@x.com", url: nil, title: nil, quote: nil, file: nil, what: "1 address", folder: nil)
        clips.keep(clip)
        let board = Self.board()
        board.clearContents()
        board.setString("something else", forType: .string)
        #expect(clips.again(clip.id, on: board))
        #expect(board.string(forType: .string) == "a@x.com")
        #expect(!clips.again("nothere", on: board))
    }

    @Test func theCopiedLineIsReadOffTheStep() throws {
        let clip = try AgentClip.make(text: "a\nb", url: nil, title: nil, quote: nil, file: nil, what: "14 addresses", folder: nil)
        // The agent never hears the clip's id: Yab keeps it.
        #expect(clip.answer.hasPrefix("Copied: 14 addresses\n"))
        #expect(!clip.answer.contains(clip.id))
        clip.remember()
        #expect(ChatItem.copied("copy", clip.answer) == ["copied": "14 addresses", "clip": clip.id])
        #expect(ChatItem.copied("copy", "Copied: Link to a (b) page") == ["copied": "Link to a (b) page"])
        #expect(ChatItem.copied("text", clip.answer) == nil)
        #expect(ChatItem.copied("copy", "copy needs text, url or file") == nil)
        var asked = ChatItem(id: "1", kind: .asked, text: "copy the emails")
        asked.state = .done
        var step = ChatItem(id: "2", kind: .tool, name: "copy")
        step.state = .done
        let marked = step.saving(["content": [["type": "text", "text": clip.answer]]])
        #expect(marked.extra?["copied"] == "14 addresses")
        #expect(marked.extra?["clip"] == clip.id)
        let earlier = ChatItem(id: "0", kind: .tool, name: "copy", state: .done, extra: ["copied": "old", "clip": "old1"])
        let items = [earlier, asked, marked]
        #expect(ChatItem.copied(in: items)?.what == "14 addresses")
        #expect(ChatItem.lastClip(items) == clip.id)
        #expect(ChatItem.lastClip([earlier, asked]) == nil)
    }

    /// The corner's line for a long answer is its first sentence.
    @Test func theCornerLeadsWithTheFirstSentence() {
        #expect(TaskAnswer.pick("Copied the 14 addresses on this page. Paste them anywhere: one a line, in the order the page lists them.") == "Copied the 14 addresses on this page.")
        #expect(TaskAnswer.pick("Short answer.") == "Short answer.")
        let long = String(repeating: "word ", count: 30)
        #expect(TaskAnswer.pick(long)?.hasSuffix("…") == true)
    }

    // MARK: - pictures

    /// The cards for a .csv, .ics and .json save_file made, and the Copied
    /// line under an answer, as the chat draws them, light and dark.
    @Test func pictures() async throws {
        guard let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] else { return }
        let folder = try Self.folder()
        let rows = (1...48).map { "Person \($0),p\($0)@example.com" }.joined(separator: "\n")
        let paths = [
            try SaveFile.write("name,email\n" + rows + "\n", named: "Team.csv", in: folder),
            try SaveFile.write("BEGIN:VCALENDAR\r\n" + String(repeating: "BEGIN:VEVENT\r\nEND:VEVENT\r\n", count: 4) + "END:VCALENDAR\r\n", named: "Talks.ics", in: folder),
            try SaveFile.write("[1,2,3,4,5,6,7,8,9,10,11,12]", named: "Items.json", in: folder),
        ].map(\.path)
        let clips = AgentClips.shared
        let clip = try AgentClip.make(text: "a@x.com", url: nil, title: nil, quote: nil, file: nil, what: "14 addresses", folder: nil)
        clips.keep(clip)
        for dark in [false, true] {
            var cards: [ChatFileCard.About] = []
            for path in paths { cards.append(await ChatFileCard.About.read(URL(fileURLWithPath: path))) }
            let view = VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    ChatFileCard(path: path, group: paths, preread: cards[index])
                }
                ChatCopiedLine(what: clip.what, clip: clip.id)
                    .padding(.top, 2)
            }
            .padding(24)
            .frame(width: 380, alignment: .leading)
            .background(Palette.ground)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = renderer.nsImage.flatMap { NSBitmapImageRep(data: $0.tiffRepresentation!)?.representation(using: .png, properties: [:]) }
            }
            try #require(data).write(to: URL(fileURLWithPath: out).appendingPathComponent(dark ? "made-dark.png" : "made-light.png"))
        }
    }
}
