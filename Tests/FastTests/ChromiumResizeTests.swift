import Foundation
import Testing
import YabCoreClient
@testable import Fast

struct ChromiumResizeTests {
    private func surface(_ width: Double = 800, _ height: Double = 600, context: Double = 7) -> [String: JSONValue] {
        ["contextId": .number(context), "width": .number(width), "height": .number(height), "source": .string("cefCallback")]
    }

    @Test func holdsTheCommittedHostUntilTheMatchingFrameArrives() {
        var state = ChromiumResize()
        state.surface(surface())
        let geometry = ChromiumResize.Geometry(size: CGSize(width: 1000, height: 700), scale: 2, visible: true)
        let token = state.request(geometry)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        #expect(state.frame(in: bounds) == CGRect(x: 0, y: 100, width: 800, height: 600))
        state.surface(surface(1000, 700))
        #expect(state.committed == CGSize(width: 800, height: 600))
        var ack = surface(1000, 700)
        ack["serial"] = .string(token)
        let accepted = state.receive(ack)
        #expect(accepted)
        #expect(state.frame(in: bounds) == bounds)
        #expect(state.acknowledged == token)
        #expect(state.serial == nil)
        let duplicate = state.receive(ack)
        #expect(!duplicate)
    }

    @Test func ignoresSupersededWrongContextAndWrongSizeReceipts() {
        var state = ChromiumResize()
        state.surface(surface())
        let first = state.request(.init(size: CGSize(width: 900, height: 650), scale: 1, visible: true))
        let latest = state.request(.init(size: CGSize(width: 700, height: 500), scale: 1, visible: true))
        var ack = surface(900, 650)
        ack["serial"] = .string(first)
        let stale = state.receive(ack)
        #expect(!stale)
        ack["serial"] = .string(latest)
        let wrongSize = state.receive(ack)
        #expect(!wrongSize)
        ack = surface(700, 500, context: 9)
        ack["serial"] = .string(latest)
        let wrongContext = state.receive(ack)
        #expect(!wrongContext)
        state.surface(surface(700, 500, context: 9))
        let accepted = state.receive(ack)
        #expect(accepted)
        #expect(state.committed == CGSize(width: 700, height: 500))
    }

    @Test func fallsBackForOfficialSDKAndInvalidatesLostContexts() {
        var state = ChromiumResize()
        state.surface(surface())
        let token = state.request(.init(size: CGSize(width: 900.2, height: 650.2), scale: 2, visible: false))
        #expect(state.requested?.size == CGSize(width: 901, height: 651))
        state.unsupported(token)
        let bounds = CGRect(x: 0, y: 0, width: 900.2, height: 650.2)
        #expect(state.frame(in: bounds) == bounds)
        state.surface(surface())
        state.surface(surface(context: 0))
        #expect(state.committed == nil)
        #expect(!state.native)
        #expect(state.serial == nil)
        #expect(state.acknowledged == nil)
    }
}
