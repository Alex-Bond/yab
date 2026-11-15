import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct PiPCloseDeliveryTests {
    private final class Controller: NSViewController {
        @objc weak var delegate: NSObject?
    }
    private final class Delegate: NSObject {
        var calls = 0
        var whenClosed: (() -> Void)?
        @objc func pipDidClose(_ controller: NSViewController) {
            calls += 1
            whenClosed?()
        }
    }
    private func drain() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    @Test func duplicateClosesNotifyOnceAfterNativeDismissReturns() async {
        let delivery = SitePiP.CloseDelivery(), controller = Controller(), delegate = Delegate()
        controller.delegate = delegate
        delegate.whenClosed = { [weak controller] in
            #expect(controller.map { delivery.isPending($0) } == true)
        }
        #expect(!delivery.isPending(controller))
        delivery.schedule(controller)
        #expect(delivery.isPending(controller))
        delivery.schedule(controller)
        #expect(delegate.calls == 0)
        await drain()
        #expect(delegate.calls == 1)
        #expect(!delivery.isPending(controller))
    }

    @Test func reopeningInvalidatesTheOldCloseEvenIfClosedAgain() async {
        let delivery = SitePiP.CloseDelivery(), controller = Controller(), delegate = Delegate()
        controller.delegate = delegate
        delivery.schedule(controller)
        delivery.opened(controller)
        delivery.schedule(controller)
        await drain()
        #expect(delegate.calls == 1)
        delivery.schedule(controller)
        delivery.opened(controller)
        await drain()
        #expect(delegate.calls == 1)
    }

    @Test func reentrantAndLateDismissalsCannotCompleteOnePresentationTwice() async {
        let delivery = SitePiP.CloseDelivery(), controller = Controller(), delegate = Delegate()
        controller.delegate = delegate
        delegate.whenClosed = {
            if delegate.calls == 1 { delivery.schedule(controller) }
        }
        delivery.schedule(controller)
        await drain()
        await drain()
        #expect(delegate.calls == 1)
        #expect(!delivery.isPending(controller))
        delivery.schedule(controller)
        await drain()
        #expect(delegate.calls == 1)
        delivery.opened(controller)
        delivery.schedule(controller)
        await drain()
        #expect(delegate.calls == 2)
        delegate.whenClosed = nil
    }

    @Test func ownerOrDelegateTeardownCancelsDelivery() async {
        let delivery = SitePiP.CloseDelivery(), delegate = Delegate()
        var controller: Controller? = Controller()
        controller?.delegate = delegate
        weak var weakController = controller
        delivery.schedule(controller!)
        controller = nil
        #expect(weakController == nil)
        await drain()
        #expect(delegate.calls == 0)
        let next = Controller(), replacement = Delegate()
        next.delegate = delegate
        delivery.schedule(next)
        next.delegate = replacement
        await drain()
        #expect(delegate.calls == 0 && replacement.calls == 0)
    }
}
