import CoreGraphics
import Foundation

// Yab Wrapped's screens, drawn on the arcade's pixel grid: the portrait
// story (180 by 320) and the landscape card to post (400 by 250, 16:10).
// Everything here is a function of the story and the time, so a frame can
// be drawn again exactly, for the tube, a test or a shot.

struct WrappedFrame {
    var story: WrappedStory
    var index: Int
    /// Seconds into this screen.
    var t: Double
    /// Seconds since Wrapped opened, for what moves throughout.
    var clock: Double
    var reduceMotion = false
    var icon: CGImage?
    var iconWorn = false

    var screen: WrappedScreen { story.screens[index] }
    /// How far along this screen is, for its segment at the top.
    var progress: Double {
        let length = screen.seconds
        return length > 0 ? min(1, t / length) : 1
    }
}

enum WrappedArcade {
    static let width = 180, height = 320
    static let cardWidth = 400, cardHeight = 250

    static func ease(_ k: Double) -> Double { 1 - pow(1 - max(0, min(1, k)), 3) }

    /// A number counting up from `start` over `length` seconds.
    static func counted(_ target: Int, t: Double, start: Double = 0.4, length: Double = 1.6, reduce: Bool) -> Int {
        reduce ? target : Int((Double(target) * ease((t - start) / length)).rounded())
    }

    static func blink(_ clock: Double, reduce: Bool) -> Bool { reduce || Int(clock * 2) % 2 == 0 }

    /// The largest scale, up to `most`, at which `text` fits `room` pixels.
    static func fit(_ text: String, room: Int, most: Int) -> Int {
        var s = most
        while s > 1, WrappedFont.measure(text, scale: s) > room { s -= 1 }
        return s
    }

    private static func noise(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 2_654_435_761 &+ salt &* 40_503)
        x ^= x >> 13
        x = x &* 0x5bd1e995
        x ^= x >> 15
        return Double(x % 10_000) / 10_000
    }

    static func stars(on g: WrappedGrid, clock: Double, count: Int = 70) {
        for i in 0..<count {
            let x = Int(noise(i, 1) * Double(g.width))
            let speed = 4 + noise(i, 3) * 10
            let y = Int((noise(i, 2) * Double(g.height) + clock * speed).truncatingRemainder(dividingBy: Double(g.height)))
            g.rect(x, y, 1, 1, noise(i, 4) > 0.7 ? .dim : .dots)
        }
    }

    /// Snow for the year's Wrapped: flakes drifting down, some bigger.
    static func snow(on g: WrappedGrid, clock: Double, count: Int = 90) {
        for i in 0..<count {
            let speed = 6 + noise(i, 3) * 14
            let y = (noise(i, 2) * Double(g.height) + clock * speed).truncatingRemainder(dividingBy: Double(g.height))
            let sway = sin(clock * (0.6 + noise(i, 5)) + noise(i, 6) * 6) * 3
            let x = Int((noise(i, 1) * Double(g.width) + sway).truncatingRemainder(dividingBy: Double(g.width)))
            let big = noise(i, 4) > 0.82
            g.rect(x, Int(y), big ? 2 : 1, big ? 2 : 1, noise(i, 7) > 0.5 ? .white : .dim)
        }
    }

    /// A string of lights across the top, sagging between hooks, blinking
    /// in turn.
    static func garland(on g: WrappedGrid, y top: Int, clock: Double) {
        let colors: [WrappedInk] = [.red, .green, .gold, .blue]
        let span = 30
        var x = 0
        while x < g.width {
            let along = Double(x % span) / Double(span)
            let y = top + Int(sin(along * .pi) * 5)
            g.rect(x, y, 1, 1, .dots)
            if x % 10 == 5 {
                let n = x / 10
                let lit = (Int(clock * 3) + n) % 3 != 0
                g.rect(x - 1, y + 1, 3, 3, lit ? colors[n % colors.count] : .slot)
            }
            x += 1
        }
    }

    /// Bursts going off over the screen, each in its own color, again and
    /// again.
    static func fireworks(on g: WrappedGrid, t: Double) {
        let colors: [WrappedInk] = [.gold, .pink, .cyan, .green, .violet, .red]
        for b in 0..<6 {
            let period = 1.6
            let local = (t + Double(b) * 0.37).truncatingRemainder(dividingBy: period)
            let round = Int((t + Double(b) * 0.37) / period)
            let cx = 30 + Int(noise(b * 7 + round, 11) * Double(g.width - 60))
            let cy = 40 + Int(noise(b * 7 + round, 12) * 120)
            let ink = colors[(b + round) % colors.count]
            guard local < 1.2 else { continue }
            let r = local * 34
            for p in 0..<14 {
                let a = Double(p) / 14 * .pi * 2
                let px = cx + Int(cos(a) * r), py = cy + Int(sin(a) * r + local * local * 10)
                g.rect(px, py, 1, 1, local > 0.9 ? .dots : ink)
                if local < 0.6 { g.rect(cx + Int(cos(a) * r * 0.6), cy + Int(sin(a) * r * 0.6), 1, 1, .white) }
            }
        }
    }

    // MARK: - the story

    static func draw(_ f: WrappedFrame, on g: WrappedGrid) {
        g.clear()
        if f.story.festive {
            snow(on: g, clock: f.reduceMotion ? 0 : f.clock)
            garland(on: g, y: 10, clock: f.reduceMotion ? 0 : f.clock)
        } else {
            stars(on: g, clock: f.reduceMotion ? 0 : f.clock)
        }
        segments(f, on: g)
        switch f.screen {
        case .coin: coin(f, on: g)
        case .rhythm: rhythm(f, on: g)
        case .character: character(f, on: g)
        case let .level(level, number, boss): self.level(level, number: number, boss: boss, f, on: g)
        case let .bonus(level): bonus(level, f, on: g)
        case .score: score(f, on: g)
        case .icon: icon(f, on: g)
        case .again: again(f, on: g)
        }
    }

    private static func segments(_ f: WrappedFrame, on g: WrappedGrid) {
        let count = f.story.screens.count
        let gap = 2, room = g.width - 12
        let each = max(1, (room - gap * (count - 1)) / count)
        for i in 0..<count {
            let x = 6 + i * (each + gap)
            g.rect(x, 5, each, 1, .slot)
            let lit = i < f.index ? each : i > f.index ? 0 : Int(Double(each) * f.progress)
            if lit > 0 { g.rect(x, 5, lit, 1, .white) }
        }
    }

    private static func coin(_ f: WrappedFrame, on g: WrappedGrid) {
        let mid = g.width / 2
        if f.story.festive {
            g.text("PLAYER 1   \(f.story.initials)", x: mid, y: 26, ink: .dim)
            g.text("YAB WRAPPED", x: mid, y: 70, scale: 2, ink: .white)
            g.text(f.story.period, x: mid, y: 96, scale: 7, ink: .gold)
            let hop = f.reduceMotion ? 0 : Int(abs(sin(f.clock * 3)) * 8)
            g.sprite(.tree, x: mid - 44, y: 190, scale: 3, ink: .green)
            g.sprite(.gift, x: mid + 20, y: 196 - hop, scale: 3, ink: .red)
            if blink(f.clock, reduce: f.reduceMotion) { g.text("HAPPY NEW YEAR", x: mid, y: 254, ink: .white) }
            g.text("PRESS START", x: mid, y: 276, ink: .dim)
            g.text("INSERT GIFT", x: mid, y: 292, ink: .dots)
            return
        }
        g.text("PLAYER 1   \(f.story.initials)", x: mid, y: 26, ink: .dim)
        g.text("YAB", x: mid, y: 92, scale: 6, ink: .white)
        g.text("WRAPPED", x: mid, y: 144, scale: 3, ink: .white)
        g.text(f.story.period, x: mid, y: 176, ink: .gold)
        let hop = f.reduceMotion ? 0 : Int(abs(sin(f.clock * 3)) * 10)
        g.sprite(.coin, x: mid - 12, y: 214 - hop, scale: 3, ink: .gold)
        if blink(f.clock, reduce: f.reduceMotion) { g.text("PRESS START", x: mid, y: 270, ink: .white) }
        g.text("INSERT COIN", x: mid, y: 292, ink: .dots)
    }

    private static func level(_ level: WrappedLevel, number: Int, boss: Bool, _ f: WrappedFrame, on g: WrappedGrid) {
        let mid = g.width / 2, reduce = f.reduceMotion
        // The boss is announced first, on a screen of its own for a moment.
        let intro = boss && !reduce ? 1.4 : 0
        if boss, f.t < intro {
            if blink(f.clock * 2, reduce: false) { g.text("WARNING", x: mid, y: 120, scale: 3, ink: .red) }
            g.text("BOSS: \(level.name)", x: mid, y: 160, scale: 2, ink: level.ink)
            return
        }
        let t = f.t - intro
        g.text(boss ? "BOSS LEVEL" : "LEVEL \(number)", x: mid, y: 20, ink: boss ? .red : .dim)
        g.sprite(level.sprite, x: mid - 12, y: 34, scale: 3, ink: level.ink)
        g.text(level.name, x: mid, y: 66, scale: fit(level.name, room: 168, most: 2), ink: level.ink)
        // What was done, counted up; the time back under the bar, smaller.
        let n = counted(level.big, t: t, reduce: reduce)
        let digits = WrappedStory.number(n)
        g.text(digits, x: mid, y: 92, scale: fit(digits, room: 168, most: 8), ink: .white)
        g.text(level.unit, x: mid, y: 156, ink: .white)
        // The health bar, full for the boss, the rest by their share of it.
        let most = f.story.levels.map(\.minutes).max() ?? 1
        let cells = 18
        let full = Int((Double(cells) * Double(level.minutes) / Double(max(1, most)) * (reduce ? 1 : ease((t - 0.4) / 1.6))).rounded(.up))
        g.frame(12, 172, 156, 14, .dim)
        for i in 0..<cells { g.rect(15 + i * 8, 175, 6, 8, i < full ? level.ink : .slot) }
        g.text(level.back, x: mid, y: 196, ink: .gold)
        var y = 212
        for line in level.lines { y = g.paragraph(line, y: y, ink: .white, leading: 10) + 2 }
        g.paragraph("HOW? " + level.how, y: max(y + 6, 236), ink: .dots, leading: 10)
        if t > 2.1 || reduce, blink(f.clock, reduce: reduce) {
            g.text(boss ? "BOSS DEFEATED" : "LEVEL CLEAR", x: mid, y: 298, ink: .gold)
        }
    }

    private static func bonus(_ level: WrappedLevel, _ f: WrappedFrame, on g: WrappedGrid) {
        let mid = g.width / 2, t = f.reduceMotion ? 9 : f.t
        g.text("BONUS STAGE", x: mid, y: 20, ink: .gold)
        if level.id == "ads" {
            invaders(t: t, clock: f.clock, ink: level.ink, on: g)
        } else {
            let bob = f.reduceMotion ? 0 : Int(sin(f.clock * 2.4) * 4)
            g.sprite(level.sprite, x: mid - 20, y: 52 + bob, scale: 5, ink: level.ink)
            for i in 0..<10 where !f.reduceMotion {
                let a = noise(i, 7) * .pi * 2 + f.clock * 0.6
                let r = 30 + noise(i, 8) * 20
                g.rect(mid + Int(cos(a) * r), 72 + Int(sin(a) * r * 0.7), 1, 1, i % 3 == 0 ? .white : level.ink)
            }
        }
        g.text(level.name, x: mid, y: 140, scale: fit(level.name, room: 168, most: 2), ink: level.ink)
        let n = counted(level.big, t: t, start: 0.6, length: 1.4, reduce: f.reduceMotion)
        let digits = WrappedStory.number(n)
        g.text(digits, x: mid, y: 164, scale: fit(digits, room: 168, most: 6), ink: .white)
        var y = g.paragraph(level.unit, y: 214, ink: .white, leading: 10) + 8
        for line in level.lines { y = g.paragraph(line, y: y, ink: .dim, leading: 10) + 2 }
        g.text("FOR FUN, NOT TIME SAVED", x: mid, y: 298, ink: .dots)
    }

    /// Ads as invaders, shot down one by one.
    private static func invaders(t: Double, clock: Double, ink: WrappedInk, on g: WrappedGrid) {
        let mid = g.width / 2
        let sway = Int(sin(clock * 1.5) * 12)
        for row in 0..<3 {
            for col in 0..<6 {
                let i = row * 6 + col
                let dies = 0.5 + Double(i) * 0.09
                let x = mid - 42 + col * 14 + sway, y = 40 + row * 14
                if t < dies {
                    g.sprite(.invader, x: x, y: y + (Int(clock * 2) % 2), ink: ink)
                } else if t < dies + 0.18 {
                    g.text("*", x: x + 4, y: y, ink: .white)
                }
                if t > dies - 0.2, t < dies { g.rect(mid + sway / 3, y + 10, 1, 112 - y - 10, .white) }
            }
        }
        g.rect(mid - 5 + sway / 3, 114, 11, 3, .green)
        g.rect(mid - 1 + sway / 3, 111, 3, 3, .green)
    }

    /// When in the day: a bar an hour, growing in, the peak one gold.
    private static func rhythm(_ f: WrappedFrame, on g: WrappedGrid) {
        let mid = g.width / 2, t = f.reduceMotion ? 9 : f.t
        let s = f.story
        g.text("YOUR RHYTHM", x: mid, y: 20, scale: 2, ink: .white)
        let most = max(1, s.hours.max() ?? 1)
        let peak = s.peak ?? s.hours.firstIndex(of: most)
        let x0 = 18, top = 52, floor = 146
        for (h, n) in s.hours.enumerated() {
            let grown = ease((t - 0.2 - Double(h) * 0.03) / 0.8)
            let height = max(1, Int(Double(floor - top) * Double(n) / Double(most) * grown))
            g.rect(x0 + h * 6, floor - height, 5, height, h == peak ? .gold : .violet)
        }
        g.rect(x0, floor + 1, 24 * 6 - 1, 1, .dots)
        for (h, label) in [(0, "12A"), (6, "6A"), (12, "12P"), (18, "6P")] { g.text(label, x: x0 + h * 6, y: floor + 5, ink: .dots, align: .left) }
        let said = t > 1.4
        if let peak, said {
            g.text("PEAK", x: mid, y: 176, ink: .dim)
            g.text(WrappedStory.hour(peak), x: mid, y: 188, scale: 4, ink: .gold)
        }
        if s.streak >= 2, t > 1.8 { g.text("\(s.streak) DAYS IN A ROW", x: mid, y: 238, ink: .white) }
    }

    /// When CHARACTER SELECT's cursor steps, getting slower, and when it
    /// lands on the player: one clock for the picture and the sounds.
    static func select(_ story: WrappedStory) -> (ticks: [Double], land: Double) {
        let steps = 20 + (WrappedType.allCases.firstIndex(of: story.character.type) ?? 0)
        var clock = 0.3, ticks: [Double] = []
        for k in 0..<steps {
            clock += 0.045 + pow(Double(k) / Double(steps), 3) * 0.28
            ticks.append(clock)
        }
        return (ticks, clock)
    }

    /// CHARACTER SELECT: the cursor runs the grid of types, slows, and
    /// stops on the player's; then the name, the line and the bars.
    private static func character(_ f: WrappedFrame, on g: WrappedGrid) {
        let mid = g.width / 2, t = f.reduceMotion ? 99 : f.t
        let me = f.story.character
        let all = WrappedType.allCases
        g.text("CHARACTER SELECT", x: mid, y: 20, ink: .dim)
        // Where the cursor is: steps getting longer, landing on the player.
        let target = all.firstIndex(of: me.type) ?? 0
        let select = self.select(f.story)
        let at = select.ticks.filter { $0 <= t }.count
        let landed = t >= select.land
        let clock = landed ? select.land : 0
        let cursor = landed ? target : at % all.count
        for (i, type) in all.enumerated() {
            let x = 12 + (i % 4) * 40, y = 36 + (i / 4) * 28
            let on = i == cursor
            if on { g.rect(x, y, 36, 24, .slot) }
            g.frame(x, y, 36, 24, on ? type.ink : .slot)
            g.text(type.code, x: x + 18, y: y + 9, ink: on ? type.ink : .dim)
        }
        let shown = all[cursor]
        g.text("PLAYER 1 IS", x: mid, y: 128, ink: .dim)
        // One size while the cursor runs, so the names don't jump; the
        // player's as big as it fits once it lands.
        g.text(shown.name, x: mid, y: 142, scale: landed ? fit(shown.name, room: 168, most: 3) : 2, ink: landed ? shown.ink : .dots)
        guard landed else { return }
        let after = t - clock
        g.paragraph(me.line, y: 172, ink: .white, leading: 10)
        for (i, bar) in me.bars.enumerated() where f.reduceMotion || after > 0.3 + Double(i) * 0.15 {
            let y = 198 + i * 14
            g.text(bar.stat, x: 12, y: y, ink: .dim, align: .left)
            for k in 0..<10 { g.rect(62 + k * 9, y, 7, 7, k < bar.value ? me.type.ink : .slot) }
            g.text("\(bar.value)", x: 168, y: y, ink: .white, align: .right)
        }
        if let dash = me.dash, f.reduceMotion || after > 1.2 {
            g.paragraph("WITH A DASH OF \(dash.name)", y: 262, ink: dash.ink, leading: 10)
        }
    }

    private static func score(_ f: WrappedFrame, on g: WrappedGrid) {
        let mid = g.width / 2, t = f.t, reduce = f.reduceMotion
        g.text("HIGH SCORE", x: mid, y: 20, ink: .gold)
        let hours = f.story.minutes / 60
        let digits = String(counted(hours, t: t, start: 0.3, length: 1.6, reduce: reduce))
        g.text("ABOUT", x: mid, y: 34, ink: .dim)
        g.text(digits, x: mid, y: 44, scale: fit(digits, room: 168, most: 9), ink: .white)
        g.text("HOURS BACK", x: mid, y: 110, scale: 2, ink: .white)
        g.text(f.story.period, x: mid, y: 132, ink: .dim)
        for (i, level) in f.story.levels.enumerated() where reduce || t > 1.8 + Double(i) * 0.35 {
            row(level, rank: i + 1, y: 156 + i * 16, left: 8, right: g.width - 8, on: g)
        }
        if reduce || t > 1.8 + Double(f.story.levels.count) * 0.35 + 0.4, blink(f.clock, reduce: reduce) {
            g.text("S  SHARE YOUR SCORE", x: mid, y: 290, ink: .white)
        }
    }

    /// One row of the score table: rank, picture, name, dots, hours.
    static func row(_ level: WrappedLevel, rank: Int, y: Int, left: Int, right: Int, on g: WrappedGrid) {
        g.text("\(rank)", x: left, y: y, ink: .dim, align: .left)
        g.sprite(level.sprite, x: left + 9, y: y - 1, ink: level.ink)
        g.text(level.name, x: left + 21, y: y, ink: level.ink, align: .left)
        let score = level.score
        let value = "\(score.value)\(score.unit.hasPrefix("H") ? "H" : "M")"
        g.text(value, x: right, y: y, ink: .white, align: .right)
        let from = left + 21 + WrappedFont.measure(level.name, scale: 1) + 4
        let to = right - WrappedFont.measure(value, scale: 1) - 4
        var x = from
        while x < to { g.rect(x, y + 6, 1, 1, .dots); x += 3 }
    }

    private static func icon(_ f: WrappedFrame, on g: WrappedGrid) {
        let mid = g.width / 2, t = f.reduceMotion ? 9 : f.t
        g.text("NEW ICON", x: mid, y: 40, scale: 2, ink: .gold)
        g.text("UNLOCKED", x: mid, y: 60, scale: 2, ink: .gold)
        let drop = Int(-120 * pow(max(0, 1 - t / 0.7), 2))
        let bounce = t > 0.7 ? Int(-6 * max(0, sin((t - 0.7) * 9)) * exp(-(t - 0.7) * 4)) : 0
        if let image = f.icon {
            picture(image, x: mid - 40, y: 96 + drop + bounce, side: 80, on: g)
        }
        g.text("ARCADE", x: mid, y: 194, scale: 2, ink: .white)
        g.text("FOR FINISHING YAB WRAPPED", x: mid, y: 216, ink: .dim)
        if f.iconWorn {
            g.text("IN YOUR DOCK NOW", x: mid, y: 262, ink: .green)
        } else if blink(f.clock, reduce: f.reduceMotion) {
            g.text("W  WEAR IT", x: mid, y: 262, ink: .white)
        }
        g.text("IN APPEARANCE > APP ICON", x: mid, y: 290, ink: .dots)
    }

    /// A picture squeezed onto the grid, nearest pixel, so it reads as
    /// pixel art.
    static func picture(_ image: CGImage, x: Int, y: Int, side: Int, on g: WrappedGrid) {
        let c = g.context
        c.saveGState()
        c.interpolationQuality = .none
        c.translateBy(x: CGFloat(x), y: CGFloat(y + side))
        c.scaleBy(x: 1, y: -1)
        // Rounded like a Mac icon, on the grid's square pixels.
        let r = CGFloat(side) * 0.22
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerWidth: r, cornerHeight: r, transform: nil))
        c.clip()
        c.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        c.restoreGState()
    }

    private static func again(_ f: WrappedFrame, on g: WrappedGrid) {
        let mid = g.width / 2
        let left = 9 - Int(f.reduceMotion ? 0 : f.t)
        if f.story.festive {
            // The year's last screen counts down to the next one.
            if left >= 0 {
                g.text("\(f.story.nextYear) IN", x: mid, y: 70, scale: 3, ink: .white)
                g.text("\(left)", x: mid, y: 110, scale: 9, ink: .gold)
            } else {
                fireworks(on: g, t: f.reduceMotion ? 0.5 : f.t - 10)
                g.text("HAPPY", x: mid, y: 150, scale: 3, ink: .white)
                g.text("\(f.story.nextYear)!", x: mid, y: 180, scale: 4, ink: .gold)
            }
            g.text("S  SHARE YOUR SCORE", x: mid, y: 246, ink: .white)
            g.text("R  PLAY AGAIN", x: mid, y: 262, ink: .dim)
            g.text("ESC  CLOSE", x: mid, y: 290, ink: .dots)
            return
        }
        if left >= 0 {
            g.text("CONTINUE?", x: mid, y: 70, scale: 3, ink: .white)
            g.text("\(left)", x: mid, y: 120, scale: 9, ink: .gold)
            g.text("S  SHARE YOUR SCORE", x: mid, y: 230, ink: .white)
            g.text("R  PLAY AGAIN", x: mid, y: 246, ink: .dim)
        } else {
            g.text("GAME OVER", x: mid, y: 120, scale: 3, ink: .white)
            g.text("THANKS FOR PLAYING", x: mid, y: 160, ink: .dim)
            g.text("S  SHARE   R  PLAY AGAIN", x: mid, y: 246, ink: .dim)
        }
        g.text("ESC  CLOSE", x: mid, y: 290, ink: .dots)
    }

    /// Not enough played yet: what there is so far, and that it counts here.
    static func waiting(have: Int, period: String, clock: Double, reduce: Bool, on g: WrappedGrid) {
        g.clear()
        stars(on: g, clock: reduce ? 0 : clock)
        let mid = g.width / 2
        g.text("YAB WRAPPED", x: mid, y: 60, scale: 2, ink: .gold)
        g.sprite(.coin, x: mid - 12, y: 96, scale: 3, ink: .gold)
        if blink(clock, reduce: reduce) { g.text("KEEP PLAYING", x: mid, y: 140, scale: 2, ink: .white) }
        g.paragraph("YOUR WRAPPED NEEDS \(WrappedStory.fewest) LEVELS. YOU HAVE \(have) SO FAR.", y: 176, ink: .white, leading: 10)
        g.paragraph("A LEVEL IS SOMETHING YAB DID FOR YOU: TASKS, ANSWERS, MAIL, FORMS, TABS.", y: 210, ink: .dim, leading: 10)
        g.paragraph("COUNTED ON THIS MAC ONLY", y: 262, ink: .dots, leading: 10)
        g.text("ESC  CLOSE", x: mid, y: 290, ink: .dots)
    }

    // MARK: - the card to post, 16:10

    /// The card to post: the player's character first, what they handed
    /// off beside it, the hours back as a footnote they can leave out.
    struct Card {
        var story: WrappedStory
        var showHours = true
        var showDash = true
        var link: String?
        var icon: CGImage?
    }

    static func card(_ card: Card, on g: WrappedGrid) {
        g.clear()
        let story = card.story
        let me = story.character
        if story.festive {
            snow(on: g, clock: 3.7, count: 170)
            garland(on: g, y: 2, clock: 1)
        } else {
            stars(on: g, clock: 3.7, count: 140)
        }
        g.text("YAB WRAPPED  \(story.period)  \(story.initials)", x: 20, y: 18, ink: .dim, align: .left)
        g.text("PLAYER 1 IS", x: 20, y: 40, ink: .dim, align: .left)
        g.text(me.type.name, x: 20, y: 54, scale: fit(me.type.name, room: 360, most: 5), ink: me.type.ink, align: .left)
        // Left: the line, the dash, the hours back.
        var y = 104
        for line in WrappedFont.wrap(me.line, columns: 30) {
            g.text(line, x: 20, y: y, ink: .white, align: .left)
            y += 12
        }
        if card.showDash, let dash = me.dash {
            y += 4
            for line in WrappedFont.wrap("WITH A DASH OF \(dash.name)", columns: 30) {
                g.text(line, x: 20, y: y, ink: dash.ink, align: .left)
                y += 12
            }
        }
        if card.showHours, story.minutes >= 60 {
            g.text("~\(story.minutes / 60)H BACK", x: 20, y: max(y + 10, 160), scale: 3, ink: .gold, align: .left)
        }
        // Right: the bars.
        for (i, bar) in me.bars.enumerated() {
            let row = 110 + i * 20
            g.text(bar.stat, x: 214, y: row, ink: .dim, align: .left)
            for k in 0..<10 { g.rect(262 + k * 10, row, 8, 8, k < bar.value ? me.type.ink : .slot) }
            g.text("\(bar.value)", x: 380, y: row, ink: .white, align: .right)
        }
        if let icon = card.icon { picture(icon, x: 350, y: 200, side: 30, on: g) }
        // Foot: where it came from, with the invite so friends count.
        g.rect(20, 214, 310, 1, .dots)
        g.text((card.link ?? "YETANOTHERBROWSER.COM").uppercased(), x: 20, y: 226, ink: .dim, align: .left)
    }

    static func cardGrid(_ card: Card) -> WrappedGrid? {
        guard let g = WrappedGrid(width: cardWidth, height: cardHeight) else { return nil }
        self.card(card, on: g)
        return g
    }
}
