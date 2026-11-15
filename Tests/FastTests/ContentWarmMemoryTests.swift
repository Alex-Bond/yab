import Foundation
import Testing
@testable import Fast

/// Only sources actually selected for a spare belong in its shared text
/// cache. These tests use files, not an extension controller or a web view.
@MainActor
struct ContentWarmMemoryTests {
    private func fixture(_ sources: [String]) throws -> (folder: URL, files: [ContentWarm.ScriptFile]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-warm-memory-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [ContentWarm.ScriptFile] = []
        do {
            for (index, source) in sources.enumerated() {
                let file = folder.appendingPathComponent("\(index).js")
                try source.write(to: file, atomically: true, encoding: .utf8)
                files.append(ContentWarm.ScriptFile(file: file, url: URL(string: "warm-extension://fixture/\(index).js")!))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return (folder, files)
    }

    @Test func selectionStopsAtTheFirstScriptThatDoesNotFit() throws {
        let fixture = try fixture(["aa", "bbb", "c"])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        var cache = ContentWarm.TextCache()
        let selected = cache.scripts(fixture.files, cap: 4)
        #expect(selected.map(\.url) == [fixture.files[0].url])
        #expect(selected.map { $0.source as String } == ["aa"])
        // A small script after the rejected one must not be substituted in.
        #expect(cache.scripts(fixture.files, cap: 5).map(\.url) == Array(fixture.files.prefix(2)).map(\.url))
    }

    @Test func theCapCountsUTF16CodeUnitsAndAllowsAnExactFit() throws {
        let fixture = try fixture(["a😀", "e\u{301}", "z"])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        var cache = ContentWarm.TextCache()
        let exact = cache.scripts(fixture.files, cap: 5)
        #expect(exact.map { $0.source.length } == [3, 2])
        #expect(exact.map(\.url) == Array(fixture.files.prefix(2)).map(\.url))
        #expect(cache.scripts(fixture.files, cap: 4).map(\.url) == [fixture.files[0].url])
    }

    @Test func aPreviouslyCachedOverCapStringIsReleased() throws {
        let source = String(repeating: "large script 😀;\n", count: 20_000)
        let fixture = try fixture([source])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        var cache = ContentWarm.TextCache()
        weak var retained: NSString?
        autoreleasepool {
            retained = cache.scripts(fixture.files, cap: source.utf16.count).first?.source
        }
        #expect(retained != nil, "The admitted text should be cached")
        autoreleasepool {
            #expect(cache.scripts(fixture.files, cap: 1).isEmpty)
        }
        #expect(retained == nil, "The cache must not retain the text of a rejected script")
        // Its remembered length may be reused, but never the rejected string.
        autoreleasepool {
            #expect(cache.scripts(fixture.files, cap: 1).isEmpty)
        }
        #expect(retained == nil)
    }

    @Test func scriptsNoLongerInTheSelectedProfileAreReleased() throws {
        let source = String(repeating: "selected script;\n", count: 10_000)
        let replacement = String(repeating: "another extension;\n", count: 8_000)
        let fixture = try fixture([source, replacement])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        var cache = ContentWarm.TextCache()
        weak var retained: NSString?
        autoreleasepool {
            retained = cache.scripts(fixture.files, cap: source.utf16.count).first?.source
        }
        #expect(retained != nil)
        weak var next: NSString?
        autoreleasepool {
            next = cache.scripts([fixture.files[1]], cap: replacement.utf16.count).first?.source
        }
        #expect(retained == nil, "Replacing the active extension profile must prune its old sources")
        #expect(next != nil)
        autoreleasepool {
            #expect(cache.scripts([], cap: source.utf16.count).isEmpty)
        }
        #expect(next == nil, "Disabling or uninstalling the last extension must empty the cache")
    }

    @Test func anUnchangedAdmittedFileReusesItsNSStringAndAChangedFileReplacesIt() throws {
        let source = String(repeating: "original script;\n", count: 1_000)
        let fixture = try fixture([source])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        var cache = ContentWarm.TextCache()
        let first = try #require(cache.scripts(fixture.files, cap: source.utf16.count).first?.source)
        let again = try #require(cache.scripts(fixture.files, cap: source.utf16.count).first?.source)
        #expect(first === again)
        let replacement = "replacement;"
        try replacement.write(to: fixture.files[0].file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: fixture.files[0].file.path)
        let changed = try #require(cache.scripts(fixture.files, cap: source.utf16.count).first?.source)
        #expect(changed as String == replacement)
        #expect(changed !== first)
    }

    @Test func anUnreadableScriptIsSkippedWithoutChangingTheOrderOrSourceURLs() throws {
        let fixture = try fixture(["first", "second"])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let missing = ContentWarm.ScriptFile(file: fixture.folder.appendingPathComponent("missing.js"),
                                             url: URL(string: "warm-extension://fixture/missing.js")!)
        var cache = ContentWarm.TextCache()
        let selected = cache.scripts([missing] + fixture.files, cap: 11)
        #expect(selected.map(\.url) == fixture.files.map(\.url))
        #expect(selected.map { $0.source as String } == ["first", "second"])
    }
}
