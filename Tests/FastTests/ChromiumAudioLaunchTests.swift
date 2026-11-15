import Foundation
import Testing
@testable import Fast

struct ChromiumAudioLaunchTests {
    @Test func ordinaryLaunchKeepsAudioInTheContainingApp() {
        let root = URL(fileURLWithPath: "/tmp/Yab Audio/Chromium")
        let arguments = ChromiumProcess.launchArguments(socket: "/tmp/core.sock", dataRoot: root)
        #expect(arguments.contains("--socket=/tmp/core.sock"))
        #expect(arguments.contains("--data-root=" + root.path))
        #expect(!arguments.contains("--disable-auto-reload"))
        let disabled = arguments.filter { $0.hasPrefix("--disable-features=") }
        #expect(disabled == ["--disable-features=AudioServiceOutOfProcess"])
    }
}
