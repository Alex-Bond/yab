import Foundation
import Testing
@testable import Fast

// What only grew on disk (#685): which sites' caches the daily pass lets
// go of, and the history pictures' limit.
struct DiskGrowthTests {
    let now = Date()
    var days: (Double) -> Date { { self.now.addingTimeInterval(-$0 * 86_400) } }

    @Test func sitesNotVisitedLatelyGo() {
        let visits = ["app.slack.com": days(20), "x.com": days(1), "teams.live.com": days(30)]
        let stale = SiteCaches.stale(["slack.com", "x.com", "live.com"], visits: visits, open: [], notifying: [],
                                     before: days(14))
        #expect(stale == ["slack.com", "live.com"])
    }

    @Test func aVisitToAnySubdomainKeepsTheSite() {
        let visits = ["slack.com": days(40), "app.slack.com": days(2)]
        #expect(SiteCaches.stale(["slack.com"], visits: visits, open: [], notifying: [], before: days(14)).isEmpty)
    }

    @Test func neverVisitedSitesAreLeftToWebKit() {
        // A CDN or a frame's site: its cache serves the sites in use.
        #expect(SiteCaches.stale(["ytimg.com", "googleapis.com"], visits: ["youtube.com": days(30)], open: [],
                                 notifying: [], before: days(14)).isEmpty)
    }

    @Test func openTabsAndNotifyingSitesStay() {
        let visits = ["app.slack.com": days(20), "www.figma.com": days(20), "linear.app": days(20)]
        let stale = SiteCaches.stale(["slack.com", "figma.com", "linear.app"], visits: visits,
                                     open: ["app.slack.com"], notifying: ["www.figma.com"], before: days(14))
        #expect(stale == ["linear.app"])
    }

    @Test func shotsPastTheLimitGoOldestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<10 {
            let file = folder.appendingPathComponent("\(index).jpg")
            try Data(repeating: 1, count: 40_000).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: days(Double(10 - index))], ofItemAtPath: file.path)
        }
        let size = { (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]))?
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) } ?? 0 }
        let limit = size() / 2
        let gone = Diary.trim(folder, to: limit)
        #expect(gone >= 4 && gone <= 6)
        #expect(size() <= limit)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left.contains("9.jpg") && !left.contains("0.jpg"))
        #expect(Diary.trim(folder, to: limit) == 0)
    }
}
