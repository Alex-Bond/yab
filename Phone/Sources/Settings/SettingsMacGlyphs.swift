import UIKit

/// Exact 24-point Settings drawings from the selected Mac Glyphs.swift. Only their
/// compile-time M/L/H/V/C/Z paths, circular arcs and circles are accepted, never page SVG.
@MainActor
enum SettingsMacGlyphs {
    private static var images: [String: UIImage] = [:]
    static var names: [String] { parts.keys.sorted() }

    static func image(_ name: String) -> UIImage? {
        if let hit = images[name] { return hit }
        guard let source = parts[name] else { return nil }
        let paths = source.compactMap { part -> (Part, CGPath)? in part.path().map { (part, $0) } }
        guard paths.count == source.count else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { output in
            let context = output.cgContext
            context.setFillColor(UIColor.black.cgColor); context.setStrokeColor(UIColor.black.cgColor)
            for (part, path) in paths {
                context.setLineWidth(part.stroke); context.setLineCap(part.cap)
                context.setLineJoin(part.join); context.setMiterLimit(part.miter)
                if part.fill { context.addPath(path); context.fillPath(using: part.evenOdd ? .evenOdd : .winding) }
                if part.stroke > 0 { context.addPath(path); context.strokePath() }
            }
        }.withRenderingMode(.alwaysTemplate)
        images[name] = image
        return image
    }

    private struct Part {
        let words: String?
        var circle: CGRect?
        var stroke: CGFloat
        var cap: CGLineCap
        var join: CGLineJoin
        var fill: Bool
        var evenOdd: Bool
        var miter: CGFloat
        init(_ words: String, stroke: CGFloat = 0, cap: CGLineCap = .butt, join: CGLineJoin = .miter, fill: Bool = false,
             evenOdd: Bool = false, miter: CGFloat = 10) {
            self.words = words; self.stroke = stroke; self.cap = cap; self.join = join
            self.fill = fill; self.evenOdd = evenOdd; self.miter = miter
        }
        init(circleX: CGFloat, y: CGFloat, radius: CGFloat, stroke: CGFloat = 0, cap: CGLineCap = .butt, join: CGLineJoin = .miter,
             fill: Bool = false, evenOdd: Bool = false, miter: CGFloat = 10) {
            words = nil; circle = CGRect(x: circleX - radius, y: y - radius, width: radius * 2, height: radius * 2)
            self.stroke = stroke; self.cap = cap; self.join = join; self.fill = fill; self.evenOdd = evenOdd; self.miter = miter
        }
        func path() -> CGPath? {
            if let circle { return CGPath(ellipseIn: circle, transform: nil) }
            guard let words else { return nil }
            let tokens = words.replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "([MLHVCAZ])", with: " $1 ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).map(String.init)
            let path = CGMutablePath(); var i = 0; var current = CGPoint.zero; var start = CGPoint.zero
            while i < tokens.count {
                let command = tokens[i]; i += 1
                let count: Int
                switch command { case "M", "L": count = 2; case "H", "V": count = 1; case "C": count = 6; case "A": count = 7; case "Z": count = 0; default: return nil }
                guard i + count <= tokens.count else { return nil }
                let values = tokens[i..<(i + count)].compactMap { Double($0) }.map { CGFloat($0) }
                guard values.count == count, values.allSatisfy(\.isFinite) else { return nil }; i += count
                switch command {
                case "M": current = CGPoint(x: values[0], y: values[1]); start = current; path.move(to: current)
                case "L": current = CGPoint(x: values[0], y: values[1]); path.addLine(to: current)
                case "H": current.x = values[0]; path.addLine(to: current)
                case "V": current.y = values[0]; path.addLine(to: current)
                case "C":
                    current = CGPoint(x: values[4], y: values[5])
                    path.addCurve(to: current, control1: CGPoint(x: values[0], y: values[1]), control2: CGPoint(x: values[2], y: values[3]))
                case "A":
                    // The pinned Feedback drawing contains only circular arcs.
                    let end = CGPoint(x: values[5], y: values[6])
                    let dx = (current.x - end.x) / 2, dy = (current.y - end.y) / 2
                    let squared = dx * dx + dy * dy
                    guard values[0] > 0, values[0] == values[1], values[2] == 0,
                          (values[3] == 0 || values[3] == 1), (values[4] == 0 || values[4] == 1), squared > 0 else { return nil }
                    let radius = max(values[0], sqrt(squared))
                    let sign: CGFloat = values[3] == values[4] ? -1 : 1
                    let coefficient = sign * sqrt(max(0, (radius * radius - squared) / squared))
                    let center = CGPoint(x: (current.x + end.x) / 2 + coefficient * dy,
                                         y: (current.y + end.y) / 2 - coefficient * dx)
                    path.addArc(center: center, radius: radius,
                                startAngle: atan2(current.y - center.y, current.x - center.x),
                                endAngle: atan2(end.y - center.y, end.x - center.x), clockwise: values[4] == 0)
                    current = end
                case "Z": path.closeSubpath(); current = start
                default: return nil
                }
            }
            return path
        }
    }

    // Coordinates and styles are the selected Mac drawings', point for point.
    private static let parts: [String: [Part]] = [
        "gearshape": [
            Part("M 7.98941 5.39755 L 7.30515 5.23965 C 6.72652 5.10612 6.11991 5.28009 5.7 5.7 C 5.28009 6.11991 5.10612 6.72651 5.23965 7.30515 L 5.39755 7.9894 C 5.57956 8.7781 5.25434 9.59711 4.58086 10.0461 L 3.74885 10.6008 C 3.28101 10.9127 3 11.4377 3 12 C 3 12.5623 3.28101 13.0873 3.74885 13.3992 L 4.58086 13.9539 C 5.25434 14.4029 5.57956 15.2219 5.39756 16.0106 L 5.23965 16.6949 C 5.10612 17.2735 5.28009 17.8801 5.7 18.3 C 6.11991 18.7199 6.72651 18.8939 7.30515 18.7604 L 7.9894 18.6024 C 8.7781 18.4204 9.59711 18.7457 10.0461 19.4191 L 10.6008 20.2512 C 10.9127 20.719 11.4377 21 12 21 C 12.5623 21 13.0873 20.719 13.3992 20.2512 L 13.9539 19.4191 C 14.4029 18.7457 15.2219 18.4204 16.0106 18.6024 L 16.6949 18.7604 C 17.2735 18.8939 17.8801 18.7199 18.3 18.3 C 18.7199 17.8801 18.8939 17.2735 18.7604 16.6949 L 18.6024 16.0106 C 18.4204 15.2219 18.7457 14.4029 19.4191 13.9539 L 20.2512 13.3992 C 20.719 13.0873 21 12.5623 21 12 C 21 11.4377 20.719 10.9127 20.2512 10.6008 L 19.4191 10.0461 C 18.7457 9.59711 18.4204 8.7781 18.6024 7.98941 L 18.7604 7.30515 C 18.8939 6.72652 18.7199 6.11991 18.3 5.7 C 17.8801 5.28009 17.2735 5.10612 16.6949 5.23965 L 16.0106 5.39755 C 15.2219 5.57956 14.4029 5.25434 13.9539 4.58086 L 13.3992 3.74884 C 13.0873 3.28101 12.5623 3 12 3 C 11.4377 3 10.9127 3.28101 10.6008 3.74885 L 10.0461 4.58086 C 9.59711 5.25434 8.7781 5.57956 7.98941 5.39755 Z", stroke: 2.0, join: .round),
            Part("M 15 12 C 15 13.6569 13.6569 15 12 15 C 10.3431 15 9 13.6569 9 12 C 9 10.3431 10.3431 9 12 9 C 13.6569 9 15 10.3431 15 12 Z", stroke: 2.0, join: .round)
        ],
        "magnifyingglass": [
            Part("M 11 18 C 14.866 18 18 14.866 18 11 C 18 7.13401 14.866 4 11 4 C 7.13401 4 4 7.13401 4 11 C 4 14.866 7.13401 18 11 18 Z", stroke: 2.0, cap: .round),
            Part("M 20 20 L 16.05 16.05", stroke: 2.0, cap: .round)
        ],
        "paintpalette": [
            Part(circleX: 12, y: 12, radius: 9, stroke: 2.0),
            Part("M 12 8 C 14.2091 8 16 9.79086 16 12 C 16 14.2091 14.2091 16 12 16 V 21 C 16.9706 21 21 16.9706 21 12 C 21 7.02944 16.9706 3 12 3 V 8 Z M 12 8 C 9.79086 8 8 9.79086 8 12 C 8 14.2091 9.79086 16 12 16 V 8 Z", fill: true)
        ],
        "rectangle.split.3x1": [
            Part("M 19 5 H 5 C 3.89543 5 3 5.89543 3 7 V 17 C 3 18.1046 3.89543 19 5 19 H 19 C 20.1046 19 21 18.1046 21 17 V 7 C 21 5.89543 20.1046 5 19 5 Z", stroke: 2.0, cap: .round, join: .round),
            Part("M 6.5 8.5 L 10.5 8.5", stroke: 2.0, cap: .round, join: .round),
            Part("M 17 8.5 H 17.5", stroke: 2.0, cap: .round, join: .round),
            Part("M 13.5 8.5 H 14", stroke: 2.0, cap: .round, join: .round)
        ],
        "sparkles": [
            Part("M 19 13 C 14.0987 13.4243 11.4243 16.0987 11 21 C 10.5578 16.0225 7.89737 13.5547 3 13 C 7.97478 12.4262 10.4262 9.97478 11 5 C 11.5547 9.89737 14.0225 12.5578 19 13 Z", stroke: 2.0, cap: .round, join: .round),
            Part("M 18.8864 2.34512 C 18.8642 2.14869 18.6981 2.0002 18.5004 2 C 18.3027 1.9998 18.1363 2.14794 18.1137 2.34433 C 18.0082 3.25861 17.7367 3.88584 17.3113 4.31127 C 16.8858 4.7367 16.2586 5.00822 15.3443 5.11367 C 15.1479 5.13632 14.9998 5.30271 15 5.5004 C 15.0002 5.69809 15.1487 5.86417 15.3451 5.88642 C 16.2439 5.98823 16.8855 6.25969 17.3217 6.68804 C 17.7556 7.11407 18.0322 7.74041 18.1126 8.64552 C 18.1305 8.84634 18.2988 9.00023 18.5004 9 C 18.702 8.99977 18.8701 8.84551 18.8874 8.64465 C 18.9645 7.75483 19.2409 7.11438 19.6776 6.67764 C 20.1144 6.24091 20.7548 5.96446 21.6446 5.88744 C 21.8455 5.87005 21.9998 5.70205 22 5.50044 C 22.0002 5.29883 21.8463 5.13048 21.6455 5.11264 C 20.7404 5.03224 20.1141 4.75557 19.688 4.3217 C 19.2597 3.88545 18.9882 3.24394 18.8864 2.34512 Z", fill: true)
        ],
        "square.2.layers.3d": [
            Part("M 7.90035 12.0002 L 3.59283 14.1014 C 2.84406 14.4666 2.84406 15.5337 3.59283 15.8989 L 11.5619 19.7863 C 11.8386 19.9213 12.1621 19.9213 12.4388 19.7863 L 20.4079 15.8989 C 21.1566 15.5337 21.1566 14.4666 20.4079 14.1014 L 16.1004 12.0002 M 7.90035 12.0002 L 3.59283 9.89893 C 2.84406 9.53367 2.84406 8.46664 3.59283 8.10139 L 11.5619 4.21402 C 11.8386 4.07905 12.1621 4.07905 12.4388 4.21402 L 20.4079 8.10139 C 21.1566 8.46664 21.1566 9.53367 20.4079 9.89893 L 16.1004 12.0002 M 7.90035 12.0002 L 11.5619 13.7863 C 11.8386 13.9213 12.1621 13.9213 12.4388 13.7863 L 16.1004 12.0002", stroke: 2.0, cap: .square, join: .round)
        ],
        "key": [
            Part("M 15.4 8.5 H 15.5 H 15.6 M 16 8.5 C 16 8.77614 15.7761 9 15.5 9 C 15.2239 9 15 8.77614 15 8.5 C 15 8.22386 15.2239 8 15.5 8 C 15.7761 8 16 8.22386 16 8.5 Z", stroke: 2.0, cap: .round, join: .round),
            Part("M 15.5 14 C 18.5376 14 21 11.5376 21 8.5 C 21 5.46243 18.5376 3 15.5 3 C 12.4624 3 10 5.46243 10 8.5 C 10 8.96094 10.0567 9.40863 10.1635 9.83649 L 4.58579 15.4142 C 4.21071 15.7893 4 16.298 4 16.8284 V 19 C 4 19.5523 4.44772 20 5 20 H 7.17157 C 7.70201 20 8.21071 19.7893 8.58579 19.4142 L 10 18 V 15.5 H 12.5 L 14.1635 13.8365 C 14.5914 13.9433 15.0391 14 15.5 14 Z", stroke: 2.0, cap: .square, join: .round)
        ],
        "creditcard": [
            Part("M 3 10 V 17 C 3 18.1046 3.89543 19 5 19 H 19 C 20.1046 19 21 18.1046 21 17 V 10 M 3 10 V 7 C 3 5.89543 3.89543 5 5 5 H 19 C 20.1046 5 21 5.89518 21 6.99975 V 10 M 3 10 H 21", stroke: 2.0, cap: .square)
        ],
        "hand.raised": [
            Part("M 17.0016 7.5 C 17.0016 6.67157 17.6732 6 18.5016 6 C 19.33 6 20.0016 6.67157 20.0016 7.5 V 13.8292 C 20.0016 17.7895 16.7911 21 12.8308 21 C 10.1685 21 7.72528 19.525 6.48529 17.169 L 3.8065 12.0793 C 3.62131 11.7274 3.66217 11.2993 3.91055 10.9888 L 4.25222 10.5617 C 4.94224 9.69921 6.20083 9.55937 7.06335 10.2494 L 8.00161 11 V 5.5 C 8.00161 4.67157 8.67319 4 9.50161 4 C 10.33 4 11.0016 4.67157 11.0016 5.5 M 17.0016 7.5 V 5.5 C 17.0016 4.67157 16.33 4 15.5016 4 C 14.6732 4 14.0016 4.67157 14.0016 5.5 M 17.0016 7.5 V 12 M 11.0016 5.5 V 4.5 C 11.0016 3.67157 11.6732 3 12.5016 3 C 13.33 3 14.0016 3.67157 14.0016 4.5 V 5.5 M 11.0016 5.5 V 11 M 14.0016 5.5 V 11.5", stroke: 2.0, cap: .round, join: .round)
        ],
        "info.circle": [
            Part("M 11 11 H 12 V 16 M 21 12 C 21 16.9706 16.9706 21 12 21 C 7.02944 21 3 16.9706 3 12 C 3 7.02944 7.02944 3 12 3 C 16.9706 3 21 7.02944 21 12 Z", stroke: 2.0, cap: .round, join: .round),
            Part("M 12 7.25 C 11.5858 7.25 11.25 7.58579 11.25 8 C 11.25 8.41421 11.5858 8.75 12 8.75 C 12.4142 8.75 12.75 8.41421 12.75 8 C 12.75 7.58579 12.4142 7.25 12 7.25 Z", stroke: 0.5, fill: true)
        ],
        "feedback": [
            Part("M 8 9 H 16", stroke: 2.0, cap: .round, join: .round),
            Part("M 8 13 H 14", stroke: 2.0, cap: .round, join: .round),
            Part("M 12.5 20.5 L 12 21 L 9 18 H 6 A 3 3 0 0 1 3 15 V 7 A 3 3 0 0 1 6 4 H 18 A 3 3 0 0 1 21 7 V 12.5", stroke: 2.0, cap: .round, join: .round),
            Part("M 16 19 H 22", stroke: 2.0, cap: .round, join: .round),
            Part("M 19 16 V 22", stroke: 2.0, cap: .round, join: .round)
        ]
    ]
}
