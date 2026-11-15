import Foundation
import Testing
@testable import Fast

// The words at a mark's corner: the count a title carries, and the plate.
struct CornerTests {
    @Test func countsInTitles() {
        #expect(Counts.fromTitle("(3) Home / X") == 3)
        #expect(Counts.fromTitle("(12) Discord | #general | Yab") == 12)
        #expect(Counts.fromTitle("Inbox (12) - anna@example.com - Gmail") == 12)
        #expect(Counts.fromTitle("Inbox (1,204) - anna@example.com - Gmail") == 1204)
        #expect(Counts.fromTitle("Starred (2) - anna@example.com - Gmail") == 2)
        #expect(Counts.fromTitle("Telegram (3)") == 3)
        #expect(Counts.fromTitle("(99+) Feed | LinkedIn") == 99)
        #expect(Counts.fromTitle("  (4) WhatsApp ") == 4)
    }

    @Test func noCounts() {
        #expect(Counts.fromTitle("Inbox - anna@example.com - Gmail") == nil)
        #expect(Counts.fromTitle("Slack | general | Yab") == nil)
        #expect(Counts.fromTitle("") == nil)
        // A number in the middle of words is the page's, not a count.
        #expect(Counts.fromTitle("Design review (Q3) notes - Google Docs") == nil)
        #expect(Counts.fromTitle("The 2026 plan (draft 2) and more - Notion") == nil)
        #expect(Counts.fromTitle("iPhone 17 (256 GB) - Apple") == nil)
    }

    @Test func sites() {
        #expect(Counts.site(URL(string: "https://www.linkedin.com/feed/")) == "linkedin.com")
        #expect(Counts.site(URL(string: "https://mail.google.com/mail/u/0/#inbox")) == "mail.google.com")
        #expect(Counts.sites.contains("mail.google.com"))
        #expect(!Counts.sites.contains("youtube.com"))
    }

    @Test func counts() {
        #expect(Corner.count(0) == nil)
        #expect(Corner.count(4)?.words == "4")
        #expect(Corner.count(100)?.words == "99+")
    }

    @Test func plates() {
        let one = CornerPlate.size("4"), two = CornerPlate.size("12"), three = CornerPlate.size("99+")
        // One character is a circle; more grow wider, never taller.
        #expect(one.width == CornerPlate.height && one.height == CornerPlate.height)
        #expect(two.width > one.width && three.width > two.width)
        #expect(three.height == CornerPlate.height)
        #expect(CornerPlate.size("12m").width < CornerPlate.size("Join").width + 8)
    }
}

extension CornerTests {
    @Test @MainActor func shortNames() {
        #expect(ShortNames.fits("Nginx reverse proxy", for: "How to Configure Nginx as a Reverse Proxy for Node.js Applications"))
        #expect(!ShortNames.fits("", for: "Anything"))
        #expect(!ShortNames.fits("The title is about Nginx and proxies.", for: "How to Configure Nginx as a Reverse Proxy"))
        #expect(!ShortNames.fits("A very long name that is not shorter at all", for: "Short"))
        #expect(ShortNames.key(URL(string: "https://a.b/c")!, "T").hasPrefix("https://a.b/c"))
    }

    @Test func titlesWithoutCounts() {
        #expect(Counts.untitled("(3) Home / X") == "Home / X")
        #expect(Counts.untitled("Inbox (12) - anna@example.com - Gmail") == "Inbox - anna@example.com - Gmail")
        #expect(Counts.untitled("Telegram (3)") == "Telegram")
        #expect(Counts.untitled("Design review (Q3) notes") == "Design review (Q3) notes")
        #expect(Counts.untitled("(5)") == "(5)")
    }
}
