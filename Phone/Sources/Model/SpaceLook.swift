import CoreGraphics
import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// The Mac's complete paint record. Editing the fields this iPhone knows
/// leaves newer effects and unknown fields in the same JSON value.
struct SpaceLook: Codable, Hashable, Sendable {
    private(set) var raw: Value

    init?(_ raw: Value) {
        guard let object = raw.object, object["swatch"]?.string != nil,
              let color = object["color"]?.string, Self.rgb(color) != nil else { return nil }
        self.raw = raw
    }

    init(color: RGB) {
        raw = .object(["swatch": .string("custom"), "color": .string(Self.hex(color)),
                       "grain": .bool(true), "grainAmount": .number(0.35), "transparency": .number(0)])
    }

    var swatch: String { raw.object?["swatch"]?.string ?? "custom" }
    var primary: RGB { Self.rgb(raw.object?["color"]?.string ?? "") ?? RGB(168, 195, 160) }
    var colors: [RGB] { raw.object?["colors"]?.array?.compactMap { $0.string.flatMap(Self.rgb) } ?? [] }
    var grain: Double {
        let value = raw.object?["grainAmount"]?.number ?? (raw.object?["grain"]?.bool == true ? 0.35 : 0)
        return Self.unit(value)
    }
    var transparency: Double { Self.unit(raw.object?["transparency"]?.number ?? 0) }
    /// The space's wash, as sync makes it from the Mac's color
    /// (SyncMapping.tint): its main color, mostly white.
    var wash: RGB {
        func mix(_ c: Int) -> Int { Int((Double(c) * 0.18 + 255 * 0.82).rounded()) }
        return RGB(mix(primary.r), mix(primary.g), mix(primary.b))
    }
    /// The color a space's grounds wear here (its card in the spaces, All
    /// Tabs): the one picked, lifted toward white only as far as dark words
    /// need to stay readable on it.
    var ground: RGB { Self.readable(primary) }

    static func readable(_ c: RGB) -> RGB {
        let lum = (0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)) / 255
        let floor = 0.62
        guard lum < floor else { return c }
        let t = (floor - lum) / (1 - lum)
        func up(_ v: Int) -> Int { Int((Double(v) + (255 - Double(v)) * t).rounded()) }
        return RGB(up(c.r), up(c.g), up(c.b))
    }
    /// The Mac's drawings: "browser", "life" or none, and how strongly.
    var drawings: String { raw.object?["drawings"]?.string ?? "" }
    var drawingsStrength: Double { Self.unit(raw.object?["drawingsStrength"]?.number ?? 0.45) }

    mutating func setPalette(_ color: LookColor, following: [LookColor]) {
        update(["swatch": .string("custom"), "color": .string(Self.hex(color.rgb)),
                "colors": .array(following.prefix(2).map { .string(Self.hex($0.rgb)) })])
    }

    mutating func setGrain(_ value: Double) {
        let amount = Self.unit(value)
        update(["grain": .bool(amount > 0), "grainAmount": .number(amount)])
    }

    mutating func setTransparency(_ value: Double) { update(["transparency": .number(Self.unit(value))]) }

    mutating func setDrawings(_ set: String) { update(["drawings": .string(set)]) }
    mutating func setDrawingsStrength(_ value: Double) { update(["drawingsStrength": .number(Self.unit(value))]) }

    private mutating func update(_ fields: [String: Value]) {
        var object = raw.object ?? [:]
        object.merge(fields) { _, new in new }
        raw = .object(object)
    }

    /// A remote edit received while the tray was open keeps its untouched
    /// fields, including effects this editor does not understand.
    func mergingChanges(from opened: SpaceLook, into latest: SpaceLook?) -> SpaceLook {
        var merged = latest?.raw.object ?? raw.object ?? [:]
        for key in ["swatch", "color", "colors", "grain", "grainAmount", "transparency", "drawings", "drawingsStrength"] {
            if raw.object?[key] != opened.raw.object?[key] { merged[key] = raw.object?[key] }
        }
        return SpaceLook(.object(merged)) ?? self
    }

    /// The swatches and dark shade use the Mac's existing color rule.
    func displayColors(dark: Bool) -> [RGB] {
        let pair: (UInt32, UInt32)? = switch swatch {
        case "gray": (0xE3E3E5, 0x202022)
        case "paper": (0xECEAE4, 0x1F1E1C)
        case "coral": (0xF2837C, 0x55282A)
        case "peach": (0xF5BB8C, 0x553823)
        case "sage": (0xA8C3A0, 0x28372A)
        case "sky": (0x8DB6E6, 0x1D304B)
        case "lavender": (0xB6A6E6, 0x2E274C)
        case "rose": (0xEEA2C4, 0x4C2338)
        case "graphite": (0x3B3B3E, 0x18181A)
        // No Color: white or black with the Mac's light and dark; its kept
        // color is white, so the grounds above go white too.
        case "plain": (0xFFFFFF, 0x0F0F0F)
        default: nil
        }
        let first = pair.map { Self.rgb(dark ? $0.1 : $0.0) } ?? (dark ? LookColor.deepened(primary) : primary)
        return [first] + colors.map { dark ? LookColor.deepened($0) : $0 }
    }

    static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    static func rgb(_ hex: String) -> RGB? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return rgb(value)
    }
    private static func rgb(_ value: UInt32) -> RGB { RGB(Int(value >> 16 & 255), Int(value >> 8 & 255), Int(value & 255)) }
    static func hex(_ color: RGB) -> String { String(format: "#%02X%02X%02X", color.r, color.g, color.b) }
}

/// The same OKLCH field and gamut-limited reach used by Mac LookHarmony.
struct LookColor: Equatable, Sendable {
    var lightness: Double
    var reach: Double
    var hue: Double

    init(lightness: Double, reach: Double, hue: Double) {
        // The whole 0 to 1, as the Mac's: a preset reaches white and black.
        self.lightness = min(1, max(0, lightness))
        self.reach = SpaceLook.unit(reach)
        self.hue = Self.turn(hue)
    }
    init(_ rgb: RGB) {
        let lch = Self.lch(rgb)
        let lightness = min(1, max(0, lch.0))
        self.init(lightness: lightness, reach: lch.1 / max(0.001, Self.chroma(lightness, lch.2)), hue: lch.2)
    }
    var rgb: RGB { Self.rgb(lightness, Self.chroma(lightness, hue) * reach, hue) }
    var point: CGPoint { CGPoint(x: 0.5 + cos(hue) * reach * 0.42, y: 0.5 + sin(hue) * reach * 0.42) }
    mutating func move(to point: CGPoint) {
        let x = Double(point.x) - 0.5, y = Double(point.y) - 0.5
        let distance = hypot(x, y)
        reach = min(1, distance / 0.42)
        if distance > 0.0001 { hue = Self.turn(atan2(y, x)) }
    }
    static func turn(_ hue: Double) -> Double {
        let result = hue.truncatingRemainder(dividingBy: 2 * .pi)
        return result < 0 ? result + 2 * .pi : result
    }
    static func deepened(_ color: RGB) -> RGB {
        let (l, c, h) = lch(color)
        let light = c < 0.02 ? min(0.24, max(0.2, l * 0.3)) : min(0.35, max(0.2, l * 0.45))
        return rgb(light, c * 0.6, h)
    }
    /// A space's color deep enough to fill a row under white words (the
    /// field's best row): its hue, OKLCH lightness 0.52, half the gamut's
    /// reach at most; a gray stays gray.
    static func filled(_ color: RGB) -> RGB {
        let (_, c, h) = lch(color)
        let light = 0.52
        return rgb(light, c < 0.012 ? 0.01 : min(chroma(light, h) * 0.5, max(0.05, c * 1.6)), h)
    }
    private static func lch(_ color: RGB) -> (Double, Double, Double) {
        func linear(_ component: Int) -> Double {
            let x = Double(component) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.r), g = linear(color.g), b = linear(color.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let z = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, hypot(a, z), atan2(z, a))
    }
    private static func linear(_ l: Double, _ c: Double, _ h: Double) -> [Double] {
        let a = c * cos(h), b = c * sin(h)
        let x = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let y = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let z = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return [4.0767416621 * x - 3.3077115913 * y + 0.2309699292 * z,
                -1.2684380046 * x + 2.6097574011 * y - 0.3413193965 * z,
                -0.0041960863 * x - 0.7034186147 * y + 1.7076147010 * z]
    }
    private static func rgb(_ l: Double, _ c: Double, _ h: Double) -> RGB {
        let components = linear(l, c, h).map { value -> Int in
            let x = min(1, max(0, value))
            let gamma = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return Int((gamma * 255).rounded())
        }
        return RGB(components[0], components[1], components[2])
    }
    private static func chroma(_ l: Double, _ h: Double) -> Double {
        var low = 0.0, high = 0.37
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if linear(l, mid, h).allSatisfy({ $0 >= -0.0001 && $0 <= 1.0001 }) { low = mid } else { high = mid }
        }
        return low
    }
}

struct LookHarmony: Equatable, Sendable {
    struct Link: Equatable, Sendable { var hue: Double; var reach: Double = 0; var lightness: Double = 0 }
    var links: [Link]
    init(primary: LookColor, colors: [RGB]) {
        links = colors.prefix(2).map {
            let color = LookColor($0)
            return Link(hue: LookColor.turn(color.hue - primary.hue), reach: color.reach - primary.reach,
                        lightness: color.lightness - primary.lightness)
        }
    }
    init(links: [Link] = []) { self.links = links }
    static func suggested(extras: Int) -> Self {
        Self(links: extras == 1 ? [.init(hue: .pi)] : extras == 2 ? [.init(hue: 2 * .pi / 3), .init(hue: 4 * .pi / 3)] : [])
    }
    func colors(from primary: LookColor) -> [LookColor] {
        links.map { .init(lightness: primary.lightness + $0.lightness, reach: primary.reach + $0.reach, hue: primary.hue + $0.hue) }
    }
    mutating func move(_ index: Int, to point: CGPoint, from primary: LookColor) {
        guard links.indices.contains(index) else { return }
        var color = colors(from: primary)[index]
        color.move(to: point)
        links[index].hue = LookColor.turn(color.hue - primary.hue)
        links[index].reach = color.reach - primary.reach
    }
}
