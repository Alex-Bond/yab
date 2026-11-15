import Foundation
import Testing
@testable import Fast

@MainActor
struct DefaultBrowserChangeTests {
    @Test func alreadyDefaultFinishesWithoutAnotherSystemQuestion() {
        var requests = 0, html = 0
        var result: Bool?
        let change = DefaultBrowserChange(current: { _ in true }, request: { _, _ in requests += 1 },
                                          html: { html += 1 }, completion: { result = $0 })
        change.start()
        #expect(result == true)
        #expect(requests == 0)
        #expect(html == 1)
    }

    @Test func schemeQuestionsAreSerialAndHTMLDoesNotHoldCompletion() {
        var requests: [String] = []
        var answers: [String: (Bool) -> Void] = [:]
        var result: Bool?, html = 0
        let change = DefaultBrowserChange(current: { _ in false }, request: { scheme, answer in
            requests.append(scheme); answers[scheme] = answer
        }, html: { html += 1 }, completion: { result = $0 })
        change.start()
        #expect(requests == ["http"])
        answers["http"]?(true)
        #expect(requests == ["http", "https"])
        #expect(result == nil)
        answers["https"]?(true)
        #expect(result == true)
        #expect(html == 1)
    }

    @Test func changedHandlersRecoverMissingCallbacksAndIgnoreLateOnes() {
        var handlers = Set<String>(), answers: [String: (Bool) -> Void] = [:]
        var results: [Bool] = []
        let change = DefaultBrowserChange(current: { handlers.contains($0) }, request: { answers[$0] = $1 },
                                          html: {}, completion: { results.append($0) })
        change.start()
        handlers.insert("http")
        change.check()
        answers["http"]?(false)
        #expect(results.isEmpty)
        handlers.insert("https")
        change.check()
        answers["https"]?(false)
        #expect(results == [true])
    }

    @Test func refusalDoesNotAssignHTMLOrAskForAnotherScheme() {
        var requests: [String] = [], html = 0
        var result: Bool?
        let change = DefaultBrowserChange(current: { _ in false }, request: { scheme, answer in
            requests.append(scheme); answer(false)
        }, html: { html += 1 }, completion: { result = $0 })
        change.start()
        #expect(result == false)
        #expect(requests == ["http"])
        #expect(html == 0)
    }

    @Test func anUnansweredQuestionExpiresOnce() {
        var answer: ((Bool) -> Void)?
        var results: [Bool] = [], html = 0
        let change = DefaultBrowserChange(current: { _ in false }, request: { _, callback in answer = callback },
                                          html: { html += 1 }, completion: { results.append($0) })
        change.start()
        change.check(now: Date().addingTimeInterval(61))
        answer?(true)
        #expect(results == [false])
        #expect(html == 0)
    }
}
