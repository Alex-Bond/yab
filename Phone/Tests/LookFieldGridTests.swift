import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

@MainActor
final class LookFieldGridTests: XCTestCase {
    func testCachedPrintedFieldHasTheExactLegacyPixelsAtDifferentSizesAndTraits() throws {
        let cache = LookFieldGridCache()
        for lightness in [0.55, 0.632718, 0.75] {
            let grid = cache.grid(lightness: lightness, columns: Metrics.SpaceTray.dotColumns, rows: Metrics.SpaceTray.dotRows)
            for size in [CGSize(width: 288, height: 196), CGSize(width: 354, height: 196)] {
                for scheme in [ColorScheme.light, .dark] {
                    let legacy = try picture(lightness: lightness, grid: nil, size: size, scheme: scheme)
                    let cached = try picture(lightness: lightness, grid: grid, size: size, scheme: scheme)
                    let before = try pixels(legacy)
                    let after = try pixels(cached)
                    XCTAssertEqual(after, before, "every printed dot must keep the earlier Canvas pixels")
                    var coloredPixels = 0
                    for offset in stride(from: 0, to: after.count, by: 4) {
                        let red: UInt8 = after[offset]
                        let green: UInt8 = after[offset + 1]
                        let blue: UInt8 = after[offset + 2]
                        if red != green || green != blue { coloredPixels += 1 }
                    }
                    XCTAssertGreaterThan(coloredPixels, 100, "a blank renderer cannot certify the color field")
                    if lightness == 0.632718, size.width == 354 {
                        attach(legacy, name: "Legacy field \(scheme)")
                        attach(cached, name: "Cached field \(scheme)")
                    }
                }
            }
        }
    }

    func testHandleMovementReusesTheGridAndOldSessionsCannotGrowTheCache() {
        let cache = LookFieldGridCache(limit: 3)
        var primary = LookColor(RGB(168, 195, 160))
        let first = cache.grid(lightness: primary.lightness, columns: 18, rows: 9)
        for index in 0..<240 {
            primary.move(to: CGPoint(x: Double(index % 18) / 17, y: Double(index % 9) / 8))
            XCTAssertTrue(cache.grid(lightness: primary.lightness, columns: 18, rows: 9) === first,
                          "a hue or reach drag must not recalculate gamut samples")
        }
        XCTAssertEqual(cache.count, 1)
        let old = cache.grid(lightness: 0.55, columns: 18, rows: 9)
        _ = cache.grid(lightness: 0.60, columns: 18, rows: 9)
        _ = cache.grid(lightness: 0.65, columns: 18, rows: 9)
        XCTAssertTrue(cache.grid(lightness: 0.55, columns: 18, rows: 9) === old, "using a grid retains it in the LRU")
        for index in 0..<30 {
            _ = cache.grid(lightness: 0.56 + Double(index) * 0.006, columns: 18, rows: 9)
            XCTAssertLessThanOrEqual(cache.count, 3)
        }
        let rebuilt = cache.grid(lightness: 0.55, columns: 18, rows: 9)
        XCTAssertFalse(rebuilt === old)
        XCTAssertEqual(rebuilt.samples, old.samples, "eviction must not change a later field")
    }

    private func picture(lightness: Double, grid: LookFieldGrid?, size: CGSize, scheme: ColorScheme) throws -> UIImage {
        let renderer = ImageRenderer(content: PrintedFieldReference(lightness: lightness, grid: grid)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(size)
        return try XCTUnwrap(renderer.uiImage, "the native SwiftUI Canvas must render")
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
            return true
        }
        XCTAssertTrue(drawn)
        return bytes
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The uncached branch is the original printed-dot Canvas, retained only as
/// the rendering reference. It does not call the new grid implementation.
private struct PrintedFieldReference: View {
    let lightness: Double
    let grid: LookFieldGrid?
    var body: some View {
        Canvas { context, size in
            let inset = Metrics.SpaceTray.dot / 2
            let travel = CGSize(width: max(1, size.width - Metrics.SpaceTray.dot), height: max(1, size.height - Metrics.SpaceTray.dot))
            if let grid {
                for sample in grid.samples {
                    let center = CGPoint(x: inset + sample.point.x * travel.width, y: inset + sample.point.y * travel.height)
                    let dot = Metrics.SpaceTray.printedDot
                    context.fill(Path(ellipseIn: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)),
                                 with: .color(Color(rgb: sample.color)))
                }
            } else {
                let light = min(0.75, max(0.55, lightness))
                for row in 0..<Metrics.SpaceTray.dotRows {
                    for column in 0..<Metrics.SpaceTray.dotColumns {
                        let point = CGPoint(x: Double(column) / Double(Metrics.SpaceTray.dotColumns - 1),
                                            y: Double(row) / Double(Metrics.SpaceTray.dotRows - 1))
                        var color = LookColor(lightness: light, reach: 0, hue: 0)
                        color.move(to: point)
                        let center = CGPoint(x: inset + point.x * travel.width, y: inset + point.y * travel.height)
                        let dot = Metrics.SpaceTray.printedDot
                        context.fill(Path(ellipseIn: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)),
                                     with: .color(Color(rgb: color.rgb)))
                    }
                }
            }
        }
    }
}
