import Foundation
import Testing
@testable import Fast

// Arc's StorableSidebar.json, cut down to the shape a real one has (read
// from a real Arc install): a global container, then one whose items list
// alternates ids and items, its spaces, and its favorites by profile.
struct ArcSidebarTests {
    static func item(_ id: String, parent: String?, children: [String] = [], tab: String? = nil, title: String? = nil, saved: String? = nil, kind: String = "itemContainer", created: Double? = nil) -> [String: Any] {
        var data: [String: Any] = [kind: [String: Any]()]
        if let tab {
            var fields: [String: Any] = ["savedURL": tab, "savedMuteStatus": "allowAudio"]
            if let saved { fields["savedTitle"] = saved }
            data = ["tab": fields]
        }
        var out: [String: Any] = ["id": id, "childrenIds": children, "data": data, "isUnread": false]
        out["parentID"] = parent
        out["title"] = title ?? NSNull()
        out["createdAt"] = created
        return out
    }

    static var sidebar: Data {
        let items: [[String: Any]] = [
            item("fav", parent: nil, children: ["t1", "t2"]),
            item("t1", parent: "fav", tab: "https://mail.google.com/mail/u/0/", saved: "Inbox"),
            item("t2", parent: "fav", tab: "https://calendar.example/", title: "My calendar", saved: "Calendar - Week"),
            item("fav1", parent: nil, children: ["t3"]),
            item("t3", parent: "fav1", tab: "https://work.example/", saved: "Work"),
            item("pinned", parent: nil, children: ["folder", "t4", "split", "t9"]),
            item("folder", parent: "pinned", children: ["t5"], title: "Reading", kind: "list"),
            item("t5", parent: "folder", tab: "https://read.example/article", saved: "Article", created: 774_376_691),
            // The same page as a favorite: once is enough.
            item("t4", parent: "pinned", tab: "https://mail.google.com/mail/u/0/", saved: "Inbox again"),
            item("split", parent: "pinned", children: ["t6", "t7"], kind: "splitView"),
            item("t6", parent: "split", tab: "https://left.example/", saved: "Left"),
            item("t7", parent: "split", tab: "https://right.example/", saved: "Right"),
            item("t9", parent: "pinned", tab: "arc://newtab", saved: "New Tab"),
            item("unpinned", parent: nil, children: ["t8"]),
            item("t8", parent: "unpinned", tab: "https://today.example/", saved: "Today"),
            // A loop in a damaged file.
            item("loop", parent: "loop", children: ["loop"]),
        ]
        var list: [Any] = []
        for item in items { list += [item["id"]!, item] }
        let json: [String: Any] = [
            "version": 1,
            "sidebar": ["containers": [
                ["global": [String: Any]()],
                [
                    "items": list,
                    "spaces": [
                        "space-1",
                        ["id": "space-1", "title": "Home", "profile": ["default": [String: Any]()],
                         "customInfo": ["iconType": ["emoji": 127968, "emoji_v2": "🏠"],
                                        "windowTheme": ["background": ["single": ["_0": ["style": ["color": ["_0": ["blendedSingleColor": ["_0": [
                                            "modifiers": ["overlay": "grain", "noiseFactor": 0.9],
                                            "color": ["red": 0.5, "green": 0.25, "blue": 1.0, "alpha": 1.0]]]]]]]]]]],
                         "containerIDs": ["pinned", "pinned", "unpinned", "unpinned"]],
                        "space-2",
                        ["id": "space-2", "title": "Broken", "profile": ["default": [String: Any]()],
                         "containerIDs": ["pinned", "loop"]],
                    ],
                    "topAppsContainerIDs": [
                        ["default": [String: Any]()], "fav",
                        ["custom": ["_0": ["directoryBasename": "Profile 1", "machineID": "M"]]], "fav1",
                    ],
                ],
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func eachSpaceIsAPlaceWithItsLook() {
        let places = ArcSidebar.places(in: Self.sidebar, names: ["Profile 1": "Work"])
        let home = places.first { $0.name == "Home" }
        #expect(home?.id == "Arc:space-1")
        #expect(home?.emoji == "🏠")
        #expect(home?.color == "8040FF")
        #expect(home?.grain == Grain.fromArc(0.9))
        #expect(home?.shared == true)
        #expect(home?.profile == "Default")
    }

    @Test func onlyATitleThatDiffersFromThePageIsAName() {
        let items: [[String: Any]] = [
            Self.item("pinned", parent: nil, children: ["same", "bare", "renamed"]),
            Self.item("same", parent: "pinned", tab: "https://same.example/", title: "Same", saved: "Same"),
            Self.item("bare", parent: "pinned", tab: "https://bare.example/", title: "Named, never loaded"),
            Self.item("renamed", parent: "pinned", tab: "https://docs.example/", title: "Specs", saved: "Untitled document - Docs"),
        ]
        var list: [Any] = []
        for item in items { list += [item["id"]!, item] }
        let json: [String: Any] = ["sidebar": ["containers": [["items": list, "spaces": [
            "s", ["id": "s", "title": "S", "profile": ["default": [String: Any]()], "containerIDs": ["pinned", "pinned"]],
        ]]]]]
        let kept = ArcSidebar.places(in: try! JSONSerialization.data(withJSONObject: json)).first?.kept ?? []
        #expect(kept.map(\.name) == [nil, "Named, never loaded", "Specs"])
        #expect(kept.map(\.title) == ["Same", "Named, never loaded", "Untitled document - Docs"])
    }

    @Test func favoritesArePinsAndASpacesPinnedTabsStay() {
        let places = ArcSidebar.places(in: Self.sidebar, names: ["Profile 1": "Work"])
        let home = places.first { $0.name == "Home" }
        // The profile's favorites are the first space's pins; the space's
        // pinned tabs, folders opened in place, are tabs that stay, and
        // the favorite pinned there again comes once.
        #expect(home?.pinned.map(\.url.absoluteString) == ["https://mail.google.com/mail/u/0/", "https://calendar.example/"])
        #expect(home?.kept.map(\.url.absoluteString) == ["https://read.example/article", "https://left.example/", "https://right.example/"])
        // What a person named it in Arc is its name, kept apart from the
        // page's own title, which would replace it once the page loads.
        #expect(home?.pinned[1].name == "My calendar")
        #expect(home?.pinned[1].title == "Calendar - Week")
        #expect(home?.pinned[0].name == nil)
        #expect(home?.pinned[0].title == "Inbox")
        // A profile with favorites and no space: a place named for it,
        // signed in as itself.
        let work = places.first { $0.profile == "Profile 1" }
        #expect(work?.name == "Work")
        #expect(work?.shared == false)
        #expect(work?.pinned.map(\.url.host) == ["work.example"])
    }

    @Test func aFolderAmongThePinnedIsKeptAsOne() {
        let home = ArcSidebar.places(in: Self.sidebar).first { $0.name == "Home" }
        // A folder's tabs name it, the ones out of any folder, a split's
        // included, name none (Kept.swift makes a folder of each name).
        #expect(home?.kept.map(\.folder) == ["Reading", nil, nil])
        #expect(home?.pinned.allSatisfy { $0.folder == nil } == true)
        #expect(home?.open.allSatisfy { $0.folder == nil } == true)
    }

    @Test func aTabSaysWhenItWasMadeInArc() {
        let home = ArcSidebar.places(in: Self.sidebar).first { $0.name == "Home" }
        // Seconds since 2001; a tab with none, none.
        #expect(home?.kept.map(\.added) == [Date(timeIntervalSinceReferenceDate: 774_376_691), nil, nil])
    }

    @Test func todaysTabsAreTheSpacesOpenOnes() {
        let home = ArcSidebar.places(in: Self.sidebar).first { $0.name == "Home" }
        #expect(home?.open.map(\.url.host) == ["today.example"])
        #expect(home?.kept.contains { $0.url.host == "today.example" } == false)
    }

    @Test func somethingElseReadsAsNoPlaces() {
        #expect(ArcSidebar.places(in: Data("{}".utf8)).isEmpty)
        #expect(ArcSidebar.places(in: Data("not json".utf8)).isEmpty)
    }

    @Test func unreadableSidebarShapesHaveOnlyFixedNumericDiagnostics() throws {
        var codes: [Int] = []
        #expect(ArcSidebar.places(in: Data("not json".utf8), diagnostic: { codes.append($0) }).isEmpty)
        #expect(codes == [TabImport.Trouble.damaged.code])
        codes = []
        let unknown = try JSONSerialization.data(withJSONObject: ["private-title": "https://private.example/secret"])
        #expect(ArcSidebar.places(in: unknown, diagnostic: { codes.append($0) }).isEmpty)
        #expect(codes == [TabImport.Trouble.newer(version: nil).code])
    }

    @Test func knownAndEmptySidebarShapesNeedNoDiagnostic() throws {
        var codes: [Int] = []
        let known = ArcSidebar.places(in: Self.sidebar, diagnostic: { codes.append($0) })
        #expect(known == ArcSidebar.places(in: Self.sidebar))
        let empty: [String: Any] = ["sidebar": ["containers": [
            ["global": [String: Any]()],
            ["spaces": [["id": "empty", "containerIDs": [Any]()]]],
        ]]]
        let places = ArcSidebar.places(in: try JSONSerialization.data(withJSONObject: empty), diagnostic: { codes.append($0) })
        #expect(places.count == 1 && places[0].isEmpty)
        #expect(codes.isEmpty)
    }

    @Test func unsupportedOrDanglingRootsAreNotSilentlyCalledEmpty() throws {
        let items = [Self.item("root", parent: nil, children: ["tab"]),
                     Self.item("tab", parent: "root", tab: "https://kept.example/")]
        let modern: [Any] = [["pinned": [String: Any]()], "private-root"]
        let valid: [String: Any] = ["id": "valid", "containerIDs": ["pinned", "root"], "newContainerIDs": modern]
        let broken: [[String: Any]] = [
            ["id": "modern", "newContainerIDs": modern],
            ["id": "wrong-shape", "containerIDs": "private-root"],
            ["id": "missing", "containerIDs": ["pinned", "missing-root"]],
            ["id": "not-an-id", "containerIDs": ["unpinned", 7]],
            ["id": "odd", "containerIDs": ["pinned"]],
        ]
        var containers: [[String: Any]] = broken.map { ["items": items, "spaces": [$0, valid]] }
        let appShapes: [Any] = ["private-root", [["default": [String: Any]()], "missing-favorites"], [["default": [String: Any]()]]]
        for apps in appShapes {
            containers.append(["items": items, "topAppsContainerIDs": apps, "spaces": [valid]])
        }
        for container in containers {
            let data = try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [container]]])
            var codes: [Int] = []
            let places = ArcSidebar.places(in: data, diagnostic: { codes.append($0) })
            #expect(places == ArcSidebar.places(in: data))
            #expect(places.first { $0.id == "Arc:valid" }?.kept.map(\.url.absoluteString) == ["https://kept.example/"])
            #expect(codes == [TabImport.Trouble.newer(version: nil).code])
        }
        // Several broken roots still produce one fixed code, never
        // identifiers, names, addresses or an event for every item.
        let repeated = try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": containers]])
        var codes: [Int] = []
        _ = ArcSidebar.places(in: repeated, diagnostic: { codes.append($0) })
        #expect(codes == [TabImport.Trouble.newer(version: nil).code])
    }

    @Test func unknownRootKindsAndParallelModernRootsLeaveLegacyImportQuiet() throws {
        let items = [Self.item("root", parent: nil, children: ["tab"]),
                     Self.item("tab", parent: "root", tab: "https://kept.example/")]
        let json: [String: Any] = ["sidebar": ["containers": [["items": items, "spaces": [[
            "id": "valid", "containerIDs": ["metadata", "not-an-import-root", "pinned", "root"],
            "newContainerIDs": [["pinned": [String: Any]()], "root"],
        ]]]]]]
        var codes: [Int] = []
        let places = ArcSidebar.places(in: try JSONSerialization.data(withJSONObject: json), diagnostic: { codes.append($0) })
        #expect(places.first?.kept.count == 1)
        #expect(codes.isEmpty)
    }

    @Test func aSpaceLeftInArcsOwnLookHasNone() {
        #expect(ArcSidebar.theme(nil).color == nil)
        #expect(ArcSidebar.theme([String: Any]()).color == nil)
    }

    @Test func diaRenamedTabsComeWithTheirNames() {
        func tab(_ url: String, _ title: String, custom: Any? = nil) -> [String: Any] {
            var out: [String: Any] = ["id": UUID().uuidString, "contents": [["variant": ["webContent": ["_0": ["url": url, "title": title]]]]]]
            out["customTitle"] = custom
            return out
        }
        let json: [String: Any] = ["version": 3, "containers": [
            ["id": ["profileID": "Default", "container": ["favorites": [String: Any]()]],
             "tabs": [tab("https://docs.example/", "Untitled document", custom: "Specs"), tab("https://plain.example/", "Plain"),
                      tab("https://wrapped.example/", "Page", custom: ["_0": "Wrapped"]), tab("https://same.example/", "Same", custom: "Same")]],
        ]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let pins = DiaContainers.places(in: data).first?.pinned ?? []
        #expect(pins.map(\.name) == ["Specs", nil, "Wrapped", nil])
        #expect(pins.map(\.title) == ["Untitled document", "Plain", "Page", "Same"])
        #expect(DiaContainers.names(in: data) == ["https://docs.example/": "Specs", "https://wrapped.example/": "Wrapped"])
    }

    @Test func diaFavoritesArePinsAndWindowsOpen() {
        func tab(_ url: String, _ title: String) -> [String: Any] {
            ["id": UUID().uuidString, "contents": [["variant": ["webContent": ["_0": ["url": url, "title": title]]]]]]
        }
        let json: [String: Any] = ["version": 1, "containers": [
            ["id": ["profileID": "Profile 2", "container": ["favorites": [String: Any]()]], "tabs": [tab("https://two.example/", "Two")]],
            ["id": ["profileID": "Default", "container": ["window": ["_0": "W"]]],
             "tabs": [tab("https://open.example/", "Open"), ["id": "n", "contents": [["variant": ["newTabPage": [String: Any]()]]]]]],
            ["id": ["profileID": "Default", "container": ["favorites": [String: Any]()]],
             "tabs": [tab("https://www.mail.example/", "Mail"), tab("https://open.example/", "Open again")]],
        ]]
        let places = DiaContainers.places(in: try! JSONSerialization.data(withJSONObject: json), names: ["Default": "Me"])
        #expect(places.map(\.name) == ["Me", "Profile 2"])
        #expect(places[0].shared == true)
        #expect(places[1].shared == false)
        #expect(places[0].pinned.map(\.url.host) == ["www.mail.example", "open.example"])
        // Pinned there, so not open a second time, by its key.
        #expect(places[0].open.isEmpty)
        #expect(places[1].pinned.map(\.url.host) == ["two.example"])
    }

    @Test func onlyOpenTabsAreNothingWithoutTheOpenOnes() {
        let entry = TabImport.Entry(url: URL(string: "https://open.example/")!, title: "Open")
        let place = TabImport.Place(id: "Chrome:Profile 3", name: "Three", profile: "Profile 3", shared: false, pinned: [], open: [entry])
        #expect(!place.holds(withOpen: false))
        #expect(place.holds(withOpen: true))
    }

    @Test func hostCaseMatchesButDifferentRoutesStaySeparate() {
        let a = TabImport.key(URL(string: "https://Example.com/path/#top")!)
        let b = TabImport.key(URL(string: "https://example.com/path/#top")!)
        #expect(a == b)
        #expect(TabImport.key(URL(string: "https://example.com/#one")!) != TabImport.key(URL(string: "https://example.com/#two")!))
        #expect(TabImport.key(URL(string: "http://example.com/")!) != TabImport.key(URL(string: "https://example.com/")!))
        #expect(TabImport.key(URL(string: "https://www.example.com/")!) != TabImport.key(URL(string: "https://example.com/")!))
        #expect(TabImport.key(URL(string: "https://example.com/?q=1")!) != TabImport.key(URL(string: "https://example.com/?q=2")!))
    }

    @Test func theSamePageInTwoSpacesIsKeptInBoth() throws {
        var json = try #require(JSONSerialization.jsonObject(with: Self.sidebar) as? [String: Any])
        var sidebar = try #require(json["sidebar"] as? [String: Any])
        var containers = try #require(sidebar["containers"] as? [[String: Any]])
        var spaces = try #require(containers[1]["spaces"] as? [Any])
        spaces += ["another", ["id": "another", "title": "Another", "containerIDs": ["pinned", "pinned"]]]
        containers[1]["spaces"] = spaces
        sidebar["containers"] = containers
        json["sidebar"] = sidebar
        let places = ArcSidebar.places(in: try JSONSerialization.data(withJSONObject: json))
        #expect(places.first { $0.name == "Home" }?.kept.contains { $0.url.host == "read.example" } == true)
        #expect(places.first { $0.name == "Another" }?.kept.contains { $0.url.host == "read.example" } == true)
    }

    @Test func nestedFoldersRetainTheirPathAndSplitsRetainBothPages() throws {
        let items = [Self.item("root", parent: nil, children: ["outer", "split"]),
                     Self.item("outer", parent: "root", children: ["inner"], title: "Work", kind: "list"),
                     Self.item("inner", parent: "outer", children: ["tab"], title: "Research", kind: "list"),
                     Self.item("tab", parent: "inner", tab: "https://nested.test/"),
                     Self.item("split", parent: "root", children: ["left", "right"], kind: "splitView"),
                     Self.item("left", parent: "split", tab: "https://left.test/"),
                     Self.item("right", parent: "split", tab: "https://right.test/")]
        let json: [String: Any] = ["sidebar": ["containers": [["items": items,
            "spaces": [["id": "work", "containerIDs": ["pinned", "root"]]]]]]]
        let place = try #require(ArcSidebar.places(in: JSONSerialization.data(withJSONObject: json)).first)
        #expect(place.kept[0].folder == "Work › Research")
        #expect(place.splits.count == 1)
        #expect(place.splits[0].first.host == "left.test")
        #expect(place.splits[0].second.host == "right.test")
    }
}
