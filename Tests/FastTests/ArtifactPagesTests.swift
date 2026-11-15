import Foundation
import Testing
@testable import Fast

/// What Yab keeps of a page an agent published (ArtifactPages,
/// docs/artifact-cards.md): the step's words and answer read, the card's
/// artifact named, the copy made, the page served with its policy.
struct ArtifactPagesTests {
    private static let words = "Updated /private/tmp/claude-501/x/scratchpad/plan/index.html at https://claude.ai/artifact/LaunchPlan01 (Version 2) Icon: \"calendar\".\n\nLive subscription: arming."

    private static func step(_ id: String, seq: Int, artifact: String = "6f1c-plan", path: String = "/tmp/plan/index.html", title: String? = "Launch plan") -> ChatItem {
        var extra = ["artifact": "https://claude.ai/artifact/LaunchPlan01", "artifactPath": path, "artifactID": artifact, "artifactSeq": String(seq)]
        if let title { extra["title"] = title }
        return ChatItem(id: id, kind: .tool, name: "Artifact", state: .done, extra: extra)
    }

    @Test func theToolsWordsSayItsVersion() {
        let read = ChatItem.published(Self.words)
        #expect(read?["artifact"] == "https://claude.ai/artifact/LaunchPlan01")
        #expect(read?["artifactPath"] == "/private/tmp/claude-501/x/scratchpad/plan/index.html")
        #expect(read?["artifactSeq"] == "2")
        #expect(read?["icon"] == "calendar")
    }

    @Test func theToolsAnswerSaysItsVersionAndFiles() {
        let answer: [String: Any] = ["url": "https://claude.ai/artifact/LaunchPlan01", "path": "/tmp/plan/index.html", "artifact_id": "6f1c-plan",
                                     "title": "Launch plan", "icon": "calendar", "seq": 3, "version": "1790264437-8463",
                                     "files_written": [["path": "img/a.jpg", "sha256": "x"], ["path": "css/site.css", "sha256": "y"]]]
        let read = ChatItem.published(result: answer)
        #expect(read?["artifactSeq"] == "3")
        #expect(read?["artifactID"] == "6f1c-plan")
        #expect(read?["artifactFiles"] == "img/a.jpg\ncss/site.css")
        #expect(read?["title"] == "Launch plan")
    }

    @Test func aStepNamesItsArtifactWhateverItsVersion() throws {
        let one = try #require(ArtifactRef(Self.step("t1", seq: 1)))
        let two = try #require(ArtifactRef(Self.step("t2", seq: 2)))
        #expect(one.key == two.key)
        #expect(one.key == one.key.lowercased())
        #expect(one.key.allSatisfy { $0.isLetter || $0.isNumber })
        #expect(one.local)
        #expect(two.seq == 2)
        #expect(ArtifactRef(Self.step("t3", seq: 1, artifact: "other")).map(\.key) != one.key)
        // Running, failed, or not the Artifact tool: no card.
        var running = Self.step("t4", seq: 1)
        running.state = .running
        #expect(ArtifactRef(running) == nil)
        #expect(ArtifactRef(ChatItem(id: "t5", kind: .tool, name: "Read", state: .done, extra: ["artifact": "https://claude.ai/artifact/x"])) == nil)
    }

    @Test func aCanvasIsNotAPageYabDraws() throws {
        let canvas = try #require(ArtifactRef(Self.step("t1", seq: 1, path: "/tmp/pricing/canvas.json", title: "Pricing calculator")))
        #expect(!canvas.local)
        let untitled = try #require(ArtifactRef(Self.step("t2", seq: 1, path: "/tmp/launch-plan/index.html", title: nil)))
        #expect(untitled.title == "Launch plan")
    }

    @Test func aTurnShowsOneCardAnArtifactAtItsLastVersion() {
        let turn = [ChatItem(id: "a", kind: .asked, text: "make it"), Self.step("t1", seq: 1), ChatItem(id: "m", kind: .message, text: "and again"),
                    Self.step("t2", seq: 2), Self.step("t3", seq: 1, artifact: "other", title: "Notes")]
        let cards = ArtifactRef.cards(in: turn)
        #expect(cards.map(\.title) == ["Launch plan", "Notes"])
        #expect(cards.first?.seq == 2)
        #expect(cards.first?.item == "t2")
    }

    @MainActor @Test func aChatShowsOneCardAnArtifactInTheTurnOfItsNewestVersion() {
        let first = [ChatItem(id: "a1", kind: .asked, text: "make it"), Self.step("t1", seq: 1), Self.step("n1", seq: 1, artifact: "notes", title: "Notes")]
        let second = [ChatItem(id: "a2", kind: .asked, text: "again"), Self.step("t2", seq: 2)]
        let placed = ArtifactCard.placement([first, second])
        #expect(placed[0]?.map(\.title) == ["Notes"])
        #expect(placed[1]?.map(\.title) == ["Launch plan"])
        #expect(placed[1]?.first?.seq == 2)
    }

    @Test func thePageIsServedWithItsPolicyAndATitle() {
        let bare = Data("<!doctype html><html><head><meta charset=utf-8></head><body><h1>Plan</h1></body></html>".utf8)
        let served = String(decoding: ArtifactPages.served(bare, title: "Launch <plan>"), as: UTF8.self)
        #expect(served.contains("<head><meta http-equiv=\"Content-Security-Policy\""))
        #expect(served.contains("<title>Launch &lt;plan></title>"))
        #expect(served.contains("<h1>Plan</h1>"))
        let titled = Data("<html><head><title>Own</title></head><body></body></html>".utf8)
        let kept = String(decoding: ArtifactPages.served(titled, title: "Launch plan"), as: UTF8.self)
        #expect(kept.contains("<title>Own</title>"))
        #expect(!kept.contains("Launch plan"))
        let headless = String(decoding: ArtifactPages.served(Data("<p>hi</p>".utf8), title: "T"), as: UTF8.self)
        #expect(headless.hasPrefix("<head><meta http-equiv=\"Content-Security-Policy\""))
    }

    @Test func thePolicyLetsInOnlyItsOwnFilesAndTheCDNs() {
        let policy = ArtifactPages.policy
        #expect(policy.hasPrefix("default-src 'none'"))
        #expect(policy.contains("form-action 'none'"))
        #expect(policy.contains("https://cdn.jsdelivr.net"))
        #expect(!policy.contains("http:"))
        #expect(!policy.contains("*"))
    }

    @Test func theCopyTakesThePageAndItsFilesAndNothingAboveIt() throws {
        let manager = FileManager.default
        let world = manager.temporaryDirectory.appendingPathComponent("artifact-copy-" + UUID().uuidString)
        defer { try? manager.removeItem(at: world) }
        let source = world.appendingPathComponent("scratch/plan", isDirectory: true)
        try manager.createDirectory(at: source.appendingPathComponent("img"), withIntermediateDirectories: true)
        try Data("<html>v1</html>".utf8).write(to: source.appendingPathComponent("index.html"))
        try Data("jpg".utf8).write(to: source.appendingPathComponent("img/a.jpg"))
        try Data("secret".utf8).write(to: world.appendingPathComponent("scratch/secret.txt"))
        let folder = world.appendingPathComponent("kept/chat/akey", isDirectory: true)
        let entry = ArtifactPages.copy(source.appendingPathComponent("index.html").path, files: ["img/a.jpg", "../secret.txt"], into: folder)
        #expect(entry == "index.html")
        #expect(manager.fileExists(atPath: folder.appendingPathComponent("page/index.html").path))
        #expect(manager.fileExists(atPath: folder.appendingPathComponent("page/img/a.jpg").path))
        #expect(!manager.fileExists(atPath: folder.appendingPathComponent("secret.txt").path))
        #expect(!manager.fileExists(atPath: folder.appendingPathComponent("page/../secret.txt").standardizedFileURL.path))
        // Again, the file rewritten: the copy is the new one, whole.
        try Data("<html>v2</html>".utf8).write(to: source.appendingPathComponent("index.html"))
        #expect(ArtifactPages.copy(source.appendingPathComponent("index.html").path, files: [], into: folder) == "index.html")
        #expect(try String(contentsOf: folder.appendingPathComponent("page/index.html"), encoding: .utf8) == "<html>v2</html>")
        #expect(!manager.fileExists(atPath: folder.appendingPathComponent("page/img/a.jpg").path))
        #expect(!manager.fileExists(atPath: folder.appendingPathComponent("page.new").path))
        // Gone from the scratchpad: no copy, nothing changed.
        #expect(ArtifactPages.copy(world.appendingPathComponent("gone.html").path, files: [], into: folder) == nil)
        #expect(manager.fileExists(atPath: folder.appendingPathComponent("page/index.html").path))
    }

    @Test func itsAddressIsYabsOwnScheme() {
        let url = ArtifactPages.address(key: "a0123", entry: "index.html")
        #expect(url?.absoluteString == "yab-artifact://a0123/index.html")
        #expect(ArtifactPages.isPage(url))
        #expect(!ArtifactPages.isPage(URL(string: "https://claude.ai/artifact/x")))
    }
}
