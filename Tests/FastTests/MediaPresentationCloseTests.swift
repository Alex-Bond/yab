import Foundation
import ObjectiveC
import Testing
@testable import Fast

/// WebKit's `closeAllMediaPresentationsWithCompletionHandler:` on macOS 15
/// and 26 keeps the block it is given without retaining it, and calls it
/// when the last presentation closes, for a video in Picture in Picture a
/// turn or more later (MediaPresentationClose.swift). A stand-in class does
/// the same: it keeps only the block's address.
@MainActor
@Suite(.serialized)
struct MediaPresentationCloseTests {
    final class Sentinel {
        let gone: () -> Void
        init(gone: @escaping () -> Void) { self.gone = gone }
        deinit { gone() }
    }

    final class Seen: @unchecked Sendable { var freed = false, completed = 0 }

    /// A class whose `closeAllMediaPresentationsWithCompletionHandler:`
    /// keeps the block's address only, as WebKit's MRC code does.
    nonisolated(unsafe) static var heldBlock: UnsafeMutableRawPointer?

    static let standIn: AnyClass = {
        let cls: AnyClass = objc_allocateClassPair(NSObject.self, "YabMediaCloseStandIn", 0)!
        let take: @convention(block) (AnyObject, AnyObject?) -> Void = { _, block in
            heldBlock = block.map { Unmanaged.passUnretained($0).toOpaque() }
        }
        class_addMethod(cls, NSSelectorFromString("closeAllMediaPresentationsWithCompletionHandler:"),
                        imp_implementationWithBlock(take), "v@:@?")
        objc_registerClassPair(cls)
        return cls
    }()

    /// Its own frame, so the test holds no reference to the block after.
    @inline(never) static func callHeldBlock(_ raw: UnsafeMutableRawPointer) {
        let block = unsafeBitCast(Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue(),
                                  to: (@convention(block) () -> Void).self)
        block()
    }

    private func turn() async { await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } } }

    /// What crashed: a Swift closure bridged for the call is freed as the
    /// call returns, while WebKit still holds its address.
    @Test func aBridgedClosureIsFreedWhileWebKitHoldsIt() async throws {
        let stand = (Self.standIn as! NSObject.Type).init()
        var freed = false
        autoreleasepool {
            let sentinel = Sentinel { freed = true }
            let bridged: @convention(block) () -> Void = { _ = sentinel }
            _ = stand.perform(NSSelectorFromString("closeAllMediaPresentationsWithCompletionHandler:"), with: bridged as AnyObject)
        }
        await turn()
        #expect(Self.heldBlock != nil)
        #expect(freed, "the bridged block outlived the call; the stand-in no longer models WebKit")
    }

    /// Yab's call: the block WebKit holds stays alive until WebKit calls
    /// it, the caller's completion runs once, and the block is let go.
    @Test func theBlockWebKitHoldsLivesUntilCalled() async throws {
        let stand = (Self.standIn as! NSObject.Type).init()
        let before = MediaPresentationClose.waiting
        let seen = Seen()
        autoreleasepool {
            let sentinel = Sentinel { seen.freed = true }
            MediaPresentationClose.send(stand, then: { withExtendedLifetime(sentinel) { seen.completed += 1 } },
                                        through: Self.standIn)
        }
        for _ in 0..<3 { await turn() }
        #expect(!seen.freed)
        #expect(MediaPresentationClose.waiting == before + 1)
        // As WebKit does from pipDidClose:, long after the call returned.
        Self.callHeldBlock(try #require(Self.heldBlock))
        for _ in 0..<3 { await turn() }
        #expect(seen.completed == 1)
        #expect(MediaPresentationClose.waiting == before)
        #expect(seen.freed)
    }
}
