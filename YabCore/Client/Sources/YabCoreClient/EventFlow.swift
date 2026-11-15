import Foundation

/// The client's half of event flow control. The helper sends events only
/// within the credit this window grants, and gets each one's credit back once
/// the application's consumer has taken it and asked for the next: so what
/// waits here is bounded by the window, however long the consumer is busy,
/// and nothing is dropped. What does not fit waits in the helper, where
/// latest-state events coalesce (YabCore/src/transport.h). Replies never
/// spend credit, so a request finishes while events wait.
final class EventFlow: @unchecked Sendable {
    struct Window: Sendable, Equatable { let bytes: Int; let count: Int }
    static let window = Window(bytes: 2 * 1024 * 1024, count: 512)
    let window: Window
    private let lock = NSLock()
    private var items: [(event: YabCoreEvent, bytes: Int)] = []
    private var head = 0
    private var bytes = 0
    private var waiter: CheckedContinuation<YabCoreEvent?, Never>?
    private var handed: Int?
    private var returnBytes = 0, returnCount = 0
    private var finished = false
    private var credit: (@Sendable (Int, Int) -> Void)?

    init(window: Window = EventFlow.window) { self.window = window }

    /// Where returned credit goes, once the helper agreed to flow control.
    func start(_ credit: @escaping @Sendable (Int, Int) -> Void) {
        lock.lock()
        self.credit = credit
        // What was taken before the helper's answer goes back now.
        let send = settle(caughtUp: true)
        lock.unlock()
        send?()
    }

    /// One event read from the wire, `size` its frame with the newline. False:
    /// the helper sent past its credit, a protocol violation.
    func append(_ event: YabCoreEvent, size: Int) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return true }
        if let waiter {
            self.waiter = nil; handed = size; lock.unlock()
            waiter.resume(returning: event); return true
        }
        items.append((event, size)); bytes += size
        let held = items.count - head
        // One event larger than the window may come once nothing else is out.
        let fits = held <= window.count && (bytes <= window.bytes || held == 1)
        lock.unlock()
        return fits
    }

    /// The consumer's next event. Asking for it says the previous one was
    /// handled, so its credit goes back; batched to a quarter window, and
    /// all of it whenever the consumer has caught up.
    func next() async -> YabCoreEvent? {
        await withCheckedContinuation { take($0) }
    }

    private func take(_ continuation: CheckedContinuation<YabCoreEvent?, Never>) {
        lock.lock()
        if let size = handed { handed = nil; returnBytes += size; returnCount += 1 }
        var event: YabCoreEvent?, parked = false
        if head < items.count {
            let item = items[head]; head += 1; bytes -= item.bytes
            if head > 64 && head * 2 > items.count { items.removeFirst(head); head = 0 }
            handed = item.bytes; event = item.event
        } else if !finished {
            precondition(waiter == nil, "EventFlow has one consumer")
            waiter = continuation; parked = true
        }
        let send = settle(caughtUp: head == items.count)
        lock.unlock()
        send?()
        if !parked { continuation.resume(returning: event) }
    }

    private func settle(caughtUp: Bool) -> (() -> Void)? {
        guard returnCount > 0, let credit,
              caughtUp || returnCount * 4 >= window.count || returnBytes * 4 >= window.bytes else { return nil }
        let bytes = returnBytes, count = returnCount
        returnBytes = 0; returnCount = 0
        return { credit(bytes, count) }
    }

    func finish() {
        lock.lock()
        finished = true
        items.removeAll(); head = 0; bytes = 0
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    var snapshot: (count: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (items.count - head, bytes)
    }
}
