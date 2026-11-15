import Foundation
import Testing
import YabCoreClient
@testable import Fast

struct ChromiumResizeTests {
    @Test func sidebarWidthsDoNotReplayVisibilityButOcclusionAndDetachDo() {
        var previous: ChromiumResize.Geometry?
        var visibilityChanges = 0
        // Initial presentation, then the intermediate widths of 20 toggles.
        for toggle in 0..<20 {
            for index in 0...20 {
                let width = toggle.isMultiple(of: 2) ? 800 + index * 12 : 1040 - index * 12
                let next = ChromiumResize.Geometry(size: CGSize(width: width, height: 700), scale: 2, visible: true)
                if next.changesVisibility(from: previous) { visibilityChanges += 1 }
                previous = next
            }
        }
        #expect(visibilityChanges == 1, "Only initial presentation shows the page; resizing does not restore it")
        let covered = ChromiumResize.Geometry(size: CGSize(width: 800, height: 700), scale: 2, visible: true, covered: true)
        #expect(covered.changesVisibility(from: previous))
        #expect(!covered.changesVisibility(from: covered))
        let hidden = ChromiumResize.Geometry(size: covered.size, scale: 2, visible: false, covered: true)
        #expect(hidden.changesVisibility(from: covered), "Dropping keep must detach even when already covered")
        let shown = ChromiumResize.Geometry(size: hidden.size, scale: 2, visible: true)
        #expect(shown.changesVisibility(from: hidden))
        #expect(shown.changesVisibility(from: covered))
        let retina = ChromiumResize.Geometry(size: shown.size, scale: 1, visible: true)
        #expect(!retina.changesVisibility(from: shown), "A display scale change is geometry too")
    }

    private func surface(_ width: Double = 800, _ height: Double = 600, context: Double = 7) -> [String: JSONValue] {
        ["contextId": .number(context), "width": .number(width), "height": .number(height), "source": .string("cefCallback")]
    }

    @Test func bootstrapSurfaceWaitsForTheFirstRequestedViewport() {
        var state = ChromiumResize()
        state.surface(surface(800, 600))
        #expect(!state.canPresent)
        let token = state.request(.init(size: CGSize(width: 1440, height: 900), scale: 2, visible: true))
        state.surface(surface(1440, 900))
        #expect(!state.canPresent)
        var ack = surface(1440, 900)
        ack["serial"] = .string(token)
        let accepted = state.receive(ack)
        #expect(accepted)
        #expect(state.canPresent)
        _ = state.request(.init(size: CGSize(width: 1200, height: 800), scale: 2, visible: true))
        #expect(state.canPresent)
    }

    @Test func bootstrapAcknowledgementSurvivesAnEmptySurface() {
        var state = ChromiumResize()
        let token = state.request(.init(size: CGSize(width: 1000, height: 700), scale: 2, visible: true))
        state.surface(surface(context: 0))
        #expect(state.serial == token)
        state.surface(surface(1000, 700, context: 9))
        #expect(!state.canPresent)
        var ack = surface(1000, 700, context: 9)
        ack["serial"] = .string(token)
        let accepted = state.receive(ack)
        #expect(accepted)
        #expect(state.canPresent)
    }

    @Test func returningSurfaceDoesNotWaitForAnUnrequestedResize() {
        var state = ChromiumResize()
        state.surface(surface())
        let token = state.request(.init(size: CGSize(width: 1000, height: 700), scale: 2, visible: true))
        var ack = surface(1000, 700)
        ack["serial"] = .string(token)
        let accepted = state.receive(ack)
        #expect(accepted)
        state.surface(surface(context: 0))
        #expect(state.acknowledged == nil)
        state.surface(surface(1000, 700, context: 9))
        #expect(state.serial == nil)
        #expect(state.canPresent, "Showing the same viewport does not send another resize")
        state = ChromiumResize()
        state.surface(surface())
        #expect(!state.canPresent, "A new page still waits for its first viewport")
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
        #expect(state.acknowledged == latest)
        let receiptAccepted1 = state.receive(ack)
        #expect(!receiptAccepted1, "The held ACK is consumed once at context binding")
        #expect(state.committed == CGSize(width: 700, height: 500))
    }

    @Test(arguments: [false, true]) func acknowledgementBeforeItsContextIsNotLost(_ replacing: Bool) {
        var state = ChromiumResize()
        if replacing { state.surface(surface(context: 7)) }
        let token = state.request(.init(size: CGSize(width: 1000, height: 700), scale: 2, visible: true))
        var ack = surface(1000, 700, context: 9)
        ack["serial"] = .string(token)
        let receiptAccepted2 = state.receive(ack)
        #expect(!receiptAccepted2)
        #expect(state.serial == token)
        state.surface(surface(1000, 700, context: 9))
        #expect(state.serial == nil)
        #expect(state.acknowledged == token)
        #expect(state.canPresent)
        #expect(state.committed == CGSize(width: 1000, height: 700))
    }

    @Test func aNewRequestRetiresAnEarlyAcknowledgement() {
        var state = ChromiumResize()
        let old = state.request(.init(size: CGSize(width: 1000, height: 700), scale: 2, visible: true))
        var ack = surface(1000, 700, context: 9); ack["serial"] = .string(old)
        let receiptAccepted3 = state.receive(ack)
        #expect(!receiptAccepted3)
        let current = state.request(.init(size: CGSize(width: 1000, height: 700), scale: 2, visible: true))
        state.surface(surface(1000, 700, context: 9))
        #expect(state.serial == current)
        #expect(!state.canPresent)
    }

    #if !ALPHA_BASELINE
    @Test func aReplacementContextNeedsItsOwnGeometryAcknowledgement() {
        var state = ChromiumResize()
        state.surface(surface(context: 7))
        let geometry = ChromiumResize.Geometry(size: CGSize(width: 1000, height: 700), scale: 2, visible: true)
        let token = state.request(geometry)
        var ack = surface(1000, 700, context: 7); ack["serial"] = .string(token)
        let receiptAccepted4 = state.receive(ack)
        #expect(receiptAccepted4)
        #expect(!state.needsContextAcknowledgement)
        state.surface(surface(1000, 700, context: 9))
        #expect(state.needsContextAcknowledgement, "Unchanged window geometry cannot acknowledge a new compositor")
        let replacement = state.request(geometry)
        ack["serial"] = .string(replacement); ack["contextId"] = .number(9)
        let receiptAccepted5 = state.receive(ack)
        #expect(receiptAccepted5)
        #expect(!state.needsContextAcknowledgement)
    }
    #endif

    @Test func fallsBackForOfficialSDKAndInvalidatesLostContexts() {
        var state = ChromiumResize()
        state.surface(surface())
        let token = state.request(.init(size: CGSize(width: 900.2, height: 650.2), scale: 2, visible: false))
        #expect(state.requested?.size == CGSize(width: 901, height: 651))
        state.unsupported(token)
        #expect(state.canPresent)
        let bounds = CGRect(x: 0, y: 0, width: 900.2, height: 650.2)
        #expect(state.frame(in: bounds) == bounds)
        state.surface(surface())
        #expect(state.canPresent, "An unsupported receipt stays optional on later native frames")
        state.surface(surface(context: 0))
        #expect(state.committed == nil)
        #expect(!state.native)
        #expect(state.serial == nil)
        #expect(state.acknowledged == nil)
        #expect(state.canPresent)
    }
}
