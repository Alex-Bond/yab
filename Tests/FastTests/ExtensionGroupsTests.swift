import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// chrome.tabGroups onto Yab's folders (ExtensionGroups.swift): a group's id
/// is a number from its folder's, the same each time, and never Chrome's -1.
@Suite struct ExtensionGroupsTests {
    @MainActor @Test func aQueryDoesNotUseTheLivePortsPreInsertionMembership() throws {
        let script = ExtensionShims.script
        let comment = try #require(script.range(of: "  // Tabs as Chrome describes them."))
        let start = try #require(script.range(of: "  if (chrome.tabs) {", range: comment.upperBound..<script.endIndex))
        let end = try #require(script.range(of: "    const tabsIn", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript("""
        (() => {
          const chrome={tabs:{}},runtime={getManifest:()=>({permissions:['tabs']})};
          const groupsAllowed=true,groupsLive=true,groupMembers=[-1,5,5];
          const native=(api)=> {if(api!=='tabGroups.membership')throw Error(api);return Promise.resolve({members:[-1,-1,5,5]});};
          const tabs=[{id:9,index:0,url:'https://new.invalid'},{id:10,index:1,url:'https://old.invalid'},
                      {id:20,index:2,url:'https://a.invalid'},{id:30,index:3,url:'https://b.invalid'}];
        \(script[start.lowerBound..<end.lowerBound])
          mend(tabs).then(()=>globalThis.result=tabs.map(tab=>[tab.id,tab.groupId]));
          }
        })()
        """)
        try #require(context.exception == nil, "\(context.exception!)")
        let text = try #require(context.evaluateScript("JSON.stringify(result)")?.toString())
        let actual = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[Int]])
        #expect(actual == [[9,-1],[10,-1],[20,5],[30,5]])
    }
    @Test func aFoldersGroupIdIsStableAndPositive() {
        let id = UUID()
        #expect(ExtensionGroups.id(of: id) == ExtensionGroups.id(of: id))
        for _ in 0..<200 { #expect(ExtensionGroups.id(of: UUID()) > 0) }
    }

    @Test func chromesNineColors() {
        #expect(ExtensionGroups.colors == ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"])
    }

    /// The groups in the order they stand, each once.
    @Test func groupsInRowOrder() {
        #expect(ExtensionGroups.order([-1, 7, 7, -1, 3, 7, 5]) == [7, 3, 5])
        #expect(ExtensionGroups.order([-1, -1]).isEmpty)
    }

    /// onMoved: the group that moved past the others, not the others.
    @Test func onlyTheGroupThatMovedIsMoved() {
        #expect(ExtensionGroups.moved(from: [1, 2, 3], to: [1, 2, 3]).isEmpty)
        #expect(ExtensionGroups.moved(from: [1, 2, 3, 4], to: [2, 3, 4, 1]) == [1])
        #expect(ExtensionGroups.moved(from: [1, 2, 3, 4], to: [4, 1, 2, 3]) == [4])
        #expect(ExtensionGroups.moved(from: [1, 2], to: [2, 1]).count == 1)
        // Made or gone in between moves nothing.
        #expect(ExtensionGroups.moved(from: [1, 2], to: [1, 9, 2]).isEmpty)
        #expect(ExtensionGroups.moved(from: [1, 9, 2], to: [1, 2]).isEmpty)
    }

    /// tabs.onUpdated {groupId}: a tab whose group changed, by its place
    /// now; a tab moved without changing group is not told.
    @Test func tabsWhoseGroupChanged() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let before = [a: -1, b: -1, c: 5]
        #expect(ExtensionGroups.regrouped(from: before, to: [(c, 5), (a, 9), (b, 9)]) == [[1, 9], [2, 9]])
        #expect(ExtensionGroups.regrouped(from: before, to: [(b, -1), (a, -1), (c, -1)]) == [[2, -1]])
        // A tab not seen before was in none.
        #expect(ExtensionGroups.regrouped(from: before, to: [(d, -1)]).isEmpty)
        #expect(ExtensionGroups.regrouped(from: before, to: [(d, 5)]) == [[0, 5]])
    }

    /// tabGroups.move of a folder of today's tabs: after the kept, -1 the
    /// end, never into another folder's run.
    @Test func whereATodayFolderGoes() throws {
        let other = UUID()
        let rest: [(folder: UUID?, kept: Bool)] = [(nil, true), (nil, false), (other, false), (other, false), (nil, false)]
        #expect(try Browser.todayPlace(-1, in: rest) == 5)
        #expect(try Browser.todayPlace(0, in: rest) == 1)
        #expect(try Browser.todayPlace(2, in: rest) == 2)
        #expect(try Browser.todayPlace(4, in: rest) == 4)
        #expect(try Browser.todayPlace(99, in: rest) == 5)
        #expect(throws: Browser.GroupMiddle.self) { try Browser.todayPlace(3, in: rest) }
    }

    /// readingList's events between two lists: removed, then added and
    /// changed in the list's order; the same list tells nothing.
    @Test func readingListEvents() {
        let one: [String: Any] = ["url": "https://a.example/", "title": "A", "hasBeenRead": false, "creationTime": 1.0, "lastUpdateTime": 1.0]
        let two: [String: Any] = ["url": "https://b.example/", "title": "B", "hasBeenRead": false, "creationTime": 2.0, "lastUpdateTime": 2.0]
        var read = one
        read["hasBeenRead"] = true
        read["lastUpdateTime"] = 3.0
        #expect(ExtensionReadingList.diff([one], [one]).isEmpty)
        let names = { (events: [[Any]]) in events.map { $0[0] as? String ?? "" } }
        #expect(names(ExtensionReadingList.diff([], [one])) == ["onEntryAdded"])
        #expect(names(ExtensionReadingList.diff([one, two], [read])) == ["onEntryRemoved", "onEntryUpdated"])
        #expect((ExtensionReadingList.diff([one, two], [read])[0][1] as? [String: Any])?["url"] as? String == "https://b.example/")
    }
}
