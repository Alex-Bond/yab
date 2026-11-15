import Foundation
import Testing
@testable import Fast

@MainActor
struct FloatShapeSafetyTests {
    private func shape(_ width: Double, _ height: Double) -> CGSize? {
        Isolate.shape(["floating", width, height] as [Any])
    }

    @Test func nonfiniteDimensionsAreNotWindowShapes() {
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(shape(value, 1080) == nil)
            #expect(shape(1920, value) == nil)
            #expect(shape(value, value) == nil)
        }
    }

    @Test func finiteDimensionsCannotProduceAnInvalidAspectRatio() {
        #expect(shape(.greatestFiniteMagnitude, .leastNonzeroMagnitude) == nil)
        #expect(shape(.leastNonzeroMagnitude, .greatestFiniteMagnitude) == nil)
    }

    @Test func normalLandscapePortraitAndUnknownSizesArePreserved() {
        #expect(shape(1920, 1080) == CGSize(width: 1920, height: 1080))
        #expect(shape(720, 1280) == CGSize(width: 720, height: 1280))
        #expect(shape(1280, 720) == CGSize(width: 1280, height: 720))
        #expect(shape(0, 1080) == nil)
        #expect(shape(1920, 0) == nil)
        #expect(shape(-1, 1080) == nil)
        #expect(Isolate.shape(nil) == nil)
        #expect(Isolate.shape(["floating", 1920]) == nil)
    }
}
