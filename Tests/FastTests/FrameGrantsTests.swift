import Foundation
import Testing
@testable import Fast

// Which loads get a seed cookie before they go (feedback #252): claude.ai
// artifact frames, and nothing else.
struct FrameGrantsTests {
    static func wants(_ address: String, main: Bool = false) -> Bool {
        FrameGrants.wants(URL(string: address)!, mainFrame: main)
    }

    @Test func artifactFramesAreSeeded() {
        #expect(Self.wants("https://0b1c2d3e-0000-4000-8000-000000000000.frame.claudeusercontent.com/_t?__frame_t=x"))
        #expect(Self.wants("https://0b1c2d3e-0000-4000-8000-000000000000-top.frame.claudeusercontent.com/_f/v/"))
        #expect(Self.wants("https://abc.claudeusercontent.com/"))
    }

    @Test func pagesAndOtherFramesAreNot() {
        #expect(!Self.wants("https://abc.frame.claudeusercontent.com/", main: true))
        #expect(!Self.wants("http://abc.frame.claudeusercontent.com/"))
        #expect(!Self.wants("https://claude.ai/artifact/x"))
        #expect(!Self.wants("https://claudeusercontent.com.example.com/"))
        #expect(!Self.wants("https://ads.doubleclick.net/frame"))
    }
}
