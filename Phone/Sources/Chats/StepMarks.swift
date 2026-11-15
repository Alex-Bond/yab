import SwiftUI
import UIKit
#if canImport(SyncKit)
import SyncKit
#endif

// A step's mark, as the Mac draws it at rest (its StepMarks.swift): one
// small drawing for each kind of work, on Central's 24-point grid in a 2 pt
// stroke with round caps. The Mac moves a mark while its step runs; here
// only finished turns show their steps, so each mark is its resting frame
// (a tick or a failure as written), drawn once into a template image.

// The marks themselves are SyncKit's (StepArt), the Mac's too.
extension StepArt {
    /// One stroke of the mark on the 24-point grid.
    struct Stroke {
        var path: CGPath
        /// Filled rather than stroked: the face's eyes.
        var fill = false
        /// A square cap, as a few of Central's shapes have.
        var square = false
    }

    /// The Mac's frame where the mark rests: the start of its gesture, a
    /// tick or a cross written out.
    var strokes: [Stroke] {
        typealias P = StepPaths
        func svg(_ d: String) -> CGPath { P.parse(d) }
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Stroke {
            let path = CGMutablePath()
            path.move(to: pt(x1, y1)); path.addLine(to: pt(x2, y2))
            return Stroke(path: path)
        }
        func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
        }
        func polyline(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points)
            return path
        }
        let circle = "M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z"
        switch self {
        case .search:
            return [Stroke(path: ellipse(11, 11, 7, 7)), Stroke(path: svg("M20 20L16.05 16.05"))]
        case .history:
            return [Stroke(path: svg("M3 5V9H7")),
                    Stroke(path: svg("M3.51172 15C4.74723 18.4956 8.08094 21 11.9996 21C16.9702 21 20.9996 16.9706 20.9996 12C20.9996 7.02944 16.9702 3 11.9996 3C8.27045 3 5.07102 5.26806 3.70551 8.5")),
                    Stroke(path: svg("M12 12L15 15")), Stroke(path: svg("M12 12V8"))]
        case .edit:
            return [Stroke(path: svg("M11 4H7.2C6.0799 4 5.51984 4 5.09202 4.21799C4.71569 4.40973 4.40973 4.71569 4.21799 5.09202C4 5.51984 4 6.0799 4 7.2V16.8C4 17.9201 4 18.4802 4.21799 18.908C4.40973 19.2843 4.71569 19.5903 5.09202 19.782C5.51984 20 6.0799 20 7.2 20H16.8C17.9201 20 18.4802 20 18.908 19.782C19.2843 19.5903 19.5903 19.2843 19.782 18.908C20 18.4802 20 17.9201 20 16.8V13")),
                    Stroke(path: svg("M9 14.9999V12.4142C9 12.1489 9.10536 11.8946 9.29289 11.707L17.3358 3.66416C18.1168 2.88311 19.3832 2.88311 20.1642 3.66416L20.3358 3.83573C21.1168 4.61678 21.1168 5.88311 20.3358 6.66416L12.2929 14.707C12.1054 14.8946 11.851 14.9999 11.5858 14.9999H9Z"), square: true)]
        case .type:
            return ([4, 12, 20] as [CGFloat]).map { Stroke(path: ellipse($0, 12, 1, 1)) }
        case .skill:
            func book(_ x0: CGFloat, _ x1: CGFloat) -> CGPath {
                CGPath(roundedRect: CGRect(x: x0, y: 4, width: x1 - x0, height: 16), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil)
            }
            return [Stroke(path: book(2.66, 8.16)), Stroke(path: book(8.16, 13.67)),
                    Stroke(path: P.moved(book(15.17, 20.67), P.turn(-10, 17.92, 12)))]
        case .mcp:
            let cord = CGMutablePath()
            cord.move(to: pt(14.5, 14.5)); cord.addLine(to: pt(15, 15))
            cord.addCurve(to: pt(21, 12), control1: pt(18, 18), control2: pt(21, 15.5))
            cord.addPath(svg("M21 12C21 7.02944 16.9706 3 12 3C7.02944 3 3 7.02944 3 12C3 16.9706 7.02944 21 12 21C12.6874 21 13.3568 20.9229 14 20.777"))
            return [Stroke(path: cord),
                    Stroke(path: svg("M13 8L8 13L10.5858 15.5858C11.3668 16.3668 12.6332 16.3668 13.4142 15.5858L15.5858 13.4142C16.3668 12.6332 16.3668 11.3668 15.5858 10.5858L13 8Z")),
                    Stroke(path: svg("M9 12L7.5 10.5M12 9L10.5 7.5"))]
        case .folder:
            return [Stroke(path: P.rounded([pt(21, 11), pt(21, 7), pt(12.5, 7), pt(10.5, 4), pt(3, 4), pt(3, 19), pt(4.6, 19)], [0, 2, 1, 1, 2, 2, 0], closed: false)),
                    Stroke(path: P.rounded([pt(3, 11), pt(21, 11), pt(21, 19), pt(3, 19)], [0.6, 0.6, 2, 2], closed: true))]
        case .readFile:
            return [Stroke(path: P.rounded([pt(12, 19.2), pt(20, 17.6), pt(20, 4.6), pt(12, 6.2)], [0, 1.8, 1.8, 0], closed: false)),
                    Stroke(path: P.rounded([pt(12, 19.2), pt(4, 17.6), pt(4, 4.6), pt(12, 6.2)], [0, 1.8, 1.8, 0], closed: false)),
                    Stroke(path: svg("M12 6.2V19.2"))]
        case .command:
            return [Stroke(path: svg("M5 7L9.29289 11.2929C9.68342 11.6834 9.68342 12.3166 9.29289 12.7071L5 17")), Stroke(path: svg("M13 17H19"))]
        case .wait:
            return [Stroke(path: svg("M12 12L6.8906 8.59373C6.3342 8.2228 6 7.59834 6 6.92963V3H18V6.92963C18 7.59834 17.6658 8.2228 17.1094 8.59373L12 12ZM12 12L17.1094 15.4063C17.6658 15.7772 18 16.4017 18 17.0704V21H6V17.0704C6 16.4017 6.3342 15.7772 6.8906 15.4063L12 12ZM20 21H4M20 3H4"))]
        case .readPage:
            return [Stroke(path: svg("M5 5C5 3.89543 5.89543 3 7 3H17C18.1046 3 19 3.89543 19 5V19C19 20.1046 18.1046 21 17 21H7C5.89543 21 5 20.1046 5 19V5Z")),
                    line(9, 7, 15, 7), line(9, 11, 15, 11), line(9, 15, 11, 15)]
        case .pdf:
            return [Stroke(path: svg("M12.1716 3H7C5.89543 3 5 3.89543 5 5V19C5 20.1046 5.89543 21 7 21H17C18.1046 21 19 20.1046 19 19V9.82843C19 9.29799 18.7893 8.78929 18.4142 8.41421L13.5858 3.58579C13.2107 3.21071 12.702 3 12.1716 3Z")),
                    Stroke(path: svg("M13 3.5V7C13 8.10457 13.8954 9 15 9H18.5")), line(9, 13, 12, 13), line(9, 17, 15.5, 17)]
        case .open:
            return [Stroke(path: svg(circle)), Stroke(path: svg("M21 12H3")), Stroke(path: ellipse(12, 12, 3.5, 9))]
        case .click:
            let rays: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(11, 4.5, 11, 3), (15.5962, 6.40392, 16.6569, 5.34326), (6.40381, 15.5962, 5.34315, 16.6569),
                                                               (4.5, 11, 3, 11), (6.40381, 6.40381, 5.34315, 5.34315)]
            return [Stroke(path: svg("M14.1365 20.8008L10.4008 11.0466C10.2461 10.6426 10.6426 10.2461 11.0466 10.4008L20.8008 14.1365C21.1883 14.2849 21.2368 14.8136 20.8827 15.03L17.353 17.1871C17.2853 17.2284 17.2284 17.2853 17.1871 17.353L15.03 20.8827C14.8136 21.2368 14.2849 21.1883 14.1365 20.8008Z"))]
                + rays.map { line($0.0, $0.1, $0.2, $0.3) }
        case .point:
            return [Stroke(path: svg("M3.68921 4.96392L9.08016 20.3265C9.38205 21.1868 10.5835 21.2274 10.9428 20.3895L13.6203 14.1453C13.7214 13.9094 13.9094 13.7214 14.1453 13.6203L20.3895 10.9428C21.2274 10.5835 21.1868 9.38205 20.3265 9.08016L4.96392 3.68921C4.17261 3.41153 3.41153 4.17261 3.68921 4.96392Z"))]
        case .scroll:
            return [Stroke(path: svg("M12 17C9.23858 17 7 14.7614 7 12V7C7 4.23858 9.23858 2 12 2C14.7614 2 17 4.23858 17 7V12C17 14.7614 14.7614 17 12 17Z")),
                    line(12, 6, 12, 8), Stroke(path: svg("M15 20L13.1094 21.2604C12.4376 21.7083 11.5624 21.7083 10.8906 21.2604L9 20"))]
        case .shot:
            return ["M3 7V7C3 5.89543 3.89543 5 5 5V5", "M19 5V5C20.1046 5 21 5.89543 21 7V7", "M5 19V19C3.89543 19 3 18.1046 3 17V17",
                    "M14 5H15", "M9 5H10", "M10 19H9", "M3 13V11"].map { Stroke(path: svg($0)) }
                + [Stroke(path: ellipse(18.5, 15.5, 4.5, 4.5)), Stroke(path: ellipse(18.5, 15.5, 1.5, 1.5))]
        case .mail:
            return [Stroke(path: CGPath(roundedRect: CGRect(x: 3, y: 5, width: 18, height: 14), cornerWidth: 2, cornerHeight: 2, transform: nil)),
                    Stroke(path: P.rounded([pt(3.8, 7), pt(12, 12.6), pt(20.2, 7)], [0, 1.2, 0], closed: false))]
        case .send:
            return [Stroke(path: svg("M9.61946 10.8613L20.9997 4.55422M9.04735 10.9043L4.10061 5.68812C3.49632 5.05091 3.94803 4 4.82621 4H20.2513C21.0247 4 21.5054 4.84039 21.1132 5.50702L13.1902 18.9762C12.7433 19.7358 11.6035 19.5879 11.3654 18.7393L9.28458 11.3223C9.24066 11.1658 9.15923 11.0223 9.04735 10.9043Z"))]
        case .hand:
            return [Stroke(path: svg("M17.0016 7.5C17.0016 6.67157 17.6732 6 18.5016 6C19.33 6 20.0016 6.67157 20.0016 7.5V13.8292C20.0016 17.7895 16.7911 21 12.8308 21C10.1685 21 7.72528 19.525 6.48529 17.169L3.8065 12.0793C3.62131 11.7274 3.66217 11.2993 3.91055 10.9888L4.25222 10.5617C4.94224 9.69921 6.20083 9.55937 7.06335 10.2494L8.00161 11V5.5C8.00161 4.67157 8.67319 4 9.50161 4C10.33 4 11.0016 4.67157 11.0016 5.5M17.0016 7.5V5.5C17.0016 4.67157 16.33 4 15.5016 4C14.6732 4 14.0016 4.67157 14.0016 5.5M17.0016 7.5V12M11.0016 5.5V4.5C11.0016 3.67157 11.6732 3 12.5016 3C13.33 3 14.0016 3.67157 14.0016 4.5V5.5M11.0016 5.5V11M14.0016 5.5V11.5"))]
        case .key:
            return [Stroke(path: svg("M15.4 8.5H15.5H15.6M16 8.5C16 8.77614 15.7761 9 15.5 9C15.2239 9 15 8.77614 15 8.5C15 8.22386 15.2239 8 15.5 8C15.7761 8 16 8.22386 16 8.5Z")),
                    Stroke(path: svg("M15.5 14C18.5376 14 21 11.5376 21 8.5C21 5.46243 18.5376 3 15.5 3C12.4624 3 10 5.46243 10 8.5C10 8.96094 10.0567 9.40863 10.1635 9.83649L4.58579 15.4142C4.21071 15.7893 4 16.298 4 16.8284V19C4 19.5523 4.44772 20 5 20H7.17157C7.70201 20 8.21071 19.7893 8.58579 19.4142L10 18V15.5H12.5L14.1635 13.8365C14.5914 13.9433 15.0391 14 15.5 14Z"), square: true)]
        case .eye:
            let lid = CGMutablePath()
            lid.move(to: pt(2.50257, 11.0947))
            lid.addCurve(to: pt(21.4974, 11.0946), control1: pt(7.33998, 2.97), control2: pt(16.66, 2.97))
            lid.addCurve(to: pt(21.4974, 12.9053), control1: pt(21.8293, 11.6521), control2: pt(21.8293, 12.3477))
            lid.addCurve(to: pt(2.50257, 12.9054), control1: pt(16.66, 21.03), control2: pt(7.33998, 21.03))
            lid.addCurve(to: pt(2.50257, 11.0947), control1: pt(2.17069, 12.3479), control2: pt(2.17069, 11.6523))
            lid.closeSubpath()
            return [Stroke(path: lid), Stroke(path: ellipse(12, 12, 3, 3))]
        case .robot:
            return [Stroke(path: svg("M12 5V3M3.5 9C2.94772 9 2.5 9.44772 2.5 10C2.5 10.5523 2.94772 11 3.5 11M20.5 9C21.0523 9 21.5 9.44772 21.5 10C21.5 10.5523 21.0523 11 20.5 11M10 14.5H14M3.5 16V7C3.5 5.89543 4.39543 5 5.5 5H18.5C19.6046 5 20.5 5.89543 20.5 7V16C20.5 17.6569 19.1569 19 17.5 19H6.5C4.84315 19 3.5 17.6569 3.5 16Z")),
                    Stroke(path: ellipse(8.5, 10, 0.5, 0.5)), Stroke(path: ellipse(15.5, 10, 0.5, 0.5))]
        case .memory:
            return StepArt.brain.map { Stroke(path: svg($0)) }
        case .download:
            let arrow = CGMutablePath()
            arrow.addPath(svg("M3 5H7C9.76142 5 12 7.23858 12 10V15"))
            arrow.move(to: pt(12, 15)); arrow.addLine(to: pt(15.75, 11.25))
            arrow.move(to: pt(12, 15)); arrow.addLine(to: pt(8.25, 11.25))
            return [Stroke(path: svg("M3 9V17C3 18.1046 3.89543 19 5 19H19C20.1046 19 21 18.1046 21 17V7C21 5.89543 20.1046 5 19 5H16")), Stroke(path: arrow)]
        case .upload:
            let arrow = CGMutablePath()
            arrow.move(to: pt(12, 19)); arrow.addLine(to: pt(12, 12))
            arrow.move(to: pt(12, 12)); arrow.addLine(to: pt(14.5, 14.5))
            arrow.move(to: pt(12, 12)); arrow.addLine(to: pt(9.5, 14.5))
            return [Stroke(path: svg("M8 19H7C4.23858 19 2 16.7614 2 14C2 11.4673 3.88316 9.37436 6.32568 9.04508C7.13649 6.69118 9.37075 5 12 5C15.3137 5 18 7.68629 18 11C20.2091 11 22 12.7909 22 15C22 17.2091 20.2091 19 18 19H16")), Stroke(path: arrow)]
        case .code:
            return [Stroke(path: svg("M17 8L20.2929 11.2929C20.6834 11.6834 20.6834 12.3166 20.2929 12.7071L17 16")),
                    Stroke(path: svg("M7 16L3.70711 12.7071C3.31658 12.3166 3.31658 11.6834 3.70711 11.2929L7 8"))]
        case .fill:
            return [Stroke(path: svg("M9 21H7C5.89543 21 5 20.1046 5 19V5C5 3.89543 5.89543 3 7 3H17C18.1046 3 19 3.89543 19 5V10")),
                    Stroke(path: polyline([pt(13.5, 19), pt(15.5, 21), pt(20.5, 15)]))]
        case .plan:
            return [Stroke(path: svg("M13 16H20M13 8H20")),
                    Stroke(path: polyline([pt(4, 9), pt(5.5, 10), pt(8.5, 6)])), Stroke(path: polyline([pt(4, 17), pt(5.5, 18), pt(8.5, 14)]))]
        case .dialog:
            return [Stroke(path: svg("M12 21C16.9706 21 21 16.9706 21 12C21 7.02944 16.9706 3 12 3C7.02944 3 3 7.02944 3 12C3 13.3544 3.29919 14.639 3.83508 15.7911C3.93688 16.01 3.96848 16.2564 3.91125 16.4909L3.1326 19.682C2.95662 20.4032 3.60019 21.058 4.32437 20.8945L7.65314 20.1428C7.8775 20.0921 8.11161 20.1223 8.32149 20.2164C9.44452 20.7199 10.6895 21 12 21Z"))]
        case .close:
            return [Stroke(path: svg("M19 5H5C3.89543 5 3 5.89543 3 7V17C3 18.1046 3.89543 19 5 19H19C20.1046 19 21 18.1046 21 17V7C21 5.89543 20.1046 5 19 5Z")),
                    line(6.5, 8.5, 10.5, 8.5), Stroke(path: svg("M17 8.5H17.5M13.5 8.5H14"))]
        case .think:
            func eye(_ x: CGFloat) -> CGPath { CGPath(roundedRect: CGRect(x: x, y: 8.75, width: 2, height: 4.5), cornerWidth: 1, cornerHeight: 1, transform: nil) }
            return [Stroke(path: ellipse(12, 12, 9, 9)), Stroke(path: eye(8.5), fill: true), Stroke(path: eye(13.5), fill: true)]
        case .done:
            return [Stroke(path: polyline([pt(5, 12.75), pt(10, 19), pt(19, 5)]))]
        case .fail:
            return [Stroke(path: svg(circle)), line(15, 9, 9, 15), line(9, 9, 15, 15)]
        }
    }

    /// Central's brain, fold by fold.
    static let brain = [
        "M4.33682 11.0002C4.12085 10.5456 4 10.037 4 9.5002C4 7.73696 5.30385 6.27826 7 6.03564",
        "M19.6632 11.0002C19.8792 10.5456 20 10.037 20 9.5002C20 7.73696 18.6961 6.27826 17 6.03564",
        "M7 16.8295C6.68722 16.94 6.35064 17.0002 6 17.0002C4.34315 17.0002 3 15.657 3 14.0002C3 12.694 3.83481 11.5827 5 11.1709",
        "M17 16.8295C17.3128 16.94 17.6494 17.0002 18 17.0002C19.6569 17.0002 21 15.657 21 14.0002C21 12.694 20.1652 11.5827 19 11.1709",
        "M12 5.5C12 4.11929 10.8807 3 9.5 3C8.11929 3 7 4.11929 7 5.5C7 6.06291 7.18604 6.58237 7.5 7.00024",
        "M12 5.5C12 4.11929 13.1193 3 14.5 3C15.8807 3 17 4.11929 17 5.5C17 6.06291 16.814 6.58237 16.5 7.00024",
        "M12 5.5V17.5",
        "M12 17.5C12 19.433 10.433 21 8.5 21C6.567 21 5 19.433 5 17.5",
        "M19 17.5C19 19.433 17.433 21 15.5 21C13.567 21 12 19.433 12 17.5",
    ]

    /// The mark drawn once, black on clear, to be tinted where it stands.
    @MainActor var image: UIImage {
        if let hit = StepArt.images[self] { return hit }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { output in
            let context = output.cgContext
            context.setStrokeColor(UIColor.black.cgColor)
            context.setFillColor(UIColor.black.cgColor)
            context.setLineWidth(2)
            context.setLineJoin(.round)
            for stroke in strokes {
                context.addPath(stroke.path)
                if stroke.fill {
                    context.fillPath()
                } else {
                    context.setLineCap(stroke.square ? .square : .round)
                    context.strokePath()
                }
            }
        }.withRenderingMode(.alwaysTemplate)
        StepArt.images[self] = image
        return image
    }

    @MainActor private static var images: [StepArt: UIImage] = [:]
}

/// Path data as the icons' SVGs have it (M L H V C Z, either case), and the
/// few shapes the marks build by hand (the Mac's StepPaths).
enum StepPaths {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for character in d {
            if character.isLetter, character != "e", character != "E" {
                flush(); tokens.append(String(character))
            } else if character == "-" {
                if let last = number.last, last == "e" || last == "E" { number.append(character) } else { flush(); number.append(character) }
            } else if character == "." {
                if number.contains(".") && !number.contains("e") { flush() }
                number.append(character)
            } else if character.isNumber || character == "e" || character == "E" {
                number.append(character)
            } else {
                flush()
            }
        }
        flush()
        var index = 0
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        func next() -> CGFloat { defer { index += 1 }; return CGFloat(Double(tokens[index]) ?? 0) }
        func hasNumber() -> Bool { index < tokens.count && !(tokens[index].first?.isLetter ?? false) }
        while index < tokens.count {
            if let letter = tokens[index].first, letter.isLetter { command = letter; index += 1 }
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                guard hasNumber() else { break }
                let point = CGPoint(x: base.x + next(), y: base.y + next())
                path.move(to: point); current = point; start = point
                command = relative ? "l" : "L"
            case "L":
                guard hasNumber() else { break }
                let point = CGPoint(x: base.x + next(), y: base.y + next())
                path.addLine(to: point); current = point
            case "H":
                guard hasNumber() else { break }
                let x = (relative ? current.x : 0) + next()
                current = CGPoint(x: x, y: current.y); path.addLine(to: current)
            case "V":
                guard hasNumber() else { break }
                let y = (relative ? current.y : 0) + next()
                current = CGPoint(x: current.x, y: y); path.addLine(to: current)
            case "C":
                guard hasNumber() else { break }
                let c1 = CGPoint(x: base.x + next(), y: base.y + next())
                let c2 = CGPoint(x: base.x + next(), y: base.y + next())
                let end = CGPoint(x: base.x + next(), y: base.y + next())
                path.addCurve(to: end, control1: c1, control2: c2); current = end
            case "Z":
                path.closeSubpath(); current = start
                if hasNumber() { command = "L" }
            default:
                index += 1
            }
        }
        return path
    }

    /// A turn by `degrees` about a point, clockwise as the grid is drawn.
    static func turn(_ degrees: CGFloat, _ x: CGFloat, _ y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -x, y: -y)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }

    static func moved(_ path: CGPath, _ transform: CGAffineTransform) -> CGPath {
        var transform = transform
        return path.copy(using: &transform) ?? path
    }

    /// A polygon's corners rounded, Lottie's way: each cut back its radius
    /// (at most half each side) and joined by a quarter circle's curve.
    static func rounded(_ points: [CGPoint], _ radii: [CGFloat], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        guard n > 1 else { return path }
        let k: CGFloat = 0.5523
        func corner(_ i: Int) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
            let v = points[i], a = points[(i - 1 + n) % n], b = points[(i + 1) % n]
            let da = CGPoint(x: a.x - v.x, y: a.y - v.y), db = CGPoint(x: b.x - v.x, y: b.y - v.y)
            let la = max(1e-6, hypot(da.x, da.y)), lb = max(1e-6, hypot(db.x, db.y))
            let c = min(radii[i % radii.count], la / 2, lb / 2)
            let ua = CGPoint(x: da.x / la, y: da.y / la), ub = CGPoint(x: db.x / lb, y: db.y / lb)
            func at(_ u: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: v.x + u.x * s, y: v.y + u.y * s) }
            return (at(ua, c), at(ua, c * (1 - k)), at(ub, c * (1 - k)), at(ub, c))
        }
        if closed {
            path.move(to: corner(0).3)
            for i in 1...n {
                let c = corner(i % n)
                path.addLine(to: c.0)
                path.addCurve(to: c.3, control1: c.1, control2: c.2)
            }
            path.closeSubpath()
        } else {
            path.move(to: points[0])
            for i in 1..<(n - 1) {
                let c = corner(i)
                path.addLine(to: c.0)
                path.addCurve(to: c.3, control1: c.1, control2: c.2)
            }
            path.addLine(to: points[n - 1])
        }
        return path
    }
}

/// A step's mark in its tint: its drawing a little over its box, as the
/// Mac sets a 24-point drawing in a mark (StepMark, 1.1 of the side).
struct StepMark: View {
    let art: StepArt
    var tint: Color = ChatInk.gray(0.6)
    var size: CGFloat = Metrics.Work.mark

    var body: some View {
        Image(uiImage: art.image)
            .resizable()
            .interpolation(.high)
            .foregroundStyle(tint)
            .frame(width: size * Metrics.Work.markOver, height: size * Metrics.Work.markOver)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
