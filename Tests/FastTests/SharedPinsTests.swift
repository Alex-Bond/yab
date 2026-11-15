import Foundation
import Testing
@testable import Fast

/// The pins every space shares (SharedPins.swift, docs/shared-pins.md): the
/// rules as pure functions, then a window's real tabs through switches,
/// pins, merges and splits. One at a time: the shared row is one file.
@Suite(.serialized)
struct SharedPinsTests {
    private func entry(_ url: String, pin: String? = "P", id: String? = UUID().uuidString) -> Session.Entry {
        Session.Entry(url: url, title: url, pin: pin, name: nil, seen: nil, id: id)
    }

    // MARK: the rules

    /// A Mac of its own: a settings suite and a folder nobody else reads.
    private struct Install {
        let name = "dev.serafim.fast.tests.pins.\(UUID().uuidString)"
        let settings: UserDefaults
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID().uuidString)", isDirectory: true)

        init() {
            settings = UserDefaults(suiteName: name)!
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func keep(_ file: String) {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data("[]".utf8))
        }

        func decide() -> Bool { SharedPins.decide(settings: settings, folder: folder) }

        func close() {
            settings.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func aNewMacSharesItsPinsAndKeepsThatOnceItIsInUse() {
        let mac = Install()
        defer { mac.close() }
        #expect(!SharedPins.inUse(folder: mac.folder, settings: mac.settings))
        #expect(mac.decide())
        // Written down at once, and only as this Mac's own default.
        #expect(mac.settings.object(forKey: SharedPins.key) as? Bool == true)
        #expect(mac.settings.bool(forKey: SharedPins.decidedKey))
        // The welcome done and a session kept later change nothing.
        mac.settings.set(true, forKey: "welcomed")
        mac.keep("session.json")
        mac.keep("spaces.json")
        #expect(mac.decide())
    }

    @Test func aMacInUseBeforeKeepsEachSpacesPins() {
        for marker in ["spaces.json", "session.json", "history.json", "welcomed", "glyph"] {
            let mac = Install()
            defer { mac.close() }
            switch marker {
            case "welcomed": mac.settings.set(true, forKey: "welcomed")
            case "glyph": mac.settings.set("letters", forKey: "glyph")
            default: mac.keep(marker)
            }
            #expect(SharedPins.inUse(folder: mac.folder, settings: mac.settings), "\(marker)")
            #expect(!mac.decide(), "\(marker)")
            #expect(mac.settings.object(forKey: SharedPins.key) as? Bool == false, "\(marker)")
            // Nothing done there turns it on by itself: emptied of its
            // files, it is still the Mac that decided In Each Space.
            try? FileManager.default.removeItem(at: mac.folder.appendingPathComponent(marker))
            mac.settings.removeObject(forKey: "welcomed")
            mac.settings.removeObject(forKey: "glyph")
            #expect(!mac.decide(), "\(marker)")
        }
    }

    @Test func aChoiceStaysOnEitherMac() {
        let new = Install(), used = Install()
        defer { new.close(); used.close() }
        used.keep("spaces.json")
        _ = new.decide(); _ = used.decide()
        SharedPins.chose(false, settings: new.settings)
        SharedPins.chose(true, settings: used.settings)
        #expect(!new.decide())
        #expect(used.decide())
        #expect(!new.settings.bool(forKey: SharedPins.decidedKey))
        #expect(!used.settings.bool(forKey: SharedPins.decidedKey))
        // A choice is not a default: joining sync leaves it to sync.
        #expect(!SharedPins.joining(settings: used.settings))
        #expect(!SharedPins.joiningSync(used.settings))
        #expect(used.decide())
    }

    @Test func aNewMacJoiningAnAccountTakesItsPins() {
        // The account's Macs are in use, at In Each Space.
        let mac = Install()
        defer { mac.close() }
        #expect(mac.decide())
        #expect(SharedPins.joining(settings: mac.settings))
        #expect(mac.settings.object(forKey: SharedPins.key) == nil)
        // Nothing is decided or written while it catches up.
        #expect(!mac.decide())
        SharedPins.chose(true, settings: mac.settings)
        #expect(mac.settings.object(forKey: SharedPins.key) == nil)
        #expect(!SharedPins.holdsApart(mac.settings))
        mac.settings.set(false, forKey: SharedPins.key) // as sync writes it
        #expect(SharedPins.joined(settings: mac.settings) == false)
        #expect(!mac.decide())
        #expect(SharedPins.joined(settings: mac.settings) == nil)

        // An account of new Macs, In Every Space.
        let other = Install()
        defer { other.close() }
        _ = other.decide()
        SharedPins.joining(settings: other.settings)
        other.settings.set(true, forKey: SharedPins.key)
        #expect(SharedPins.joined(settings: other.settings) == true)
        #expect(other.decide())

        // An account from before the choice: its Macs were in use.
        let third = Install()
        defer { third.close() }
        _ = third.decide()
        SharedPins.joining(settings: third.settings)
        #expect(SharedPins.joined(settings: third.settings) == false)
        #expect(third.settings.object(forKey: SharedPins.key) as? Bool == false)
        #expect(!third.settings.bool(forKey: SharedPins.decidedKey))
    }

    @Test func aMacInUseJoiningAnAccountInEverySpaceKeepsItsPinsApart() {
        let mac = Install()
        defer { mac.close() }
        mac.keep("session.json")
        #expect(!mac.decide())
        #expect(!SharedPins.joining(settings: mac.settings))
        #expect(SharedPins.joiningSync(mac.settings))
        #expect(SharedPins.holdsApart(mac.settings))
        #expect(!mac.decide())
        #expect(SharedPins.joined(settings: mac.settings) == false)
        // Sent as its choice: the account's other Macs follow it.
        #expect(mac.settings.object(forKey: SharedPins.key) as? Bool == false)
        #expect(!mac.settings.bool(forKey: SharedPins.decidedKey))
        #expect(!SharedPins.holdsApart(mac.settings))
    }

    @Test func syncTurnedOffBeforeAJoinCaughtUpPutsBackWhatTheMacHad() {
        let mac = Install()
        defer { mac.close() }
        _ = mac.decide()
        SharedPins.joining(settings: mac.settings)
        #expect(SharedPins.leftJoining(settings: mac.settings) == true)
        #expect(mac.decide())
        #expect(mac.settings.bool(forKey: SharedPins.decidedKey))
        #expect(SharedPins.leftJoining(settings: mac.settings) == nil)
    }

    @Test func theDefaultsOwnKeysNeverSync() {
        #expect(SyncShapes.syncs(SharedPins.key))
        #expect(!SyncShapes.syncs(SharedPins.decidedKey))
        #expect(!SyncShapes.syncs(SharedPins.joiningKey))
    }

    @Test func mergingKeepsTheFirstSpaceFirstAndDropsOnlyTheSameAddress() {
        let personal = ["https://mail.example.test/u/0/", "https://calendar.example.test/"]
        let work = ["https://calendar.example.test/", "https://mail.example.test/u/1/", "https://linear.example.test/"]
        let study = ["https://calendar.example.test/", "https://music.example.test/"]
        let merged = SharedPins.merge([personal, work, study]) { $0 }
        #expect(merged.kept == ["https://mail.example.test/u/0/", "https://calendar.example.test/",
                                "https://mail.example.test/u/1/", "https://linear.example.test/", "https://music.example.test/"])
        #expect(merged.dropped == ["https://calendar.example.test/", "https://calendar.example.test/"])
    }

    @Test func aBusyPinIsNeverADuplicate() {
        let merged = SharedPins.merge([[("https://meet.example.test/abc", false)], [("https://meet.example.test/abc", true)]]) { $0.1 ? nil : $0.0 }
        #expect(merged.kept.count == 2)
        #expect(merged.dropped.isEmpty)
    }

    @Test func thePinsGoToTheSpaceOnScreenOnlyWhenItShowedThem() {
        let work = UUID()
        #expect(SharedPins.heir(onScreen: work, showing: true, spacesOn: true) == work)
        #expect(SharedPins.heir(onScreen: work, showing: false, spacesOn: true) == Space.firstID)
        #expect(SharedPins.heir(onScreen: work, showing: true, spacesOn: false) == Space.firstID)
    }

    @Test func anOrderPutsWhatItDoesntNameAfter() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        #expect(SharedPins.ordered([d, a, c, b], id: { $0 }, by: [b, c, a]) == [b, c, a, d])
        #expect(SharedPins.ordered([d, a], id: { $0 }, by: nil) == [d, a])
    }

    @Test func aRowWithoutItsPinsKeepsItsFrontAndPairs() {
        let shape = Session.Shape(tabs: [entry("https://a.test/"), entry("https://b.test/", pin: nil), entry("https://c.test/", pin: nil),
                                         entry("https://d.test/", pin: nil)],
                                  active: 2, pairs: [Session.Pair(first: 2, second: 3, share: 0.5)])
        let loose = SharedPins.unpinned(shape)
        #expect(loose.tabs.map(\.url) == ["https://b.test/", "https://c.test/", "https://d.test/"])
        #expect(loose.active == 1)
        #expect(loose.pairs?.first.map { [$0.first, $0.second] } == [1, 2])
        // Left on a pin: none in front, not its first tab.
        #expect(SharedPins.unpinned(Session.Shape(tabs: shape.tabs, active: 0)).front == nil)
        // Left with none: none still.
        #expect(SharedPins.unpinned(Session.Shape(tabs: shape.tabs, front: nil)).front == nil)
    }

    @Test func syncCarriesTheSharedPinsAsTheFirstSpacesAndTakesThemApartAgain() {
        let pins = [entry("https://mail.example.test/u/0/"), entry("https://calendar.example.test/")]
        let first = Session.Shape(tabs: [entry("https://a.test/", pin: nil), entry("https://b.test/", pin: nil), entry("https://c.test/", pin: nil)],
                                  active: 1, pairs: [Session.Pair(first: 1, second: 2, share: 0.4)])
        let folded = SharedPins.folded(pins, into: first)
        #expect(folded.tabs.map(\.url) == pins.map(\.url) + first.tabs.map(\.url))
        #expect(folded.active == 3)
        #expect(folded.pairs?.first.map { [$0.first, $0.second] } == [3, 4])
        let (back, rest) = SharedPins.unfolded(folded)
        #expect(back.map(\.url) == pins.map(\.url))
        #expect(rest.tabs.map(\.url) == first.tabs.map(\.url))
        #expect(rest.active == 1)
        #expect(rest.pairs?.first.map { [$0.first, $0.second] } == [1, 2])

        // Left on the second shared pin: sent left on it, back as -2.
        let onPin = Session.Shape(tabs: first.tabs, active: -2)
        #expect(SharedPins.folded(pins, into: onPin).active == 1)
        #expect(SharedPins.unfolded(SharedPins.folded(pins, into: onPin)).rest.active == -2)
        // Nothing shared: the row as it is.
        #expect(SharedPins.folded([], into: first).tabs.count == 3)
        // Left with none in front: sent so, and back so.
        let bare = Session.Shape(tabs: first.tabs, front: nil)
        #expect(SharedPins.folded(pins, into: bare).front == nil)
        #expect(SharedPins.unfolded(SharedPins.folded(pins, into: bare)).rest.front == nil)
    }

    @Test func thePinsChoiceSyncsAsASetting() {
        #expect(SyncShapes.syncs(SharedPins.key))
        let values = SyncShapes.settings([SharedPins.key: true])
        #expect(values[SharedPins.key]?["value"]?.bool == true)
    }

    @MainActor @Test func importingIntoAnUnopenedSpaceCountsTheWholeSharedGrid() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Import Work"), client = world.space("Import Client", own: true)
        world.share(true)
        let existing = (0..<8).map { world.page("https://shared-import.test/\($0)") }
        browser.lay(existing)
        for tab in existing { browser.pin(tab) }
        let incoming = (7..<11).map { TabImport.Entry(url: URL(string: "https://shared-import.test/\($0)")!, title: "T\($0)") }
        let imported = browser.lay(incoming, kept: [], open: [], into: work)
        #expect(imported.pinned == 1 && imported.open == 2)
        #expect(browser.sharedPins?.count == 9)
        #expect(Session.read(space: Space.pinsID).tabs.count == 9)
        let workFile = Session.read(space: work, window: world.id)
        #expect(workFile.tabs.count == 2 && workFile.tabs.allSatisfy { $0.pin == nil && $0.kept == true })
        browser.switchSpace(to: work)
        #expect(browser.tabs.filter { $0.everywhere != nil }.count == 9)
        #expect(browser.tabs.filter { $0.kept }.count == 2)
        let repeated = browser.lay(incoming, kept: [], open: [], into: work)
        #expect(repeated.pinned == 0 && repeated.open == 0)
        browser.unpin(try #require(browser.sharedPins?.last))
        #expect(browser.lay(incoming, kept: [], open: [], into: work).pinned == 0)
        let own = browser.lay(incoming, kept: [], open: [], into: client)
        #expect(own.pinned == 4)
        #expect(Session.read(space: Space.pinsID).tabs.count == 8)
    }

    @MainActor @Test func nativeContextListsAParkedSharedPinOnceAndMarksItsScope() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Native Work"), client = world.space("Native Client", own: true)
        world.share(true)
        let gmail = world.page("https://mail.example.test/u/0/")
        browser.lay([gmail]); browser.pin(gmail)
        browser.switchSpace(to: work)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let control = NativeControl(file: folder.appendingPathComponent("native.json"))
        let session = Agents.shared.attach(name: "Shared pins test")
        session.nativeWindowID = nil
        Store.settings.set(true, forKey: SharedPins.key)
        defer { Agents.shared.detach(session.id); try? FileManager.default.removeItem(at: folder) }
        func context() -> [String: Any] {
            var result: [String: Any] = [:]
            control.handle("agent-native-context", request: ["session": session.id, "limit": 50], browser: browser) { result = $0 }
            return result
        }
        var seen = context()["tabs"] as? [[String: Any]] ?? []
        #expect(seen.filter { $0["id"] as? String == gmail.id.uuidString }.count == 1)
        #expect(seen.first { $0["id"] as? String == gmail.id.uuidString }?["inEverySpace"] as? Bool == true)
        browser.switchSpace(to: client)
        seen = context()["tabs"] as? [[String: Any]] ?? []
        #expect(seen.filter { $0["id"] as? String == gmail.id.uuidString }.count == 1)
        #expect(seen.first { $0["id"] as? String == gmail.id.uuidString }?["visible"] as? Bool == false)
    }

    /// Pin Pair in each kind of space (feedback #349): the first, another
    /// that shows the pins every space shares, one with its own sign-ins,
    /// with the pins shared and with each space's own; every square stays
    /// a pinned pair where it was made.
    @MainActor @Test func aPairPinsAsOneInEverySpace() throws {
        for every in [true, false] {
            let world = World()
            defer { world.close() }
            let browser = world.browser
            browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
            let work = world.space("Pair Work"), client = world.space("Pair Client", own: true)
            world.share(every)
            func pinned(_ name: String) throws -> Pair {
                let a = browser.open(URL(string: "https://\(name).pairs.test/a")!, foreground: true)
                let b = browser.open(URL(string: "https://\(name).pairs.test/b")!, foreground: false)
                browser.split(b, with: a)
                let pair = try #require(browser.pair(of: a.id))
                #expect(browser.canPinPair(pair), "\(name), shared \(every)")
                browser.pinPair(pair)
                #expect(browser.pinPair(of: a.id) == pair, "\(name), shared \(every)")
                return pair
            }
            let first = try pinned("first")
            browser.switchSpace(to: work)
            #expect((browser.pinPair(of: first.first) != nil) == every)
            let second = try pinned("work")
            browser.switchSpace(to: client)
            let third = try pinned("client")
            #expect(browser.pinPair(of: first.first) == nil && browser.pinPair(of: second.first) == nil)
            browser.switchSpace(to: Space.firstID)
            #expect(browser.pinPair(of: first.first) == first)
            #expect((browser.pinPair(of: second.first) != nil) == every)
            browser.switchSpace(to: work)
            #expect(browser.pinPair(of: second.first) == second)
            browser.switchSpace(to: client)
            #expect(browser.pinPair(of: third.first) == third)
        }
    }

    // MARK: a window

    @MainActor @Test func theSharedPinsGoAlongAndAreParkedInASpaceWithItsOwnSignIns() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work"), client = world.space("Client", own: true)
        world.share(true)
        #expect(browser.pinsShared)
        #expect(browser.showsShared(Space.firstID) && browser.showsShared(work) && !browser.showsShared(client))

        let gmail = world.page("https://mail.example.test/u/0/"), today = world.page("https://example.test/today")
        browser.lay([gmail, today])
        browser.pin(gmail)
        #expect(gmail.everywhere == gmail.id)
        // To the shared row's file, never the space's.
        #expect(Session.read(space: Space.pinsID).tabs.map(\.url) == ["https://mail.example.test/u/0/"])
        #expect(Session.read(space: Space.pinsID).tabs.first?.id == gmail.id.uuidString)
        #expect(!Session.read(space: Space.firstID, window: world.id).tabs.contains { $0.pin != nil })

        browser.switchSpace(to: work)
        #expect(browser.tabs.first === gmail)
        #expect(browser.parked[Space.firstID]?.tabs.contains { $0 === gmail } == false)
        #expect(!Session.read(space: work, window: world.id).tabs.contains { $0.pin != nil })

        browser.switchSpace(to: client)
        #expect(!browser.tabs.contains { $0 === gmail })
        #expect(browser.parked[Space.pinsID]?.tabs.first === gmail)
        // Asleep on the timer as any parked tab.
        #expect(browser.parkedTabs.contains { $0 === gmail })
        #expect(browser.spaceHolding(gmail.id) == work)

        browser.switchSpace(to: Space.firstID)
        #expect(browser.tabs.first === gmail)
        #expect(browser.parked[Space.pinsID] == nil)
        #expect(!gmail.gone)
    }

    @MainActor @Test func aRowLeftOnASharedPinComesBackOnIt() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        world.share(true)
        let gmail = world.page("https://mail.example.test/u/0/"), today = world.page("https://example.test/today")
        browser.lay([gmail, today])
        browser.pin(gmail)
        browser.activeID = gmail.id
        browser.switchSpace(to: work)
        // Pictured coming (SpacePager, the strip): the pins at its head, on
        // the one it was left on.
        let coming = browser.withShared(try #require(browser.parked[Space.firstID]), in: Space.firstID)
        #expect(coming.tabs.first === gmail)
        #expect(coming.active == gmail.id)
        browser.switchSpace(to: Space.firstID)
        #expect(browser.activeID == gmail.id)

        // And after a relaunch: the file says -1, the first shared pin.
        browser.writeSession(now: true)
        #expect(Session.read(space: Space.firstID, window: world.id).active == -1)
        Store.settings.set(true, forKey: SharedPins.key)
        let again = Browser(windowID: world.id)
        Store.settings.set(false, forKey: SharedPins.key)
        defer { again.letGo() }
        #expect(again.pinsShared)
        #expect(again.active?.everywhere == gmail.id)
        #expect(again.tabs.first?.everywhere == gmail.id)
    }

    @MainActor @Test func turningItOnMergesEverySpacesPinsFirstSpaceFirst() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work"), client = world.space("Client", own: true)
        let gmail0 = world.page("https://mail.example.test/u/0/"), calendar = world.page("https://calendar.example.test/")
        browser.lay([gmail0, calendar, world.page("https://example.test/a")])
        browser.pin([gmail0, calendar])
        browser.switchSpace(to: work)
        let calendar2 = world.page("https://calendar.example.test/"), gmail1 = world.page("https://mail.example.test/u/1/")
        let workPage = world.page("https://example.test/b")
        browser.lay([calendar2, gmail1, workPage])
        browser.pin([calendar2, gmail1])
        browser.activeID = calendar2.id
        browser.switchSpace(to: client)
        let own = world.page("https://calendar.example.test/")
        browser.lay([own])
        browser.pin(own)
        browser.switchSpace(to: Space.firstID)
        #expect(!browser.pinsShared)

        world.share(true)
        let shared = try #require(browser.sharedPins)
        #expect(shared.map { Browser.pinAddress($0) } == ["https://mail.example.test/u/0/", "https://calendar.example.test/", "https://mail.example.test/u/1/"])
        #expect(shared[0] === gmail0 && shared[1] === calendar && shared[2] === gmail1)
        #expect(Array(browser.tabs.prefix(3)).elementsEqual(shared, by: { $0 === $1 }))
        // The same address twice: one closed.
        #expect(calendar2.gone)
        #expect(browser.parked[work]?.tabs.contains { $0.pin != nil } == false)
        #expect(browser.parked[work]?.tabs.contains { $0 === workPage } == true)
        // A space with sign-ins of its own keeps its own.
        #expect(browser.parked[client]?.tabs.first === own)
        #expect(own.everywhere == nil)
        #expect(Session.read(space: Space.pinsID).tabs.count == 3)

        // Work, left on its calendar, comes back on the one kept.
        browser.switchSpace(to: work)
        #expect(Array(browser.tabs.prefix(3)).elementsEqual(shared, by: { $0 === $1 }))
        #expect(browser.activeID == calendar.id)
    }

    @MainActor @Test func turningItOffGivesThePinsToTheSpaceOnScreenOrTheFirst() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work"), client = world.space("Client", own: true)
        world.share(true)
        let gmail = world.page("https://mail.example.test/u/0/"), music = world.page("https://music.example.test/")
        browser.lay([gmail, music])
        browser.pin([gmail, music])

        browser.switchSpace(to: work)
        world.share(false)
        #expect(!browser.pinsShared)
        #expect(Array(browser.tabs.prefix(2)).elementsEqual([gmail, music], by: { $0 === $1 }))
        #expect(gmail.everywhere == nil && music.everywhere == nil)
        #expect(Session.read(space: work, window: world.id).tabs.filter { $0.pin != nil }.count == 2)
        #expect(Session.read(space: Space.pinsID).tabs.isEmpty)

        // On again, from a space of its own: back to the first space.
        world.share(true)
        browser.switchSpace(to: client)
        world.share(false)
        let first = try #require(browser.parked[Space.firstID])
        #expect(Array(first.tabs.prefix(2)).elementsEqual([gmail, music], by: { $0 === $1 }))
        #expect(!browser.tabs.contains { $0 === gmail })
    }

    @MainActor @Test func movingTabsNeverTakesASharedPin() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        world.share(true)
        let gmail = world.page("https://mail.example.test/u/0/"), page = world.page("https://example.test/page")
        browser.lay([gmail, page])
        browser.pin(gmail)
        #expect(browser.moveTabs([gmail], to: work, say: false) == nil)
        #expect(browser.tabs.first === gmail)
        let move = browser.moveTabs([gmail, page], to: work, say: false)
        #expect(move?.tabs.map(\.original) == [page.id])
        #expect(browser.tabs.first === gmail)
    }

    /// Row 1105: a pin sent to another space, by its menu's Move to › a
    /// space, ⌃⇧N, or let go over the space (each one Browser.moveTabs),
    /// arrives pinned there, at the end of its pins, with its address,
    /// letter and name, as Arc's pinned tabs do; ⌘Z brings it back.
    @MainActor @Test func aPinGoesToAnotherSpaceAndArrivesPinned() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        let gmail = world.page("https://mail.example.test/u/0/"), page = world.page("https://example.test/page")
        browser.lay([gmail, page])
        browser.pin(gmail)
        gmail.name = "Inbox"
        let letter = try #require(gmail.pin)
        // Work has a pin of its own already: it goes after it.
        let linear = world.page("https://linear.example.test/")
        linear.pin = "L"
        browser.parked[work] = Parked(tabs: [linear], active: linear.id)
        browser.select(page)

        let move = try #require(browser.moveTabs([gmail], to: work, say: false))
        #expect(move.tabs.map(\.original) == [gmail.id])
        #expect(!browser.tabs.contains { $0 === gmail })
        let there = try #require(browser.parked[work]).tabs
        #expect(there.elementsEqual([linear, gmail], by: { $0 === $1 }))
        #expect(gmail.pin == letter && gmail.name == "Inbox" && gmail.address?.absoluteString == "https://mail.example.test/u/0/")
        #expect(Session.read(space: work, window: world.id).tabs.map(\.pin) == ["L", letter])

        browser.undoMove(move)
        #expect(browser.tabs.first === gmail && gmail.pin == letter)
        #expect(browser.parked[work]?.tabs.elementsEqual([linear], by: { $0 === $1 }) == true)

        // As ⌃⇧N sends it, the pin in front: on screen in Work, still pinned.
        browser.select(gmail)
        #expect(browser.moveTabs(browser.chosen, to: work, say: false) != nil)
        browser.switchSpace(to: work)
        #expect(Array(browser.tabs.prefix(2)).elementsEqual([linear, gmail], by: { $0 === $1 }))
        #expect(browser.tabs.filter { $0.pin != nil }.count == 2)
    }

    /// Register 1105, x.com's pin: an agent attached through `yab mcp` that
    /// once worked in a pin of yours never says its turn is over, so its
    /// `guest` stays. Gone quiet, the pin is an ordinary one again: it
    /// stays in its space, and Move to › Space sends it there pinned. While
    /// the agent is at work it goes along, as before.
    @MainActor @Test func aPinAnAgentWorkedInOnceStillMovesToASpace() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        let x = world.page("https://x.example.test/home"), page = world.page("https://example.test/page")
        browser.lay([x, page])
        browser.pin(x)
        let agent = Agents.shared.attach(name: "claude-code")
        defer { agent.state = .done }
        x.guest = agent.id

        agent.touched = Date()
        #expect(Browser.hosts(x) && browser.travels(x))
        agent.touched = Date().addingTimeInterval(-(AgentFeed.rests + 1))
        #expect(agent.resting && !Browser.hosts(x) && !browser.travels(x))
        #expect(Browser.holdsOwn([x]))

        browser.select(page)
        #expect(browser.moveTabs([x], to: work, say: false) != nil)
        #expect(!browser.tabs.contains { $0 === x })
        #expect(browser.parked[work]?.tabs.contains { $0 === x } == true && x.pin != nil)

        // Ended (detached, or its process gone): the same.
        agent.state = .done
        #expect(!Browser.hosts(x))
    }

    /// Owner, 2026-10-25: a tab an agent is busy in had no Move to › Space,
    /// silently. Now it has: sent, the same tab lands in that space and
    /// stays there (no longer going along into every space), its agent's
    /// face on it, and the agent's next call still finds it by its id.
    @MainActor @Test func aTabAnAgentIsBusyInMovesToASpaceAndStaysThere() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let home = browser.spaceID
        let work = world.space("Work")
        let busy = world.page("https://busy.example.test/a"), page = world.page("https://example.test/page")
        browser.lay([busy, page])
        let agent = Agents.shared.attach(name: "claude-code")
        defer { agent.state = .done }
        busy.guest = agent.id
        agent.touched = Date()
        #expect(Browser.hosts(busy) && browser.travels(busy) && Browser.movable(busy))

        browser.select(page)
        let move = try #require(browser.moveTabs([busy], to: work, say: false))
        #expect(move.tabs.first?.now === busy)
        #expect(!browser.tabs.contains { $0 === busy })
        #expect(browser.parked[work]?.tabs.contains { $0 === busy } == true)
        #expect(busy.guest == agent.id && Browser.hosts(busy) && !browser.travels(busy))

        // Into Work and out again: it stays in Work.
        browser.switchSpace(to: work)
        #expect(browser.tabs.contains { $0 === busy })
        browser.switchSpace(to: home)
        #expect(!browser.tabs.contains { $0 === busy })
        #expect(browser.spaceHolding(busy.id) == work)
        // The agent holds it by its id, wherever it is.
        #expect(Bench().find(["id": busy.id.uuidString], in: browser) === busy)
    }

    /// Into a space with sign-ins of its own the busy tab goes as itself,
    /// not opened afresh in that store: the agent is mid-task in it.
    /// Picked with a plain tab, both go; ⌘Z brings it back to going along.
    @MainActor @Test func aBusyTabGoesAsItselfIntoASpaceWithItsOwnSignIns() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let own = world.space("Own", own: true)
        let busy = world.page("https://busy.example.test/b"), plain = world.page("https://example.test/plain"), page = world.page("https://example.test/stay")
        browser.lay([busy, plain, page])
        let agent = Agents.shared.attach(name: "claude-code")
        defer { agent.state = .done }
        busy.guest = agent.id
        agent.touched = Date()

        browser.select(page)
        let move = try #require(browser.moveTabs([busy, plain], to: own, say: false))
        #expect(move.tabs.count == 2)
        #expect(move.tabs.first { $0.original == busy.id }?.now === busy)
        #expect(move.tabs.first { $0.original == plain.id }?.now !== plain)
        #expect(browser.parked[own]?.tabs.contains { $0 === busy } == true && busy.stays)

        browser.undoMove(move)
        #expect(browser.tabs.contains { $0 === busy } && !busy.stays && browser.travels(busy))
    }

    /// An agent's own tab, in its task's folder, moves too and takes that
    /// space for its home; a script's bench tab shows nowhere and never.
    @MainActor @Test func anAgentsOwnTabMovesAndAScriptsDoesNot() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        let page = world.page("https://example.test/page")
        browser.lay([page])
        let agent = Agents.shared.attach(name: "claude-code")
        defer { agent.state = .done }
        let theirs = browser.benchOpen(URL(string: "about:blank")!)
        theirs.agent = agent.id
        let script = browser.benchOpen(URL(string: "about:blank")!)
        script.agent = Agents.script
        #expect(browser.travels(theirs) && Browser.movable(theirs))
        #expect(!Browser.movable(script))

        browser.select(page)
        #expect(browser.moveTabs([theirs, script], to: work, say: false)?.tabs.count == 1)
        #expect(theirs.assistantSpace == work && !browser.travels(theirs))
        #expect(browser.parked[work]?.tabs.contains { $0 === theirs } == true)
        #expect(browser.tabs.contains { $0 === script })
    }

    /// Row 1149: a Meet tab stuck across spaces, in the way of a folder.
    /// A call goes along only while it is live; in another space its
    /// home's folder isn't drawn there, and once the call is over it goes
    /// back to its own space, in its folder, not left in the one you are in.
    @MainActor @Test func aCallGoesAlongOnlyWhileLiveAndThenGoesHome() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let home = browser.spaceID
        let work = world.space("Work")
        let meet = world.page("https://meet.example.test/abc"), page = world.page("https://example.test/page")
        browser.lay([meet, page])
        let folder = Nest(name: "Meetings")
        meet.kept = true
        meet.nest = folder
        browser.select(meet)
        meet.pretendCall(true)
        #expect(meet.onCall && browser.travels(meet))

        browser.switchSpace(to: work)
        #expect(browser.tabs.contains { $0 === meet } && meet.homeSpace == home)
        // Its home's folder is not drawn here.
        #expect(!Folders.nests(in: browser.tabs).contains { $0.nest === folder })

        let there = world.page("https://example.test/work")
        browser.lay(browser.tabs + [there])
        browser.select(there)
        meet.pretendCall(false)
        #expect(!browser.travels(meet))
        #expect(!browser.tabs.contains { $0 === meet })
        #expect(browser.parked[home]?.tabs.contains { $0 === meet } == true)
        #expect(meet.nest === folder && meet.kept && meet.homeSpace == nil)
    }

    /// A call's tab has Move to › Space like any: the same live tab goes
    /// and stays there; its next call goes along again.
    @MainActor @Test func aCallsTabMovesToASpaceAndStays() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let home = browser.spaceID
        let work = world.space("Work", own: true)
        let meet = world.page("https://meet.example.test/xyz"), page = world.page("https://example.test/page")
        browser.lay([meet, page])
        meet.pretendCall(true)
        #expect(Browser.movable(meet) && browser.sendable(meet))

        browser.select(page)
        let move = try #require(browser.moveTabs([meet], to: work, say: false))
        #expect(move.tabs.first?.now === meet)
        #expect(meet.stays && !browser.travels(meet))
        browser.switchSpace(to: work)
        browser.switchSpace(to: home)
        #expect(browser.spaceHolding(meet.id) == work)

        meet.pretendCall(false)
        #expect(!meet.stays)
        meet.pretendCall(true)
        #expect(browser.travels(meet))
        meet.pretendCall(false)
    }

    /// Several picked with a pin among them: all of them go, the pin to the
    /// other space's pins, the rest to the end of its today's.
    @MainActor @Test func picksWithAPinAmongThemAllGoAndThePinStaysPinned() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        let gmail = world.page("https://mail.example.test/u/0/")
        let one = world.page("https://example.test/one"), two = world.page("https://example.test/two"), stay = world.page("https://example.test/stay")
        browser.lay([gmail, one, two, stay])
        browser.pin(gmail)
        let move = try #require(browser.moveTabs([gmail, one, two], to: work, say: false))
        #expect(Set(move.tabs.map(\.original)) == [gmail.id, one.id, two.id])
        #expect(browser.tabs.elementsEqual([stay], by: { $0 === $1 }))
        let there = try #require(browser.parked[work]).tabs.filter { !$0.isBlank }
        #expect(there.elementsEqual([gmail, one, two], by: { $0 === $1 }))
        #expect(gmail.pin != nil && one.pin == nil && two.pin == nil)
    }

    /// Pins In Every Space: a shared pin sent to a space with sign-ins of
    /// its own leaves the shared row and is that space's own pin, its page
    /// opened afresh signed in there; ⌘Z makes it a shared pin again.
    @MainActor @Test func aSharedPinGoesToASpaceOfItsOwnAsItsPin() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let client = world.space("Client", own: true)
        world.share(true)
        let gmail = world.page("https://mail.example.test/u/0/"), music = world.page("https://music.example.test/")
        let page = world.page("https://example.test/page")
        browser.lay([gmail, music, page])
        browser.pin([gmail, music])
        let letter = try #require(gmail.pin)
        #expect(gmail.everywhere != nil)
        #expect(!browser.pinnedAlready(gmail, in: client))

        let move = try #require(browser.moveTabs([gmail], to: client, say: false))
        let arrived = try #require(move.tabs.first?.now)
        #expect(arrived !== gmail && gmail.gone)
        #expect(arrived.pin == letter && arrived.everywhere == nil)
        #expect(Browser.pinAddress(arrived) == "https://mail.example.test/u/0/")
        #expect(browser.parked[client]?.tabs.first === arrived)
        #expect(browser.sharedPins?.elementsEqual([music], by: { $0 === $1 }) == true)
        browser.writeSession(now: true)
        #expect(Session.read(space: Space.pinsID).tabs.map(\.url) == ["https://music.example.test/"])

        browser.undoMove(move)
        browser.writeSession(now: true)
        let back = try #require(browser.tabs.first)
        #expect(Browser.pinAddress(back) == "https://mail.example.test/u/0/" && back.pin == letter)
        #expect(back.everywhere != nil)
        #expect(browser.sharedPins?.count == 2)
    }

    /// A shared pin sent to a space that shows the shared pins is there
    /// already: nothing moves, and the corner says so with Go There rather
    /// than nothing at all.
    @MainActor @Test func aSharedPinSentWhereItIsAlreadySaysSo() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        world.share(true)
        let gmail = world.page("https://mail.example.test/u/0/"), page = world.page("https://example.test/page")
        browser.lay([gmail, page])
        browser.pin(gmail)
        #expect(browser.pinnedAlready(gmail, in: work))
        #expect(browser.moveTabs([gmail], to: work) == nil)
        #expect(browser.tabs.first === gmail && gmail.everywhere != nil)
        #expect(browser.toaster.shown && browser.toaster.words == "Already pinned in Work" && browser.toaster.act == "Go There")
    }

    @MainActor @Test func aPinOfItsOwnInASpaceThatSharesJoinsTheSharedOnes() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        world.share(true)
        let gmail = world.page("https://mail.example.test/u/0/")
        browser.lay([gmail])
        browser.pin(gmail)
        // Brought into Work's row as its own, as sync or a move would: one
        // at Gmail's address, one new.
        let twin = world.page("https://mail.example.test/u/0/"), linear = world.page("https://linear.example.test/")
        let page = world.page("https://example.test/work")
        twin.pin = "G"
        linear.pin = "L"
        browser.parked[work] = Parked(tabs: [twin, linear, page], active: twin.id)
        browser.switchSpace(to: work)
        #expect(Array(browser.tabs.prefix(2)).elementsEqual([gmail, linear], by: { $0 === $1 }))
        #expect(linear.everywhere == linear.id)
        #expect(twin.gone)
        #expect(browser.activeID == gmail.id)
        browser.writeSession(now: true)
        #expect(Session.read(space: Space.pinsID).tabs.map(\.url) == ["https://mail.example.test/u/0/", "https://linear.example.test/"])
    }

    @MainActor @Test func aPinAnAgentTookIntoASpaceOfItsOwnComesBackAmongTheShared() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work"), client = world.space("Client", own: true)
        world.share(true)
        let gmail = world.page("https://mail.example.test/u/0/"), music = world.page("https://music.example.test/")
        browser.lay([gmail, music, world.page("https://example.test/page")])
        browser.pin([gmail, music])

        // An agent at work in Gmail: it goes along into Client, the other
        // pin put aside, Gmail keeping its place among them.
        gmail.guest = "agent"
        browser.switchSpace(to: client)
        #expect(browser.tabs.contains { $0 === gmail })
        #expect(browser.parked[Space.pinsID]?.tabs.map(\.id) == [music.id])
        #expect(browser.sharedPins?.map(\.id) == [gmail.id, music.id])
        // Written all together at quit, the one along too, never as Client's.
        browser.flushSession()
        #expect(Session.read(space: Space.pinsID).tabs.map(\.url) == ["https://mail.example.test/u/0/", "https://music.example.test/"])
        #expect(!Session.read(space: client, window: world.id).tabs.contains { $0.pin != nil })

        // Its work done there: into Work, back in its place.
        gmail.guest = nil
        browser.switchSpace(to: work)
        #expect(Array(browser.tabs.prefix(2)).elementsEqual([gmail, music], by: { $0 === $1 }))
        #expect(browser.parked[Space.pinsID] == nil)
        #expect(!gmail.gone)
    }

    @MainActor @Test func aPrivatePinStaysThePinOfItsSpace() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        let secret = Tab(shy: true)
        secret.restore(url: URL(string: "https://private.example.test/")!, title: "Private")
        browser.prepare(secret)
        let gmail = world.page("https://mail.example.test/u/0/")
        browser.lay([gmail, secret])
        browser.pin([gmail, secret])

        // Turned on: Gmail shared, the private one left as it was, open.
        world.share(true)
        #expect(gmail.everywhere == gmail.id)
        #expect(secret.everywhere == nil && secret.pin != nil && !secret.gone)
        #expect(browser.tabs.contains { $0 === secret })
        #expect(Session.read(space: Space.pinsID).tabs.map(\.url) == ["https://mail.example.test/u/0/"])

        // Pinned while shared: still the space's own, and stays with it.
        let another = Tab(shy: true)
        another.restore(url: URL(string: "https://private.example.test/other")!, title: "Other")
        browser.prepare(another)
        browser.lay(browser.tabs + [another])
        browser.pin(another)
        #expect(another.everywhere == nil)
        browser.switchSpace(to: work)
        #expect(browser.tabs.first === gmail)
        #expect(!browser.tabs.contains { $0 === secret || $0 === another })
        #expect(browser.parked[Space.firstID]?.tabs.contains { $0 === secret } == true)
        #expect(browser.parked[Space.firstID]?.tabs.contains { $0 === another } == true)
    }

    @MainActor @Test func anotherWindowFollowsTheSameList() throws {
        let world = World()
        defer { world.close() }
        let a = world.browser
        let other = UUID()
        let b = Browser(windowID: other)
        defer {
            b.letGo()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(other.uuidString).json"))
        }
        SharedPins.turn(true, in: [a, b], spacesOn: true)
        defer { SharedPins.turn(false, in: [a, b], spacesOn: true) }
        #expect(a.pinsShared && b.pinsShared)
        let gmail = world.page("https://mail.example.test/u/0/")
        a.lay([gmail])
        a.pin(gmail)
        b.followPins(Session.read(space: Space.pinsID).tabs)
        let copy = try #require(b.tabs.first)
        #expect(copy !== gmail)
        #expect(copy.everywhere == gmail.id)
        #expect(copy.asleep)

        a.editLetter(gmail)
        a.letter("M", for: gmail)
        a.endPinEdit()
        b.followPins(Session.read(space: Space.pinsID).tabs)
        #expect(b.tabs.first === copy)
        #expect(copy.pin == "M")

        a.unpin(gmail)
        b.followPins(Session.read(space: Space.pinsID).tabs)
        #expect(!b.tabs.contains { $0 === copy })
        #expect(gmail.everywhere == nil && a.tabs.contains { $0 === gmail })
    }

    // MARK: the grid standing still

    // Feedback #270: every space but the first deleted, the name stayed
    // over the rows (and so the fold of the kept tabs) and the space's mark
    // in the foot, as in Arc.
    @MainActor @Test func oneSpaceKeepsItsNameAndItsMark() {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        browser.spaces = browser.spaces.filter { $0.id == Space.firstID }
        #expect(browser.spaces.count == 1)
        #expect(browser.namesSpaces)
        #expect(browser.footShowsSpaces)
        browser.prefs.usesSpaces = false
        #expect(!browser.namesSpaces)
        #expect(browser.footShowsSpaces == (browser.turnOrder.count > 1))
        browser.prefs.usesSpaces = true
    }

    @MainActor @Test func theGridStaysThroughASwitchBetweenTwoSpacesThatShowIt() {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work"), client = world.space("Client", own: true)
        world.share(true)
        let gmail = world.page("https://mail.example.test/u/0/"), today = world.page("https://example.test/today")
        browser.lay([gmail, today])
        browser.pin(gmail)
        // Spaces to tell apart: each is named over its rows.
        #expect(browser.namesSpaces)
        browser.switchSpace(to: work)
        #expect(browser.pinsStayed)
        #expect(browser.pinsHold(SpacePull.shared))
        // Into a space with sign-ins of its own the grid is its own.
        browser.switchSpace(to: client)
        #expect(!browser.pinsStayed)
        #expect(!browser.pinsHold(SpacePull.shared))
        browser.switchSpace(to: Space.firstID)
        #expect(!browser.pinsStayed)
        browser.switchSpace(to: work)
        #expect(browser.pinsStayed)
        // In Each Space nothing stays.
        world.share(false)
        browser.switchSpace(to: Space.firstID)
        #expect(!browser.pinsStayed)
        #expect(!browser.pinsHold(SpacePull.shared))
    }

    // MARK: a space left with none in front

    /// None in front is said by a mark of its own, `active` 0 beside it for
    /// a Yab from before; a file from before reads as it always did, and a
    /// row left on a shared pin still says so below zero.
    @Test func noneInFrontIsWrittenApartFromTheShapesPlace() throws {
        let tabs = [entry("https://a.test/"), entry("https://b.test/", pin: nil)]
        let bare = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(Session.Shape(tabs: tabs, front: nil)))
        #expect(bare.front == nil && bare.active == 0 && bare.nothingInFront == true)
        let onPin = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(Session.Shape(tabs: tabs, front: -2)))
        #expect(onPin.front == -2 && onPin.nothingInFront == nil)
        let old = try JSONDecoder().decode(Session.Shape.self, from: Data(#"{"tabs":[{"url":"https://a.test/","title":"a"}],"active":0}"#.utf8))
        #expect(old.front == 0)
    }

    /// A space's pin, its old folder's tab and one of today's, as the alpha
    /// report had them (2026-10-18).
    @MainActor private func row(_ world: World) -> (pin: Tab, folder: Tab, today: Tab) {
        let pin = world.page("https://pin.example.test/"), folder = world.page("https://folder.example.test/old")
        let today = world.page("https://today.example.test/")
        folder.kept = true
        folder.nest = Nest(name: "Old Bookmarks")
        world.browser.lay([pin, folder, today])
        world.browser.pin(pin)
        return (pin, folder, today)
    }

    @MainActor @Test func aSpaceLeftWithNoneInFrontComesBackSoAfterARelaunch() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        _ = row(world)
        browser.activeID = nil
        browser.writeSession(now: true)
        #expect(Session.read(space: Space.firstID, window: world.id).nothingInFront == true)
        let again = Browser(windowID: world.id)
        defer { again.letGo() }
        #expect(again.tabs.count == 3)
        #expect(again.activeID == nil)
        // Nothing loaded for it: the pin and the folder's tab stay asleep.
        #expect(again.tabs.allSatisfy { $0.asleep })
    }

    @MainActor @Test func aSpaceLeftWithNoneInFrontComesBackSoAfterASwitch() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        let (pin, folder, _) = row(world)
        browser.activeID = nil
        browser.switchSpace(to: work)
        #expect(browser.parked[Space.firstID]?.active == nil)
        browser.switchSpace(to: Space.firstID)
        #expect(browser.spaceID == Space.firstID)
        #expect(browser.activeID == nil)
        #expect(pin.asleep && folder.asleep)
        // Read again from its file, as a space not opened since launch is:
        // none in front there too.
        browser.switchSpace(to: work)
        browser.parked.removeValue(forKey: Space.firstID)?.tabs.forEach { $0.close() }
        browser.switchSpace(to: Space.firstID)
        #expect(browser.tabs.count == 3)
        #expect(browser.activeID == nil)
        #expect(browser.tabs.allSatisfy { $0.asleep })
    }

    @MainActor @Test func aSpaceLeftOnAPinComesBackOnIt() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        let (pin, _, _) = row(world)
        browser.select(pin)
        browser.switchSpace(to: work)
        browser.switchSpace(to: Space.firstID)
        #expect(browser.activeID == pin.id)
        browser.writeSession(now: true)
        #expect(Session.read(space: Space.firstID, window: world.id).front == 0)
        let again = Browser(windowID: world.id)
        defer { again.letGo() }
        #expect(again.active?.address == pin.address)
    }

    @MainActor @Test func aSpaceWhoseTabInFrontIsGoneComesBackWithNone() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Work")
        let (_, folder, today) = row(world)
        browser.select(today)
        browser.switchSpace(to: work)
        // Closed while its space is parked (the switcher, an agent).
        browser.closeParked(today, in: Space.firstID)
        browser.switchSpace(to: Space.firstID)
        #expect(browser.activeID == nil)
        #expect(folder.asleep)
        // A file whose tab in front is no longer there: none either.
        let file = Session.read(space: Space.firstID, window: world.id)
        Session.write(now: true, space: Space.firstID, window: world.id,
                      Session.Shape(tabs: file.tabs + [Session.Entry(url: "", title: "gone", pin: nil, name: nil, seen: nil)], active: file.tabs.count))
        let again = Browser(windowID: world.id)
        defer { again.letGo() }
        #expect(again.tabs.count == 2)
        #expect(again.activeID == nil)
        #expect(again.tabs.allSatisfy { $0.asleep })
    }

    @MainActor @Test func pinsAreInSettingsSearchOnTheSpacesPage() {
        let item = SettingsItem.all.first { $0.id == "pins" }
        #expect(item?.page == .spaces)
        #expect(item?.score("favorites") != nil)
    }

    /// ⌘T finds a tab in a space not on screen, says which space, and
    /// taking it brings that space with the tab in front, as Arc's Command
    /// Bar does.
    @MainActor @Test func theFieldFindsATabInAnotherSpaceAndGoesThere() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = world.space("Field Work")
        let here = world.page("https://here.example.test/notes")
        let there = world.page("https://parked.example.test/report")
        browser.lay([here])
        browser.switchSpace(to: work)
        browser.lay([there])
        browser.select(there)
        browser.switchSpace(to: Space.firstID)
        #expect(browser.parked[work]?.tabs.contains { $0 === there } == true)
        let rows = browser.openPages(matching: "parked.example")
        let row = try #require(rows.first)
        #expect(rows.count == 1 && row.tab == there.id && row.space == work)
        // A tab on screen has no space to name.
        #expect(browser.openPages(matching: "here.example").first?.space == nil)
        browser.take(row)
        #expect(browser.spaceID == work)
        #expect(browser.activeID == there.id)
    }
}

/// A window of its own for a test: its spaces made in memory only, its
/// settings and files put back as they were.
@MainActor
private final class World {
    let id = UUID()
    let browser: Browser
    private var made: [UUID] = []
    private let spaces: Any?
    private let pins: Any?
    private let shared: Data?
    /// A switch keeps the window's look with the space it leaves, and so
    /// writes the spaces, this window's made-up ones among them.
    private let spacesList: Data?

    private static var sharedFile: URL { Store.file("session-\(Space.pinsID.uuidString).json") }
    private static var spacesFile: URL { Store.file("spaces.json") }

    init() {
        spaces = Store.settings.object(forKey: "spaces")
        pins = Store.settings.object(forKey: SharedPins.key)
        shared = try? Data(contentsOf: World.sharedFile)
        spacesList = try? Data(contentsOf: World.spacesFile)
        // In Each Space while the window comes up, so it starts as every
        // other test's does; each test turns the pins on itself.
        Store.settings.set(false, forKey: SharedPins.key)
        browser = Browser(windowID: id)
        browser.prefs.usesSpaces = true
    }

    /// Pins: In Every Space or In Each Space, for this window alone.
    func share(_ on: Bool) {
        SharedPins.turn(on, in: [browser], spacesOn: true)
    }

    func space(_ name: String, own: Bool = false) -> UUID {
        let space = Space(id: UUID(), name: name, icon: "🧪", ownSignIns: own)
        browser.spaces.append(space)
        if !own { Spaces.sharing.insert(space.id) }
        made.append(space.id)
        return space.id
    }

    func page(_ address: String) -> Tab {
        let tab = Tab()
        tab.restore(url: URL(string: address)!, title: address)
        browser.prepare(tab)
        return tab
    }

    func close() {
        browser.letGo()
        Store.settings.set(spaces, forKey: "spaces")
        Store.settings.set(pins, forKey: SharedPins.key)
        if let shared { try? shared.write(to: World.sharedFile) } else { try? FileManager.default.removeItem(at: World.sharedFile) }
        if let spacesList { try? spacesList.write(to: World.spacesFile, options: .atomic) } else { try? FileManager.default.removeItem(at: World.spacesFile) }
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        for space in made {
            Spaces.sharing.remove(space)
            Spaces.pageCounts[space] = nil
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)-\(space.uuidString).json"))
        }
        Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
    }
}
