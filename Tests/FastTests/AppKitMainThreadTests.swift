import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct AppKitMainThreadTests {
    @Test func notificationsRemainSynchronousAndReentrant() {
        let center = NotificationCenter()
        let name = Notification.Name("AppKitMainThreadTests")
        var order: [Int] = []
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            AppKitMainThread.sync {
                order.append(1)
                AppKitMainThread.sync { order.append(2) }
            }
        }
        defer { center.removeObserver(observer) }
        center.post(name: name, object: nil)
        order.append(3)
        #expect(order == [1, 2, 3])
    }

    @Test func timerFromTheMainRunLoopUsesTheSameSynchronousBoundary() {
        var heard = false
        let timer = Timer(timeInterval: 1, repeats: false) { _ in
            AppKitMainThread.sync { heard = Thread.isMainThread }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        timer.fire()
        #expect(heard)
    }

    @Test func eventResultAndThrownErrorsArePreserved() throws {
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        let returned = AppKitMainThread.sync { event }
        #expect(returned === event)
        enum Failure: Error { case expected }
        #expect(throws: Failure.expected) {
            try AppKitMainThread.sync { throw Failure.expected }
        }
    }
}
