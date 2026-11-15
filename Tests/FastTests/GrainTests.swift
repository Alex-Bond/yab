import Foundation
import Testing
@testable import Fast

// Grain as an amount: the slider's detents, and spaces written before it had
// one read as they were worn, and written so those builds still read them.
struct GrainTests {
    @Test func aSlideTicksOnlyAcrossAFifth() {
        #expect(!Detents.crossed(0.05, 0.15, every: 0.2))
        #expect(Detents.crossed(0.15, 0.25, every: 0.2))
        #expect(Detents.crossed(0.9, 0.1, every: 0.2))
        #expect(!Detents.crossed(0.3, 0.3, every: 0.2))
    }

    @Test func oldPaintReadsAsTheStandard() throws {
        let on = try JSONDecoder().decode(SpacePaint.self, from: Data(#"{"swatch":"sage","color":"12E4A0","grain":true}"#.utf8))
        #expect(on.grain == Grain.standard)
        let off = try JSONDecoder().decode(SpacePaint.self, from: Data(#"{"swatch":"sage","color":"12E4A0","grain":false}"#.utf8))
        #expect(off.grain == 0)
    }

    @Test func newPaintKeepsOnOrOffForOldBuilds() throws {
        var paint = try JSONDecoder().decode(SpacePaint.self, from: Data(#"{"swatch":"sage","color":"12E4A0","grain":false}"#.utf8))
        paint.grain = 0.6
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(paint)) as? [String: Any])
        #expect(json["grain"] as? Bool == true)
        #expect(json["grainAmount"] as? Double == 0.6)
        #expect(try JSONDecoder().decode(SpacePaint.self, from: JSONEncoder().encode(paint)).grain == 0.6)
    }

    @Test func theStandardIsTheOldOpacity() {
        #expect(abs(Grain.opacity(Grain.standard) - 0.07) < 1e-9)
        #expect(Grain.opacity(2) == 0.2)
    }
}
