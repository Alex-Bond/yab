import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentBookmarkTests {
    private func site(_ title: String = "Same title") -> Bookmark {
        .site(title, URL(string: "https://bookmark.example/page")!)
    }

    private func withTree(_ tree: [Bookmark], _ run: (Bookmarks) -> Void) {
        let bookmarks = Bookmarks()
        let original = bookmarks.roots
        defer { bookmarks.replaceAll(with: original) }
        bookmarks.replaceAll(with: tree)
        run(bookmarks)
    }

    @Test func nestedFoldersAndBookmarksReturnIdsForTheNextOperation() {
        withTree([]) { bookmarks in
            let root = AgentBookmarks.createFolder(["title": "Reading"], in: bookmarks)
            let rootID = root["id"] as? String ?? ""
            #expect(UUID(uuidString: rootID) != nil)
            let child = AgentBookmarks.createFolder(["title": "Articles", "folder": rootID.lowercased()], in: bookmarks)
            let childID = child["id"] as? String ?? ""
            let made = AgentBookmarks.add(["url": "https://example.com/article", "title": "Essay", "folder": childID], to: bookmarks)
            let id = made["id"] as? String ?? ""
            #expect(UUID(uuidString: id) != nil)
            #expect((made["text"] as? String)?.contains(id) == true)
            #expect(bookmarks.roots.first?.children?.first?.children?.first?.id.uuidString == id)
            let again = AgentBookmarks.add(["url": "https://example.com/article", "folder": "No extra folder"], to: bookmarks)
            #expect(again["id"] as? String == id)
            #expect(bookmarks.roots.count == 1)
            #expect(AgentBookmarks.update(["id": childID, "title": "Papers"], in: bookmarks)["error"] == nil)
            #expect(bookmarks.roots.first?.children?.first?.title == "Papers")
            let updated = AgentBookmarks.update(["id": id, "title": "Revised", "url": "https://example.com/revised"], in: bookmarks)
            #expect(updated["id"] as? String == id)
            #expect(updated["url"] as? String == "https://example.com/revised")
            #expect(AgentBookmarks.move(["id": id, "folder": "", "before": rootID], in: bookmarks)["error"] == nil)
            #expect(bookmarks.roots.first?.id.uuidString == id)
            #expect(bookmarks.roots.last?.children?.first?.children?.isEmpty == true)
        }
    }

    @Test func folderSelectionRejectsUnknownIdsAndAmbiguousNamesWithoutWriting() {
        let first = Bookmark.folder("Work", []), second = Bookmark.folder("Work", [])
        withTree([first, second]) { bookmarks in
            let revision = bookmarks.revision
            for folder in [UUID().uuidString, "work"] {
                #expect(AgentBookmarks.add(["url": "https://example.com", "folder": folder], to: bookmarks)["error"] != nil)
                #expect(bookmarks.revision == revision)
            }
            #expect(AgentBookmarks.createFolder(["title": "Nested", "folder": UUID().uuidString], in: bookmarks)["error"] != nil)
            #expect(bookmarks.roots == [first, second])
            let added = AgentBookmarks.add(["url": "https://example.com", "folder": second.id.uuidString.lowercased()], to: bookmarks)
            #expect(added["parent"] as? String == second.id.uuidString)
            #expect(bookmarks.roots.first?.children?.isEmpty == true)
            #expect(bookmarks.roots.last?.children?.count == 1)
        }
    }

    @Test func allEntriesAreReachableByPagingAndFoldersAreSearchable() {
        let sites = (0..<451).map { Bookmark.site("Page \($0)", URL(string: "https://example.com/\($0)")!) }
        let folder = Bookmark.folder("Research", sites)
        var offset = 0
        var seen: [UUID] = []
        repeat {
            let page = AgentBookmarks.list(["folder": folder.id.uuidString, "offset": offset, "limit": 100], roots: [folder])
            #expect(page["total"] as? Int == 451)
            let text = page["text"] as? String ?? ""
            seen += sites.filter { text.contains($0.id.uuidString) }.map(\.id)
            if let next = page["next_offset"] as? Int {
                #expect(next > offset)
                offset = next
            } else { break }
        } while offset < 1000
        #expect(seen == sites.map(\.id))
        let search = AgentBookmarks.list(["query": "research"], roots: [folder])
        #expect(search["total"] as? Int == 1)
        #expect((search["text"] as? String)?.contains(folder.id.uuidString) == true)
        let beyond = AgentBookmarks.list(["offset": Int.max], roots: [folder])
        #expect(beyond["has_more"] as? Bool == false)
        let empty = Bookmark(title: "Empty", url: nil, children: nil)
        #expect(AgentBookmarks.list(["folder": empty.id.uuidString], roots: [folder, empty])["total"] as? Int == 0)
        let invalid: [[String: Any]] = [["offset": -1], ["limit": 0], ["limit": 401], ["limit": "100"], ["folder": UUID().uuidString]]
        for request in invalid { #expect(AgentBookmarks.list(request, roots: [folder])["error"] != nil) }
    }

    @Test func reorderingKeepsTheParentAndInvalidMovesKeepTheWholeTree() {
        let a = site("A"), b = site("B"), c = site("C")
        let nested = Bookmark.folder("Nested", [c])
        let folder = Bookmark.folder("Folder", [a, b, nested])
        withTree([folder]) { bookmarks in
            #expect(AgentBookmarks.move(["id": b.id.uuidString, "before": a.id.uuidString], in: bookmarks)["error"] == nil)
            #expect(bookmarks.roots.first?.children?.map(\.id) == [b.id, a.id, nested.id])
            let tree = bookmarks.roots, revision = bookmarks.revision
            let invalid: [[String: Any]] = [
                ["id": folder.id.uuidString, "folder": nested.id.uuidString],
                ["id": folder.id.uuidString, "folder": folder.id.uuidString],
                ["id": a.id.uuidString, "folder": UUID().uuidString],
                ["id": a.id.uuidString, "folder": b.id.uuidString],
                ["id": a.id.uuidString, "before": c.id.uuidString],
                ["id": a.id.uuidString, "folder": "", "before": b.id.uuidString],
                ["id": a.id.uuidString],
            ]
            for request in invalid {
                #expect(AgentBookmarks.move(request, in: bookmarks)["error"] != nil)
                #expect(bookmarks.roots == tree)
                #expect(bookmarks.revision == revision)
            }
        }
    }

    @Test func invalidEditsAreAtomicAndNamesDoNotChangeIdentity() {
        let page = site(), folder = Bookmark.folder("Folder", [])
        withTree([page, folder]) { bookmarks in
            let revision = bookmarks.revision
            let invalid: [[String: Any]] = [
                ["id": page.id.uuidString], ["id": UUID().uuidString, "title": "Other"],
                ["id": page.id.uuidString, "title": " "],
                ["id": page.id.uuidString, "title": "Changed", "url": "javascript:alert(1)"],
                ["id": folder.id.uuidString, "url": "https://example.com"],
            ]
            for request in invalid {
                #expect(AgentBookmarks.update(request, in: bookmarks)["error"] != nil)
                #expect(bookmarks.roots == [page, folder])
                #expect(bookmarks.revision == revision)
            }
            #expect(AgentBookmarks.update(["id": page.id.uuidString, "title": "New title"], in: bookmarks)["error"] == nil)
            #expect(bookmarks.roots.first?.id == page.id)
            #expect(bookmarks.roots.first?.added == page.added)
        }
    }

    @Test func listingsExposeExactIdsEvenForDuplicateAndFilteredPages() {
        let first = site(), second = site()
        let folder = Bookmark.folder("Reading", [.folder("Nested", [second])])
        let roots = [first, folder]
        let all = AgentBookmarks.text(roots)
        for node in [first, second, folder] { #expect(all.contains(node.id.uuidString)) }
        let filtered = AgentBookmarks.text(roots, query: "  SAME TITLE\n")
        #expect(filtered.contains(first.id.uuidString))
        #expect(filtered.contains(second.id.uuidString))
        #expect(!filtered.contains(folder.id.uuidString))
        #expect(AgentBookmarks.text(roots, query: "bookmark.example").contains(second.id.uuidString))
        #expect(AgentBookmarks.text(roots, query: "absent") == "No bookmark matches that.")
    }

    @Test func deletionTargetsOnlyTheRequestedNestedId() {
        let first = site(), second = site()
        let nested = Bookmark.folder("Nested", [second])
        let folder = Bookmark.folder("Reading", [first, nested])
        let bookmarks = Bookmarks()
        let original = bookmarks.roots
        defer { bookmarks.replaceAll(with: original) }
        bookmarks.replaceAll(with: [folder])
        let revision = bookmarks.revision

        let answer = AgentBookmarks.delete(["id": second.id.uuidString.lowercased()], from: bookmarks)
        #expect(answer["error"] == nil)
        #expect(bookmarks.revision > revision)
        #expect(bookmarks.roots.map(\.id) == [folder.id])
        #expect(bookmarks.roots.first?.children?.first == first)
        #expect(bookmarks.roots.first?.children?.last?.id == nested.id)
        #expect(bookmarks.roots.first?.children?.last?.children == [])
        let after = bookmarks.roots
        #expect(AgentBookmarks.delete(["id": second.id.uuidString], from: bookmarks)["error"] != nil)
        #expect(bookmarks.roots == after)
    }

    @Test func invalidIdsNeverMutateTheTree() {
        let page = site()
        let bookmarks = Bookmarks()
        let original = bookmarks.roots
        defer { bookmarks.replaceAll(with: original) }
        bookmarks.replaceAll(with: [page])
        let revision = bookmarks.revision
        let requests: [[String: Any]] = [[:], ["id": ""], ["id": "Same title"], ["id": page.url!],
                                        ["id": 1], ["id": UUID().uuidString]]
        for request in requests {
            #expect(AgentBookmarks.delete(request, from: bookmarks)["error"] != nil)
            #expect(bookmarks.roots == [page])
            #expect(bookmarks.revision == revision)
        }
    }

    @Test func nonemptyFoldersNeedExplicitRecursiveDeletion() {
        let page = site(), kept = site("Keep")
        let folder = Bookmark.folder("Reading", [.folder("Nested", [page])])
        let bookmarks = Bookmarks()
        let original = bookmarks.roots
        defer { bookmarks.replaceAll(with: original) }
        bookmarks.replaceAll(with: [folder, kept])
        let requests: [[String: Any]] = [["id": folder.id.uuidString], ["id": folder.id.uuidString, "recursive": false],
                                        ["id": folder.id.uuidString, "recursive": "true"]]
        for request in requests {
            #expect(AgentBookmarks.delete(request, from: bookmarks)["error"] != nil)
            #expect(bookmarks.roots == [folder, kept])
        }
        #expect(AgentBookmarks.delete(["id": folder.id.uuidString, "recursive": true], from: bookmarks)["error"] == nil)
        #expect(bookmarks.roots == [kept])
        #expect(AgentBookmarks.delete(["id": kept.id.uuidString], from: bookmarks)["error"] == nil)
        #expect(bookmarks.isEmpty)
    }

    @Test func emptyFoldersCanBeDeleted() {
        let empty = Bookmark.folder("Empty", [])
        let bookmarks = Bookmarks()
        let original = bookmarks.roots
        defer { bookmarks.replaceAll(with: original) }
        bookmarks.replaceAll(with: [empty])
        #expect(AgentBookmarks.delete(["id": empty.id.uuidString], from: bookmarks)["error"] == nil)
        #expect(bookmarks.isEmpty)
    }

    @Test func deletionHasADestructiveToolAndARealBrowserHandler() throws {
        let tool = try #require(Mcp.byName["bookmark_delete"])
        #expect(tool.required == ["id"])
        #expect(tool.hint.destroys && !tool.hint.reads && !tool.hint.outside)
        #expect(tool.listed(for: Mcp.Audience()))
        #expect(tool.listed(for: Mcp.Audience(inner: true)))
        for audience in [Mcp.Audience(inner: true, sub: true),
                         Mcp.Audience(inner: true, sub: true, profile: "context_explorer"),
                         Mcp.Audience(inner: true, phoneReadOnly: true)] {
            #expect(!tool.listed(for: audience))
            #expect((Mcp.phoneRefusal(tool.name, audience) ?? Mcp.refusal(tool.name, [:], audience)) != nil)
        }
        #expect(Bench.keptVerbs["agent-bookmark-delete"] != nil)
    }

    @Test func everyBookmarkMutationIsUnavailableToReadOnlyOrChildTasks() throws {
        for name in ["bookmark_add", "bookmark_delete", "bookmark_update", "bookmark_move", "bookmark_folder_create"] {
            let tool = try #require(Mcp.byName[name])
            #expect(tool.listed(for: Mcp.Audience(inner: true)))
            for audience in [Mcp.Audience(inner: true, sub: true),
                             Mcp.Audience(inner: true, sub: true, profile: "context_explorer"),
                             Mcp.Audience(inner: true, phoneReadOnly: true)] {
                #expect(!tool.listed(for: audience))
                #expect((Mcp.phoneRefusal(name, audience) ?? Mcp.refusal(name, [:], audience)) != nil)
            }
        }
        for verb in ["agent-bookmark-update", "agent-bookmark-move", "agent-bookmark-folder-create"] {
            #expect(Bench.keptVerbs[verb] != nil)
        }
    }
}
