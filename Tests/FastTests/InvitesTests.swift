import Foundation
import Testing
@testable import Fast

// Invite a Friend (Invites.swift): the code in the address a download came
// from, and what a locked icon takes.
@MainActor
struct InvitesTests {
    @Test func codeFromThePage() {
        #expect(Invites.code(in: "https://yetanotherbrowser.com/hi/k7m2qp9x") == "k7m2qp9x")
        #expect(Invites.code(in: "https://yetanotherbrowser.com/hi/k7m2qp9x/yab.dmg") == "k7m2qp9x")
    }

    @Test func codeFromTheFile() {
        #expect(Invites.code(in: "https://abc.public.blob.vercel-storage.com/releases/yab-0.0.24.dmg?c=k7m2qp9x") == "k7m2qp9x")
    }

    @Test func noCodeElsewhere() {
        #expect(Invites.code(in: "https://yetanotherbrowser.com/download") == nil)
        #expect(Invites.code(in: "https://yetanotherbrowser.com/hi/") == nil)
        #expect(Invites.code(in: "https://yetanotherbrowser.com/hi/a%20b") == nil)
        #expect(Invites.code(in: "not a url") == nil)
    }

    @Test func ladderIsInOrder() {
        let needs = Invites.ladder.map(\.friends)
        #expect(needs == needs.sorted())
        #expect(Invites.ladder.first?.style == .waxSeal)
    }

    @Test func friendIconsAreChoices() {
        for rung in Invites.ladder { #expect(AppIconStyle.choices.contains(rung.style)) }
        #expect(AppIconStyle.choices.contains(.charm))
    }

    // MARK: Post About Yab (PostReward.swift)

    @Test func postAddressesAreTold() {
        #expect(PostReward.isPost(URL(string: "https://x.com/dana/status/1849")!))
        #expect(PostReward.isPost(URL(string: "https://twitter.com/dana/status/1849/")!))
        #expect(!PostReward.isPost(URL(string: "https://x.com/intent/post?text=hi")!))
        #expect(!PostReward.isPost(URL(string: "https://x.com/home")!))
        #expect(!PostReward.isPost(URL(string: "https://evil.com/dana/status/1849")!))
    }

    @Test func linksCountAsXCountsThem() {
        let link = "yetanotherbrowser.com/hi/k7m2qp9x"
        #expect(PostFacts.xLength("Try it: \(link)") == "Try it: ".count + 23)
        #expect(PostFacts.xLength("https://x.com/a/status/1 ok") == 23 + 3)
    }

    @Test func onlyEnglishShortWithTheLinkGoes() {
        let link = "yetanotherbrowser.com/hi/k7m2qp9x"
        #expect(PostFacts.fits("Best Arc alternative I've tried, and the AI actually does things. \(link)", link: link))
        #expect(!PostFacts.fits("Best Arc alternative I've tried, and the AI actually does things.", link: link))
        #expect(!PostFacts.fits("Best Arc alternative \u{2014} the AI actually does things. \(link)", link: link))
        #expect(!PostFacts.fits(String(repeating: "word ", count: 60) + link, link: link))
    }

    @Test func everyShapeFitsForEveryone() {
        let link = "yetanotherbrowser.com/hi/k7m2qp9x"
        let weeks = Date().addingTimeInterval(-21 * 86_400)
        let people = [
            PostFacts(from: "Arc", since: weeks, broughtIn: true, agent: "Claude Code", plan: "Max", tasks: 31, hours: 6, asks: 212, mailZero: 0, ads: 0),
            PostFacts(from: "Chrome", since: weeks, broughtIn: true, agent: "Codex", plan: "Plus", tasks: 14, hours: 2, asks: 0, mailZero: 9, ads: 18_400),
            PostFacts(from: nil, since: Date().addingTimeInterval(-4 * 86_400), broughtIn: false, agent: nil, plan: nil, tasks: 0, hours: 0, asks: 40, mailZero: 0, ads: 0),
            PostFacts(from: nil, since: nil, broughtIn: false, agent: nil, plan: nil, tasks: 0, hours: 0, asks: 0, mailZero: 0, ads: 0),
        ]
        for person in people {
            for angle in PostFacts.Angle.allCases {
                let post = PostFacts.template(person, angle: angle, link: link)
                #expect(PostFacts.fits(post, link: link), "\(angle): \(post)")
            }
        }
    }

    @Test func peopleAlikeStartDifferently() {
        let facts = PostFacts(from: nil, since: nil, broughtIn: false, agent: nil, plan: nil, tasks: 0, hours: 0, asks: 3, mailZero: 0, ads: 0)
        let firsts = Set((0 ..< 40).map { PostFacts.angle(seed: "install-\($0)", step: 0, facts: facts) })
        #expect(firsts.count >= 4)
        // Another goes round every angle before one comes again.
        let round = (0 ..< PostFacts.Angle.allCases.count).map { PostFacts.angle(seed: "same", step: $0, facts: facts) }
        #expect(Set(round).count == PostFacts.Angle.allCases.count)
    }

    @Test func aSwitchStartsFromTheSwitch() {
        let facts = PostFacts(from: "Arc", since: nil, broughtIn: true, agent: nil, plan: nil, tasks: 0, hours: 0, asks: 0, mailZero: 0, ads: 0)
        #expect(PostFacts.angle(seed: "any", step: 0, facts: facts) == .switched)
    }

    @Test func surpriseStandsForThePostIcons() {
        #expect(!AppIconStyle.surprise.unlocked)
        for style in PostReward.icons {
            #expect(AppIconStyle.choices.contains(style) == style.unlocked)
        }
        #expect(AppIconStyle.choices.contains(.surprise) == !PostReward.icons.allSatisfy(\.unlocked))
    }
}
