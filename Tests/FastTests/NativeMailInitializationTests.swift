import Foundation
import Testing
@testable import Fast
@testable import MailCore

/// MailList's singleton must be cold here even when another suite has already
/// opened mail. A child in a fresh test world exercises the real initializer.
struct NativeMailInitializationTests {
    @MainActor @Test func coldMailMigrationAndStoredChanges() throws {
        let childKey = "YAB_NATIVE_MAIL_INIT_CHILD"
        guard ProcessInfo.processInfo.environment[childKey] == "1" else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var arguments: [String] = []
            var cursor = 1
            while cursor < CommandLine.arguments.count {
                let argument = CommandLine.arguments[cursor]
                if ["--filter", "--experimental-event-stream-output"].contains(argument) {
                    cursor += 2
                } else {
                    arguments.append(argument)
                    cursor += 1
                }
            }
            arguments += ["--filter", "^FastTests[.]NativeMailInitializationTests/coldMailMigrationAndStoredChanges"]
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment[childKey] = "1"
            environment["YAB_PROBE"] = "native-mail-init-" + UUID().uuidString.lowercased()
            environment["YAB_HISTORY"] = "own"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            // Keep the nested test library's markers out of the outer gate
            // log: it must describe one run, even though this test has a child.
            let outputFolder = ProcessInfo.processInfo.environment["YAB_FARM_OUT"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            let log = outputFolder.appendingPathComponent("native-mail-init-child-" + UUID().uuidString + ".log")
            try data.write(to: log)
            print("NATIVE_MAIL_CHILD_RESULT status=\(process.terminationStatus) log=\(log.path)")
            #expect(process.terminationReason == .exit && process.terminationStatus == 0,
                    "Cold MailList child failed; status \(process.terminationStatus), log \(log.path)")
            let completed = text.contains("NATIVE_MAIL_COLD_COMPLETE")
            #expect(completed, "Cold MailList child did not complete; log \(log.path)")
            if completed { print("NATIVE_MAIL_COLD_COMPLETE: child migration and notification controls passed") }
            return
        }

        try #require(Store.testing && Store.unitTests)
        let defaults = Store.settings
        let preferences = Preferences()
        // This fresh process has not loaded MailList or migrated these keys.
        try #require(defaults.data(forKey: MailSplits.key) == nil)
        let legacy = Data(#"[{"title":"Work","q":"from:example.test","icon":"briefcase","why":"Kept before splits","group":"sender","pages":[{"url":"https://example.test/dashboard","title":"Dashboard"}]}]"#.utf8)
        defaults.set(legacy, forKey: MailSplits.listsKey)
        let setting = try #require(NativeSetting.kept.first { $0.id == "mail-needs" })
        var changes: [NativeValue] = []
        let observation = setting.observe(preferences) { changes.append(setting.read(preferences)) }
        defer { observation.cancel() }
        // On BASE this unrelated notification enters the cold MailList,
        // whose migration posts synchronously and reenters its once token.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

        #expect(changes.isEmpty, "Subscribing and unrelated writes are not setting changes")
        let list = MailList.shared
        let persisted = try #require(defaults.data(forKey: MailSplits.key))
        let saved = try JSONDecoder().decode([MailList.Split].self, from: persisted)
        #expect(saved == list.splits)
        #expect(defaults.data(forKey: MailSplits.listsKey) == legacy)
        let migrated = try #require(saved.first { $0.id == "q:from:example.test" })
        #expect(migrated.title == "Work" && migrated.icon == "briefcase")
        #expect(migrated.why == "Kept before splits" && migrated.group == "sender")
        #expect(migrated.pages == [MailList.Page(url: "https://example.test/dashboard", title: "Dashboard")])
        #expect(migrated.on && migrated.mode == .also && !migrated.notify)
        #expect(Set(saved.map(\.id)) == Set(MailSplits.builtIns.map(\.id) + [migrated.id]))

        // The explicit initial value is skipped, never the first real change.
        #expect(setting.read(preferences) == .bool(true))
        try setting.write(preferences, .bool(false))
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(changes == [.bool(false)])
        try setting.write(preferences, .bool(false))
        defaults.set(1, forKey: "native-mail-init.unrelated")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(changes == [.bool(false)], "Equal values and unrelated writes are deduplicated")
        try setting.write(preferences, .bool(true))
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(changes == [.bool(false), .bool(true)])
        #expect(defaults.string(forKey: "mail.needs") == "asks")
        #expect(defaults.data(forKey: MailSplits.key) == persisted, "Observation must not rewrite the migrated splits")
        #expect(MailSplits.load(defaults) == saved)
        #expect(changes == [.bool(false), .bool(true)])
        observation.cancel()
        try setting.write(preferences, .bool(false))
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(changes == [.bool(false), .bool(true)], "Cancelled subscriptions remain cancelled")
        print("NATIVE_MAIL_COLD_COMPLETE: migration preserved; first and subsequent changes emitted; duplicates suppressed")
    }
}
