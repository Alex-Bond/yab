import CoreGraphics
import Testing
@testable import Fast

// Rounded rects for macOS 15 (RoundedPath.swift): its CoreGraphics
// asserts on a corner more than half a side, so the corner given is cut
// to what the rect can hold, never below 0, and a null rect is nothing.
struct RoundedPathTests {
    @Test func cornerFitsTheRect() {
        #expect(CGRect(x: 0, y: 0, width: 100, height: 40).fitting(corner: 10) == 10)
        #expect(CGRect(x: 0, y: 0, width: 100, height: 6).fitting(corner: 10) == 3)
        #expect(CGRect(x: 0, y: 0, width: 4, height: 60).fitting(corner: 10) == 2)
        #expect(CGRect.zero.fitting(corner: 10) == 0)
        #expect(CGRect(x: 0, y: 0, width: 20, height: 20).fitting(corner: -1) == 0)
        #expect(CGRect.null.fitting(corner: 10) == 0)
        #expect(CGRect.infinite.fitting(corner: 10) == 0)
        // Negative sizes are measured as CGRect does, by their magnitude.
        #expect(CGRect(x: 0, y: 0, width: -6, height: 50).fitting(corner: 10) == 3)
    }

    /// Rects that are small, empty or inset past themselves still make a
    /// path; on macOS 15 each of these aborted before.
    @Test func smallRectsMakePaths() {
        let rects: [CGRect] = [
            .zero,
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 3, y: 4, width: 2.86, height: 11),
            CGRect(x: 0, y: 0, width: 10, height: 10).insetBy(dx: 6, dy: 6),
            CGRect(x: 0, y: 0, width: 22, height: 0.5),
        ]
        for rect in rects {
            let path = CGPath.rounded(rect, corner: 8)
            if rect.isNull { #expect(path.isEmpty) } else { #expect(path.boundingBoxOfPath.width <= rect.width + 1e-9) }
            let mutable = CGMutablePath()
            mutable.addRounded(rect, corner: 8)
            #expect(mutable.isEmpty == rect.isNull)
        }
    }

    @Test func roomyRectsKeepTheirCorner() {
        let rect = CGRect(x: 0, y: 0, width: 80, height: 30)
        #expect(CGPath.rounded(rect, corner: 10) == CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
    }
}
