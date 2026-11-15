import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct PageAskLifetimeTests {
    private func fixture(_ check: (Browser, Tab) throws -> Void) rethrows {
        let browser = Browser(windowID: UUID())
        let tab = Tab()
        tab.restore(url: URL(string: "https://vpn.example.com/login")!, title: "VPN")
        browser.outside.append(tab)
        defer {
            browser.dropAsks(tab)
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
        }
        try check(browser, tab)
    }

    @Test func provisionalAddressesKeepEveryKindOfPermissionAsk() {
        fixture { browser, tab in
            let kinds: [PageAsk.Kind] = [
                .app(URL(string: "f5-epi://localhost/inspect")!, URL(fileURLWithPath: "/Applications/F5 Endpoint Inspector.app")),
                .capture(.camera), .capture(.microphone), .capture(.cameraAndMicrophone),
                .location, .notifications, .localNetwork(true), .download, .downloads
            ]
            for kind in kinds {
                tab.restore(url: URL(string: "https://vpn.example.com/login")!, title: "VPN")
                let question = PageAsk(kind: kind, host: "vpn.example.com")
                var replies = 0
                browser.ask(question, on: tab) { _, _ in replies += 1 }
                tab.hushed = "vpn.example.com"
                for address in ["f5-epi://localhost/inspect", "https://download.example.net/inspector", "about:blank"] {
                    let url = URL(string: address)!
                    // No current history item: shownHost falls back to the
                    // provisional address, not the document that asked.
                    tab.restore(url: url, title: "VPN")
                    #expect(tab.built == nil)
                    browser.asksMoved(tab, to: url)
                    #expect(tab.asks.first?.id == question.id)
                    #expect(replies == 0)
                    #expect(Asks.owed[question.id] != nil)
                    #expect(tab.hushed == "vpn.example.com")
                }
                browser.answer(tab, .no)
                #expect(replies == 1)
                #expect(tab.asks.isEmpty)
            }
        }
    }

    @Test func aCommittedPageAtTheSameSiteKeepsTheAsk() {
        fixture { browser, tab in
            let question = PageAsk(kind: .location, host: "vpn.example.com")
            var replies = 0
            browser.ask(question, on: tab) { _, _ in replies += 1 }
            browser.asksMoved(tab, to: URL(string: "https://auth.example.com/check#ready")!, committed: true)
            #expect(tab.asks.first?.id == question.id)
            #expect(replies == 0)
        }
    }

    @Test func aCommittedPageAtAnotherSiteRejectsTheWholeQueueOnce() {
        fixture { browser, tab in
            let first = PageAsk(kind: .location, host: "vpn.example.com")
            let second = PageAsk(kind: .notifications, host: "vpn.example.com")
            var rejected: [UUID] = []
            for question in [first, second] {
                browser.ask(question, on: tab) { reply, answered in
                    if case .no = reply { rejected.append(answered.id) }
                    else { Issue.record("Leaving must not grant access") }
                }
            }
            #expect(tab.asks.map(\.id) == [first.id, second.id])
            browser.asksMoved(tab, to: URL(string: "https://other.example.net/")!, committed: true)
            browser.dropAsks(tab)
            #expect(tab.asks.isEmpty)
            #expect(rejected == [first.id, second.id])
            #expect(Asks.owed[first.id] == nil && Asks.owed[second.id] == nil)
        }
    }

    @Test func aCommittedHostlessPageRejectsTheAsk() {
        fixture { browser, tab in
            let question = PageAsk(kind: .location, host: "vpn.example.com")
            var rejected = false
            browser.ask(question, on: tab) { reply, _ in
                if case .no = reply { rejected = true }
            }
            browser.asksMoved(tab, to: URL(string: "about:blank")!, committed: true)
            #expect(tab.asks.isEmpty)
            #expect(rejected)
        }
    }

    @Test func answeringTheHandoffSettlesOnlyThatQuestion() {
        fixture { browser, tab in
            let first = PageAsk(kind: .app(URL(string: "f5-epi://localhost/inspect")!,
                                          URL(fileURLWithPath: "/Applications/F5 Endpoint Inspector.app")), host: "vpn.example.com")
            let second = PageAsk(kind: .location, host: "vpn.example.com")
            var opened = 0, rejected = 0
            browser.ask(first, on: tab) { reply, _ in
                if case .yes = reply { opened += 1 }
            }
            browser.ask(second, on: tab) { reply, _ in
                if case .no = reply { rejected += 1 }
            }
            #expect(tab.asks.map(\.id) == [first.id, second.id])
            browser.answer(tab, .yes(nil))
            #expect(opened == 1 && rejected == 0)
            #expect(tab.asks.first?.id == second.id)
            #expect(Asks.owed[first.id] == nil)
            browser.answer(tab, .no)
            browser.dropAsks(tab)
            #expect(opened == 1 && rejected == 1)
            #expect(tab.asks.isEmpty)
        }
    }

    @Test func captureHasTwoAnswersAndNoCheckbox() {
        fixture { browser, tab in
            for reply: AskReply in [.yes(nil), .no] {
                let question = PageAsk.capture(.cameraAndMicrophone, host: "meet.example.com")
                #expect(question.box == nil)
                #expect(AskCard.width(question) == 440)
                var kept = false
                browser.ask(question, on: tab) { _, answered in kept = answered.ticked }
                browser.answer(tab, reply)
                if case .yes = reply { #expect(kept) } else { #expect(!kept) }
                browser.dropAsks(tab)
            }
        }
    }

    @Test func leavingWhileMacOSAsksCancelsItsWaitOnce() {
        fixture { browser, tab in
            var question = PageAsk(kind: .capture(.camera), host: "vpn.example.com")
            question.stage = .waiting
            var replies = 0, canceled = 0
            browser.ask(question, on: tab) { _, _ in replies += 1 }
            Asks.waiting[question.id] = { allowed in
                #expect(!allowed)
                canceled += 1
            }
            browser.asksMoved(tab, to: URL(string: "https://other.example.net/")!)
            #expect(replies == 0 && canceled == 0)
            browser.asksMoved(tab, to: URL(string: "https://other.example.net/")!, committed: true)
            browser.dropAsks(tab)
            #expect(replies == 1 && canceled == 1)
            #expect(Asks.waiting[question.id] == nil)
        }
    }

    @Test func closingThePageRejectsItsPendingAskOnce() {
        fixture { browser, tab in
            let question = PageAsk(kind: .location, host: "vpn.example.com")
            var replies = 0
            browser.ask(question, on: tab) { reply, _ in
                if case .no = reply { replies += 1 }
            }
            browser.letGo(outside: tab)
            browser.dropAsks(tab)
            #expect(tab.asks.isEmpty)
            #expect(replies == 1)
            #expect(Asks.owed[question.id] == nil)
        }
    }

    @Test func withdrawingANativeLeaveKeepsAnotherQuestionAndSettlesOnce() {
        fixture { browser, tab in
            let first = PageAsk(kind: .location, host: "vpn.example.com")
            let leave = PageAsk(kind: .leave, host: "vpn.example.com")
            var leaveReplies = 0, firstReplies = 0
            browser.ask(first, on: tab) { _, _ in firstReplies += 1 }
            browser.ask(leave, on: tab) { reply, _ in
                if case .no = reply { leaveReplies += 1 }
                else { Issue.record("A withdrawn native approval must not authorize closing") }
            }
            browser.withdrawAsk(leave.id, on: tab)
            browser.withdrawAsk(leave.id, on: tab)
            #expect(tab.asks.map(\.id) == [first.id])
            #expect(firstReplies == 0 && leaveReplies == 1)
            #expect(Asks.owed[leave.id] == nil && Asks.owed[first.id] != nil)
        }
    }
}
