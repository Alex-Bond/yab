import Foundation
import Testing
@testable import Fast

struct ExtensionOneListTests {
    private func id(_ letter: Character) -> String { String(repeating: letter, count: 32) }

    private func item(_ letter: Character, on: Bool = true, pinned: Bool? = nil) -> Installed {
        Installed(id: id(letter), name: String(letter), version: "1", enabled: on, fromStore: true, permissions: [], pinned: pinned)
    }

    private func row(_ letter: Character, on: Bool = true) -> ExtensionOneList.Native {
        .init(id: id(letter), name: String(letter), version: "2", enabled: on)
    }

    /// The owner's two lists as measured on 2026-11-01.
    @Test func theUnionKeepsEveryExtensionOnIfOnAnywhere() {
        let webKit = [item("a", on: false), item("b"), item("c", on: false), item("d", on: false), item("e"), item("f"), item("g"), item("h")]
        let native = [row("i"), row("g"), row("e"), row("f"), row("h"), row("a", on: false)]
        let merged = ExtensionOneList.merged(webKit: webKit, native: native, pins: [])
        #expect(merged.map(\.id) == ["a", "b", "c", "d", "e", "f", "g", "h", "i"].map { id(Character($0)) })
        #expect(merged.filter(\.enabled).map(\.name) == ["b", "e", "f", "g", "h", "i"])
        #expect(merged.last?.fromStore == true)
        // Run twice, nothing doubles.
        #expect(ExtensionOneList.merged(webKit: merged, native: native, pins: []).map(\.id) == merged.map(\.id))
    }

    @Test func onInChromiumWinsAndClearsWhatWebKitWaitedOn() {
        var off = item("a", on: false)
        off.wants = ["debugger"]
        let merged = ExtensionOneList.merged(webKit: [off], native: [row("a")], pins: [])
        #expect(merged[0].enabled)
        #expect(merged[0].wants == nil)
    }

    @Test func pinsComeInChromiumsOrderThenWebKits() {
        let webKit = [item("a", pinned: true), item("b"), item("c", pinned: true), item("d")]
        let merged = ExtensionOneList.merged(webKit: webKit, native: [row("b"), row("d")], pins: [id("d"), id("c")])
        #expect(merged.filter { $0.pinned == true }.map(\.name) == ["d", "c", "a"])
        #expect(merged.map(\.name) == ["d", "c", "a", "b"])
    }

    @Test func aFoldersExtensionCrossesToChromium() {
        let local = Installed(id: id("b"), name: "Mine", version: "1", enabled: true, fromStore: false, permissions: [], source: "/tmp/x")
        let plan = ExtensionOneList.plan(list: [local], native: [], known: [])
        #expect(plan.bringToChromium == [local])
        #expect(ExtensionOneList.webKitFolders([local, item("a")]) == Set([local.id]))
    }

    /// Settings reads the composed list, while Chromium actions use `enabled`.
    @Test @MainActor func legacyFolderRowsExplainHowToEnableChromium() {
        let native = ChromiumExtensions(profile: "unpacked-composition", privateMode: false)
        for on in [true, false] {
            let local = Installed(id: "local-1234", name: "Mine", version: "1", enabled: on,
                                  fromStore: false, permissions: [], source: "/tmp/x")
            let store = item("a", on: on)
            let rows = native.composed([], list: [local, store])
            #expect(rows.map(\.id) == [local.id, store.id])
            #expect(rows[0].issue != nil)
            #expect(rows[0].webKitOnly)
            #expect(rows[0].on == on)
            #expect(!rows[0].enabled)
            #expect(!rows[0].absent)
            #expect(!rows[1].webKitOnly)
            #expect(rows[1].absent)
            #expect(rows[1].on == on)
            #expect(native.composed([], list: [store]).map(\.id) == [store.id])
        }
    }

    @Test @MainActor func nativeFolderUsesOneRowAndBothToggleStates() {
        let model = ChromiumExtensions(profile: "native-folder-composition", privateMode: false)
        for on in [false, true] {
            let local = Installed(id: id("b"), name: "Mine", version: "1", enabled: on, fromStore: false, permissions: [], source: "/tmp/x")
            let native = try! ChromiumExtensions.Item(.object(["id": .string(local.id), "name": .string(local.name), "state": .string(on ? "ENABLED" : "DISABLED")]))
            let rows = model.composed([native], list: [local])
            #expect(rows.count == 1)
            #expect(rows[0].on == on)
            #expect(!rows[0].webKitOnly)
            #expect(rows[0].issue == nil)
            #expect(ExtensionOneList.plan(list: [local], native: [], known: []).bringToChromium == [local])
        }
    }

    @Test func goneFromTheListLeavesChromiumNewInChromiumJoinsTheList() {
        let plan = ExtensionOneList.plan(list: [item("a")], native: [row("a"), row("b"), row("c")], known: [id("a"), id("b")])
        #expect(plan.dropFromChromium == [id("b")])
        #expect(plan.addToList.map(\.id) == [id("c")])
        #expect(plan.bringToChromium.isEmpty)
    }

    /// One pass as convergeOnce runs it: Chrome's list read at its start
    /// for the plan, read again at its end for what counts as matched.
    private struct Profile {
        var list: [Installed] = []
        var chrome: [ExtensionOneList.Native] = []
        var known: Set<String> = []
        var dropped: [String] = []

        mutating func install(_ letter: Character) {
            let id = String(repeating: letter, count: 32)
            chrome.append(.init(id: id, name: String(letter), version: "1", enabled: true))
        }

        /// `during`: what happens in Chrome after the pass read its list
        /// and before it read it again.
        mutating func pass(during: (inout Profile) -> Void = { _ in }) {
            let plan = ExtensionOneList.plan(list: list, native: chrome, known: known)
            chrome.removeAll { plan.dropFromChromium.contains($0.id) }
            dropped += plan.dropFromChromium
            for row in plan.addToList {
                list.append(Installed(id: row.id, name: row.name, version: row.version, enabled: row.enabled, fromStore: true, permissions: []))
            }
            during(&self)
            known = ExtensionOneList.matched(native: chrome.map(\.id), list: list, known: known)
        }
    }

    /// Six added a few seconds apart, each while the pass the one before
    /// started is still running (a RAM soak kept 3 of 6, twice).
    @Test func severalInstalledInARowAllStay() {
        var profile = Profile()
        profile.install("a")
        profile.pass { $0.install("b"); $0.install("c") }
        profile.pass { $0.install("d") }
        profile.pass { $0.install("e"); $0.install("f") }
        profile.pass()
        profile.pass()
        let all = ["a", "b", "c", "d", "e", "f"].map { id(Character($0)) }
        #expect(profile.dropped.isEmpty)
        #expect(profile.chrome.map(\.id) == all)
        #expect(profile.list.map(\.id) == all)
        #expect(profile.known == Set(all))
    }

    /// One taken off the list goes from Chromium too: at once, while a pass
    /// runs, or after the helper was down.
    @Test func aRealRemovalStillReachesChromium() {
        var profile = Profile()
        for letter in "abc" { profile.install(letter) }
        profile.pass()
        profile.pass()
        #expect(profile.known == Set(["a", "b", "c"].map { id(Character($0)) }))
        // Removed from the list (WebKit's Remove) while a pass runs.
        profile.pass { $0.list.removeAll { $0.name == "b" } }
        #expect(profile.known.contains(id("b")))
        profile.pass()
        #expect(profile.dropped == [id("b")])
        #expect(profile.chrome.map(\.id) == [id("a"), id("c")])
        // Removed while the helper was down: the first pass after takes it off.
        profile.list.removeAll { $0.name == "c" }
        profile.pass()
        #expect(profile.dropped == [id("b"), id("c")])
        #expect(profile.list.map(\.id) == [id("a")] && profile.chrome.map(\.id) == [id("a")])
        #expect(profile.known == [id("a")])
        // Added again on Chromium later: it comes back to the list.
        profile.install("b")
        profile.pass()
        #expect(profile.list.map(\.id) == [id("a"), id("b")])
        #expect(profile.dropped == [id("b"), id("c")])
    }

    /// An install read after a pass's plan takes one more pass; one the
    /// pass is taking off Chromium doesn't start another.
    @Test func anInstallDuringAPassAsksForAnotherOne() {
        let list = [item("a")]
        #expect(!ExtensionOneList.wantsPass(native: [id("a")], list: list, known: nil))
        #expect(ExtensionOneList.wantsPass(native: [id("a"), id("b")], list: list, known: nil))
        #expect(ExtensionOneList.wantsPass(native: [id("a"), id("b")], list: list, known: [id("a")]))
        #expect(!ExtensionOneList.wantsPass(native: [id("a"), id("b")], list: list, known: [id("a"), id("b")]))
        #expect(ExtensionOneList.wantsPass(native: [id("a"), id("b"), id("c")], list: list, known: [id("a"), id("b")]))
    }

    /// A profile that lost everything brings it back rather than emptying the list.
    @Test func missingFromChromiumIsBroughtNeverForgotten() {
        let plan = ExtensionOneList.plan(list: [item("a"), item("b")], native: [], known: [id("a"), id("b")])
        #expect(plan.bringToChromium.map(\.id) == [id("a"), id("b")])
        #expect(plan.dropFromChromium.isEmpty)
    }

    @Test func storageFollowsEachSideAndTheLastWriterTakesAConflict() {
        let shadow = ["same": "1", "editedC": "1", "editedW": "1", "goneC": "1", "goneW": "1", "both": "1"]
        let chromium = ["same": "1", "editedC": "2", "editedW": "1", "goneW": "1", "both": "c", "newC": "1"]
        let webKit = ["same": "1", "editedC": "1", "editedW": "2", "goneC": "1", "both": "w", "newW": "1"]
        let newer = ExtensionOneList.crossing(chromium: chromium, webKit: webKit, shadow: shadow, chromiumNewer: true)
        #expect(newer.toWebKit == ["both", "editedC", "newC"])
        #expect(newer.toChromium == ["editedW", "newW"])
        #expect(newer.removeFromWebKit == ["goneC"])
        #expect(newer.removeFromChromium == ["goneW"])
        let older = ExtensionOneList.crossing(chromium: chromium, webKit: webKit, shadow: shadow, chromiumNewer: false)
        #expect(older.toChromium == ["both", "editedW", "newW"])
    }

    /// The first time nothing counts as removed: each side keeps what it has.
    @Test func theFirstCrossingIsAUnion() {
        let first = ExtensionOneList.crossing(chromium: ["a": "1", "b": "1"], webKit: ["b": "2", "c": "1"], shadow: nil, chromiumNewer: false)
        #expect(first.toWebKit == ["a"])
        #expect(first.toChromium == ["b", "c"])
        #expect(first.removeFromChromium.isEmpty && first.removeFromWebKit.isEmpty)
    }

    @Test func aValueHashesTheSameFromEitherEngine() {
        #expect(ChromiumExtensionStorage.hash(#"{"b":1,"a":[1.0,"x/y"]}"#) == ChromiumExtensionStorage.hash(#"{"a":[1,"x\/y"],"b":1.0}"#))
        #expect(ChromiumExtensionStorage.hash("{oops") == nil)
        #expect(!ChromiumExtensionStorage.crosses("__yabWorkerLife"))
    }

    @Test func webKitsDatabaseTakesValuesAndGivesThemBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("x/LocalStorage.db")
        #expect(ChromiumExtensionStorage.write(file, values: [(key: "a", value: "1"), (key: "b", value: "\"é\"")], removed: []))
        #expect(ChromiumExtensionStorage.write(file, values: [(key: "a", value: "2")], removed: ["b"]))
        let rows = try #require(ChromiumExtensionStorage.rows(file))
        #expect(rows.map(\.key) == ["a"])
        #expect(rows.first?.value == "2")
    }

    @Test func theHookArmsOnceKeepsUseStrictFirstAndComesOffForWebKit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("js"), withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"x","version":"1","background":{"service_worker":"js/sw.js"}}"#
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let worker = folder.appendingPathComponent("js/sw.js")
        let original = "'use strict';\nconsole.log(1);\n"
        try original.write(to: worker, atomically: true, encoding: .utf8)
        #expect(try ChromiumExtensionPackages.arm(folder))
        #expect(try !ChromiumExtensionPackages.arm(folder))
        let armed = try String(contentsOf: worker, encoding: .utf8)
        #expect(armed.hasPrefix("/*yab-action-hook-1*/'use strict';"))
        #expect(armed.hasSuffix(original))
        try ChromiumExtensionPackages.plain(folder)
        #expect(try String(contentsOf: worker, encoding: .utf8) == original)
    }

    @Test func oneBroughtInKeepsItsArrivalHookUntilItIsAPackageAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"x","version":"1","background":{"service_worker":"sw.js"}}"#
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let worker = folder.appendingPathComponent("sw.js")
        let original = "chrome.runtime.onInstalled.addListener(d => d.reason === '" + "__yabBroughtIn" + "');\n"
        try original.write(to: worker, atomically: true, encoding: .utf8)
        #expect(try ChromiumExtensionPackages.arm(folder))
        #expect(try !String(contentsOf: worker, encoding: .utf8).contains(ChromiumArrivalHook.source))
        #expect(try ChromiumExtensionPackages.arm(folder, broughtIn: true))
        #expect(try String(contentsOf: worker, encoding: .utf8).contains(ChromiumArrivalHook.source))
        // A pass's arm keeps it: no change, so no reload under the load.
        #expect(try !ChromiumExtensionPackages.arm(folder))
        #expect(try String(contentsOf: worker, encoding: .utf8).hasSuffix(original))
        #expect(try ChromiumExtensionPackages.arm(folder, broughtIn: false))
        #expect(try !String(contentsOf: worker, encoding: .utf8).contains(ChromiumArrivalHook.source))
        #expect(try String(contentsOf: worker, encoding: .utf8).hasSuffix(original))
    }

    @Test func aModuleWorkerImportsItsHookFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("js"), withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"x","version":"1","background":{"service_worker":"js/sw.js","type":"module"}}"#
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let worker = folder.appendingPathComponent("js/sw.js")
        let side = folder.appendingPathComponent("js/yab-hook-1.js")
        let original = "import './app.js';\n"
        try original.write(to: worker, atomically: true, encoding: .utf8)
        #expect(try ChromiumExtensionPackages.arm(folder, broughtIn: true))
        #expect(try !ChromiumExtensionPackages.arm(folder))
        let armed = try String(contentsOf: worker, encoding: .utf8)
        #expect(armed.hasPrefix("/*yab-action-hook-1*/import './yab-hook-1.js';\n"))
        #expect(armed.hasSuffix(original))
        #expect(try String(contentsOf: side, encoding: .utf8) == ChromiumActionHook.source + ChromiumArrivalHook.source)
        #expect(try ChromiumExtensionPackages.arm(folder, broughtIn: false))
        #expect(try String(contentsOf: side, encoding: .utf8) == ChromiumActionHook.source)
        try ChromiumExtensionPackages.plain(folder)
        #expect(try String(contentsOf: worker, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: side.path))
    }

    @Test func aWorkerOutsideItsPackageIsLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"x","version":"1","background":{"service_worker":"../sw.js"}}"#
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        #expect(try !ChromiumExtensionPackages.arm(folder))
    }

    @Test func aQuestionsLinesNameWhatChromeAddsInOneOfEach() {
        let lines = ChromiumInstallWords.lines(["permission:debugger", "permission:tabCapture", "permission:desktopCapture", "site:https://a.test/*"])
        #expect(lines == ["Capture content of your screen", "Access the page debugger backend", "Read and change pages on https://a.test/*"])
    }
}

struct UnpackedIdentityTests {
    @Test func identitySurvivesVersionChangesAndAnExplicitKey() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(#"{"manifest_version":3,"name":"Fixture","version":"1.0"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        let first = try ChromiumExtensionPackages.unpackedID(source)
        #expect(ChromiumExtensions.validID(first))
        #expect(try ChromiumExtensionPackages.unpackedID(source) == first)
        let key = try ChromiumExtensionPackages.unpackedKey(source)
        let keyed: [String: Any] = ["manifest_version": 3, "name": "Fixture", "version": "2.0", "key": key.base64EncodedString()]
        try JSONSerialization.data(withJSONObject: keyed).write(to: source.appendingPathComponent("manifest.json"))
        #expect(try ChromiumExtensionPackages.unpackedID(source) == first)
        let original = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        try Data("original popup".utf8).write(to: source.appendingPathComponent("popup.html"))
        let native = try ChromiumExtensionPackages.prepareUnpacked(source, id: first)
        defer { try? FileManager.default.removeItem(at: native) }
        #expect(try Data(contentsOf: source.appendingPathComponent("manifest.json")) == original)
        #expect(try String(contentsOf: native.appendingPathComponent("popup.html"), encoding: .utf8) == "original popup")
        try Data("edited popup".utf8).write(to: source.appendingPathComponent("popup.html"))
        #expect(try ChromiumExtensionPackages.prepareUnpacked(source, id: first) == native)
        #expect(try String(contentsOf: native.appendingPathComponent("popup.html"), encoding: .utf8) == "edited popup")
    }
}
