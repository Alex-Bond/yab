import Foundation
import Testing
@testable import Fast

struct LiveFolderFeatureTests {
    private func world(_ run: (UserDefaults, URL) throws -> Void) throws {
        let suite = "live-folders-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try run(defaults, folder)
    }

    @Test func newProfilesAreOff() throws {
        try world { defaults, folder in
            #expect(!LiveFolderFeature.initial(in: defaults, folder: folder))
            #expect(defaults.object(forKey: LiveFolderFeature.key) as? Bool == false)
        }
    }

    @Test func existingSessionAndWindowFoldersStayOn() throws {
        for file in ["session.json", "session-another-space.json", "session-window-window-space.json"] {
            try world { defaults, folder in
                try Data(#"{"tabs":[{"folderLive":{"source":"github.pulls"}}]}"#.utf8)
                    .write(to: folder.appendingPathComponent(file))
                #expect(LiveFolderFeature.initial(in: defaults, folder: folder))
            }
        }
    }

    @Test func emptyFoldersStayOn() throws {
        try world { defaults, folder in
            try Data(#"{"space":[{"live":{"source":"youtube"}}]}"#.utf8)
                .write(to: folder.appendingPathComponent("empty-folders.json"))
            #expect(LiveFolderFeature.initial(in: defaults, folder: folder))
        }
    }

    @Test func explicitOffWinsOverSavedFolders() throws {
        try world { defaults, folder in
            defaults.set(false, forKey: LiveFolderFeature.key)
            try Data(#"{"tabs":[{"folderLive":{"source":"github.pulls"}}]}"#.utf8)
                .write(to: folder.appendingPathComponent("session.json"))
            #expect(!LiveFolderFeature.initial(in: defaults, folder: folder))
        }
    }

    @Test func regularFoldersAndHiddenHistoryDoNotOptIn() throws {
        try world { defaults, folder in
            try Data(#"{"tabs":[{"folder":"a","folderLive":null,"live":null}]}"#.utf8)
                .write(to: folder.appendingPathComponent("session.json"))
            try Data(#"{"space":[{"name":"Regular","live":null}]}"#.utf8)
                .write(to: folder.appendingPathComponent("empty-folders.json"))
            try Data(#"{"shown":{"old-folder":["old-tab"]}}"#.utf8)
                .write(to: folder.appendingPathComponent("live-folders.json"))
            #expect(!LiveFolderFeature.initial(in: defaults, folder: folder))
        }
    }

    @Test func migrationOnlyRunsOnceAndDoesNotRewriteSessions() throws {
        try world { defaults, folder in
            #expect(!LiveFolderFeature.initial(in: defaults, folder: folder))
            let file = folder.appendingPathComponent("session.json")
            let data = Data(#"{"tabs":[{"folderLive":{"source":"notion"}}]}"#.utf8)
            try data.write(to: file)
            #expect(!LiveFolderFeature.initial(in: defaults, folder: folder))
            #expect(try Data(contentsOf: file) == data)
        }
    }
}
