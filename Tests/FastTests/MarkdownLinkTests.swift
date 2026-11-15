import AppKit
import Testing
@testable import Fast

// What ⌥⇧⌘C puts on the clipboard as text.
struct MarkdownLinkTests {
    static func link(_ title: String, _ address: String) -> String {
        let url = Diary.shareable(URL(string: address)!)
        return MarkdownLink.markdown(.init(title: MarkdownLink.title(title, host: url.host() ?? ""), url: url))
    }

    @Test func theSiteNameGoes() {
        #expect(Self.link("Rust (programming language) - Wikipedia", "https://en.wikipedia.org/wiki/Rust_(programming_language)")
            == "[Rust (programming language)](https://en.wikipedia.org/wiki/Rust_(programming_language))")
        #expect(Self.link("(12) Never Gonna Give You Up - YouTube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=Ab")
            == "[Never Gonna Give You Up](https://www.youtube.com/watch?v=dQw4w9WgXcQ)")
        #expect(Self.link("Some story | BBC News", "https://www.bbc.co.uk/news/1") == "[Some story](https://www.bbc.co.uk/news/1)")
    }

    @Test func aDashOfItsOwnStays() {
        #expect(Self.link("Swift - the language", "https://swift.org/") == "[Swift - the language](https://swift.org/)")
        #expect(Self.link("Post - Xylophones", "https://x.com/a") == "[Post - Xylophones](https://x.com/a)")
        // A site called something its address doesn't say keeps its name.
        #expect(Self.link("Ask HN: Anyone? | Hacker News", "https://news.ycombinator.com/item?id=1")
            == "[Ask HN: Anyone? | Hacker News](https://news.ycombinator.com/item?id=1)")
        #expect(Self.link("WebKitの仕組み | キータ", "https://qiita.com/ja/1/") == "[WebKitの仕組み | キータ](https://qiita.com/ja/1/)")
    }

    @Test func markdownHoldsTogether() {
        #expect(Self.link("[RFC] a\\b", "https://example.com/") == "[\\[RFC\\] a\\\\b](https://example.com/)")
        #expect(Self.link("Odd", "https://example.com/a_(b") == "[Odd](https://example.com/a_%28b)")
    }

    // What Notes or Mail read from the HTML beside it, in any alphabet.
    @Test func theHTMLKeepsItsLetters() {
        let board = NSPasteboard(name: .init("yab.test.markdownlink"))
        defer { board.releaseGlobally() }
        MarkdownLink.copy([.init(title: "WebKitの仕組み", url: URL(string: "https://zenn.dev/a/1")!)], to: board)
        let read = board.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString]
        #expect(read?.first?.string == "WebKitの仕組み")
        #expect(board.string(forType: .string) == "[WebKitの仕組み](https://zenn.dev/a/1)")
        #expect(board.string(forType: .URL) == "https://zenn.dev/a/1")
    }
}
