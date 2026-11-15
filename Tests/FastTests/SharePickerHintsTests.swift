import Foundation
import Testing
@testable import Fast

@MainActor struct SharePickerHintsTests {
    private func picker(audio: Bool = false, _ body: [String: Any]) -> SharePicker {
        let picker = SharePicker(token: "t", frame: nil, host: "example.com", audio: audio)
        picker.take(body)
        return picker
    }

    @Test func aNamedSurfaceOpensItsDoor() {
        #expect(picker(["surface": "browser"]).preferred == .tabs)
        #expect(picker(["surface": "window"]).preferred == .windows)
        #expect(picker(["surface": "monitor"]).preferred == .screens)
        #expect(picker(["surface": ""]).preferred == nil)
    }

    @Test func thePageSaysWhatIsOffered() {
        #expect(picker(["own": "include"]).offersCaller)
        #expect(!picker(["own": "exclude"]).offersCaller)
        #expect(!picker([:]).offersCaller)
        let first = picker(["current": true])
        #expect(first.offersCaller && first.callerFirst)
        #expect(!picker(["screens": "exclude"]).kinds.contains(.screens))
    }

    @Test func soundComesAsChromeOffersIt() {
        let asked = picker(audio: true, [:])
        #expect(asked.hears(.tab(UUID())))
        #expect(!asked.hears(.display(1)))
        #expect(!asked.hears(.window(1)))
        #expect(!picker(audio: false, [:]).hears(.tab(UUID())))
    }
}
