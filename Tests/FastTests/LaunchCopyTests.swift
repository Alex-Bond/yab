import Testing
@testable import Fast

/// Crash reports 70 and 71: a `yab mcp` whose app was gone when it started
/// died in CFBundle. Which files say the app is whole, and which binaries
/// are not checked at all.
struct LaunchCopyTests {
    @Test func findsTheAppAroundItsExecutable() {
        #expect(LaunchCopy.appFiles(executable: "/Applications/yab.app/Contents/MacOS/yab")
            == .init(app: "/Applications/yab.app", executable: "/Applications/yab.app/Contents/MacOS/yab",
                     info: "/Applications/yab.app/Contents/Info.plist"))
        // An app inside another one's folder: the innermost bundle.
        #expect(LaunchCopy.appFiles(executable: "/Users/a/Tools.app/Contents/Resources/Code.app/Contents/MacOS/yab")?.app
            == "/Users/a/Tools.app/Contents/Resources/Code.app")
    }

    @Test func bareBinariesAreNotChecked() {
        #expect(LaunchCopy.appFiles(executable: "/Users/a/fast/.build/debug/Fast") == nil)
        #expect(LaunchCopy.appFiles(executable: "/tmp/yab") == nil)
        #expect(LaunchCopy.appFiles(executable: "/Applications/yab.app/Contents/MacOS/") == nil)
        #expect(LaunchCopy.appFiles(executable: "/Applications/yab.app/Contents/MacOS/sub/yab") == nil)
    }

    @Test func wholeNeedsTheExecutableAndItsInfo() throws {
        let files = try #require(LaunchCopy.appFiles(executable: "/Applications/yab.app/Contents/MacOS/yab"))
        #expect(LaunchCopy.whole(files) { _ in true })
        // Moved aside or removed by an update: nothing at the path.
        #expect(!LaunchCopy.whole(files) { _ in false })
        // A new copy half written by Finder: the binary there, no Info.plist yet.
        #expect(!LaunchCopy.whole(files) { $0 == files.executable })
    }
}
