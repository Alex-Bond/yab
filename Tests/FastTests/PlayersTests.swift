import Foundation
import Testing
@testable import Fast

/// The sites whose playing video Picture in Picture automatically follows.
struct PlayersTests {
    @Test func unlistedSitesRequireAUserStartedVideo() {
        #expect(Players.automaticPolicy(URL(string: "https://studio.example/film")) == 2)
        #expect(Players.automaticPolicy(nil) == 2)
        #expect(Players.automaticPolicy(URL(string: "https://www.youtube.com/watch?v=1")) == 1)
        #expect(Players.automaticPolicy(URL(string: "https://amazon.com/gp/video/detail/1")) == 1)
        #expect(Players.automaticPolicy(URL(string: "https://amazon.com/shop")) == 2)
    }

    @Test func bilibiliIsASiteToWatchOn() {
        // Row 1111: its videos never came out on their own.
        for address in [
            "https://www.bilibili.com/video/BV1GJ411x7h7/",
            "https://www.bilibili.com/bangumi/play/ep123",
            "https://live.bilibili.com/21452505",
            "https://m.bilibili.com/video/BV1GJ411x7h7",
            "https://www.bilibili.tv/en/video/2041863208",
        ] {
            #expect(Players.knows(URL(string: address)), "\(address)")
        }
    }

    @Test func lookalikeHostsAreNot() {
        #expect(!Players.knows(URL(string: "https://notbilibili.com/video/1")))
        #expect(!Players.knows(URL(string: "https://example.com/bilibili.com")))
    }
}
