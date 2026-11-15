import UIKit
import XCTest
@testable import YabPhone

/// Native menus draw Yab's glyphs where and as large as SF Symbols stand in
/// them (UIImage.menuGlyph).
@MainActor
final class MenuGlyphTests: XCTestCase {
    /// The drawn part of an image, in points, measured in pixels at 3x.
    static func ink(_ image: UIImage) -> CGRect {
        let scale: CGFloat = 3
        let size = image.size
        let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
        guard w > 0, h > 0 else { return .zero }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: scale, y: -scale)
            image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
            UIGraphicsPopContext()
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .zero }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private func describe(_ name: String, _ image: UIImage?) -> String {
        guard let image else { return "\(name): none" }
        let ink = Self.ink(image)
        return String(format: "%@: size %.2fx%.2f baseline %.2f insets t%.2f l%.2f b%.2f r%.2f ink x%.2f y%.2f %.2fx%.2f symbol %@",
                      name, image.size.width, image.size.height, image.baselineOffsetFromBottom ?? -1,
                      image.alignmentRectInsets.top, image.alignmentRectInsets.left, image.alignmentRectInsets.bottom,
                      image.alignmentRectInsets.right, ink.minX, ink.minY, ink.width, ink.height, image.isSymbolImage ? "yes" : "no")
    }

    /// What the system's symbols measure under the configurations a menu
    /// may use, and what ours measure: printed for the log.
    func testMeasureSymbolsAndGlyphs() {
        let configs: [(String, UIImage.SymbolConfiguration)] = [
            ("body", .init(textStyle: .body)),
            ("body-large", .init(textStyle: .body, scale: .large)),
            ("17", .init(pointSize: 17)),
            ("17-large", .init(pointSize: 17, weight: .regular, scale: .large)),
        ]
        var lines: [String] = []
        for (label, config) in configs {
            for name in ["square", "square.on.square", "doc.on.doc", "square.and.arrow.up", "link", "plus.square.on.square",
                         "pencil", "translate", "plus", "xmark", "globe", "trash", "pin", "archivebox"] {
                lines.append(describe("\(label) \(name)", UIImage(systemName: name, withConfiguration: config)))
            }
        }
        for name in ["SquareBehindSquare1", "PlusMedium", "MacPencil", "Translate", "ShareOs", "PageText", "MacPin", "CrossMedium"] {
            lines.append(describe("menuGlyph \(name)", UIImage.menuGlyph(name)))
        }
        let body = UIFont.preferredFont(forTextStyle: .body)
        lines.append(String(format: "body font %.2f cap %.2f x %.2f ascender %.2f descender %.2f",
                            body.pointSize, body.capHeight, body.xHeight, body.ascender, body.descender))
        print("MENU-GLYPH-MEASURE\n" + lines.joined(separator: "\n"))
    }

    /// Copy's two squares ink as large as SF's square.on.square beside them,
    /// the plus as large as SF's plus, each centered on the capitals' middle.
    func testGlyphsInkAsLargeAsTheSymbolsBesideThem() throws {
        let config = UIImage.SymbolConfiguration(textStyle: .body)
        for (ours, theirs, centered) in [("SquareBehindSquare1", "square.on.square", true), ("PlusMedium", "plus", true),
                                         ("ShareOs", "square.and.arrow.up", false)] {
            let glyph = try XCTUnwrap(UIImage.menuGlyph(ours)), symbol = try XCTUnwrap(UIImage(systemName: theirs, withConfiguration: config))
            let a = Self.ink(glyph), b = Self.ink(symbol)
            XCTAssertEqual(a.height, b.height, accuracy: 1.5, "\(ours) inks \(a.height) high, \(theirs) \(b.height)")
            // Both centered on the capitals' middle over the baseline (share's
            // arrow stands its symbol higher; ours keeps the box centered).
            guard centered else { continue }
            let mid = { (image: UIImage) in image.size.height / 2 - (image.baselineOffsetFromBottom ?? 0) }
            XCTAssertEqual(mid(glyph), mid(symbol), accuracy: 1, "\(ours) stands off \(theirs)'s middle")
        }
        XCTAssertEqual(UIImage.menuGlyph("SquareBehindSquare1")?.size.width, UIImage.menuGlyphSide)
    }

    /// Every Mac drawing a menu asks for is in the catalog, drawn at a
    /// symbol's size (Phone/scripts/mac-glyphs.py copies them).
    func testEveryMacGlyphLoads() throws {
        for glyph in MacGlyph.allCases {
            let image = try XCTUnwrap(UIImage.menuGlyph(glyph), glyph.rawValue)
            XCTAssertEqual(image.size.width, UIImage.menuGlyphSide, glyph.rawValue)
            XCTAssertGreaterThan(Self.ink(image).height, 8, "\(glyph.rawValue) draws nothing")
        }
    }

    /// Crash 405: a menu rebuilt over and over drew every glyph again on the
    /// main thread. The same glyph at the same size is drawn once.
    func testMenuGlyphIsDrawnOnce() throws {
        let first = try XCTUnwrap(UIImage.menuGlyph("SquareBehindSquare1"))
        let second = try XCTUnwrap(UIImage.menuGlyph("SquareBehindSquare1"))
        XCTAssertTrue(first === second)
    }
}
