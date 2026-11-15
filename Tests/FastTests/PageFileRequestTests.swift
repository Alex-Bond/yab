import Testing
@testable import Fast

@Suite(.serialized) @MainActor
struct PageFileRequestTests {
    @Test func cancellationBeforeUISubscribesPreventsLatePresentation() {
        let requests = PageFileRequests()
        let first = requests.begin("first")
        requests.cancel("first")
        var cancelled = 0
        first.whenCancelled { cancelled += 1 }
        #expect(cancelled == 1)
        #expect(!first.isActive)
        #expect(!requests.finish("first", first))
        requests.cancel("first")
        #expect(cancelled == 1)
    }

    @Test func replacementRetiresOldScanWithoutCancellingTheNewChooser() {
        let requests = PageFileRequests()
        let old = requests.begin("old")
        var oldScanCanPresent = true
        old.whenCancelled { oldScanCanPresent = false }
        let current = requests.begin("new")
        #expect(!oldScanCanPresent)
        #expect(!requests.finish("old", old))
        requests.cancel("old")
        #expect(current.isActive)
        #expect(requests.finish("new", current))
        #expect(!requests.finish("new", current))
    }

    @Test func helperReconnectCannotReuseAnOldCallbackEvenWithTheSameToken() {
        let requests = PageFileRequests()
        let previousHelper = requests.begin("native-1")
        requests.cancel()
        let nextHelper = requests.begin("native-1")
        #expect(!requests.finish("native-1", previousHelper))
        #expect(nextHelper.isActive)
        #expect(requests.finish("native-1", nextHelper))
    }

    @Test func successfulReplyReleasesObserversAndCannotBeRepliedAgain() {
        let requests = PageFileRequests()
        let request = requests.begin("choose")
        var cancellation = 0
        request.whenCancelled { cancellation += 1 }
        #expect(requests.finish("choose", request))
        requests.cancel()
        request.cancel()
        request.whenCancelled { cancellation += 1 }
        #expect(cancellation == 0)
        #expect(!request.isActive)
        #expect(!requests.finish("choose", request))
    }

    @Test func cancellationInvalidatesUIBeforeCallingObservers() {
        let requests = PageFileRequests()
        let request = requests.begin("choose")
        var latePanelReply = true
        request.whenCancelled { latePanelReply = requests.finish("choose", request) }
        requests.cancel()
        #expect(!latePanelReply)
        #expect(!request.isActive)
    }
}
