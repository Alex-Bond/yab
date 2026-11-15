import AVFoundation
import Foundation

// Yab Wrapped's sounds, made the way the arcade machines made them: square
// and triangle waves and a little noise, synthesized here when the arcade
// first plays one, no sound files. Quiet, only while the arcade is up, and
// the first only after the person pressed Return on its row. M or the
// speaker in the strip under the tube turns them off, and off they stay
// (`wrapped.muted`).
//
// What plays when is the story's cues (WrappedSound.cues): times into a
// screen, worked out from the same clock the screen is drawn on.

enum WrappedSfx: String, CaseIterable {
    case coin, roll, tick, clear, boss, zap, pop, step, land, bar0, bar1, bar2, bar3, dash, score, unlock, count, over, firework
}

@MainActor
final class WrappedSound {
    static let shared = WrappedSound()
    static let mutedKey = "wrapped.muted"
    /// Under everything else the Mac plays.
    static let volume: Float = 0.22

    static var muted: Bool {
        get { Store.settings.bool(forKey: mutedKey) }
        set {
            Store.settings.set(newValue, forKey: mutedKey)
            if newValue { shared.stop() }
        }
    }

    private let rate = 44_100.0
    private var engine: AVAudioEngine?
    private var voices: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [WrappedSfx: AVAudioPCMBuffer] = [:]
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!

    /// The last sounds played, for the bench to hear without speakers.
    private(set) var played: [WrappedSfx] = []

    func play(_ sfx: WrappedSfx) {
        guard !Self.muted else { return }
        played = Array((played + [sfx]).suffix(64))
        guard let engine = start() else { return }
        guard let buffer = buffer(sfx) else { return }
        // Eight voices in turn: a tick can't cut off the chord under it.
        let voice = voices[next % voices.count]
        next += 1
        if !engine.isRunning { try? engine.start() }
        voice.stop()
        voice.scheduleBuffer(buffer, at: nil, options: [])
        voice.play()
    }

    func stop() {
        voices.forEach { $0.stop() }
        engine?.stop()
    }

    private func start() -> AVAudioEngine? {
        if let engine { return engine }
        let engine = AVAudioEngine()
        for _ in 0..<8 {
            let voice = AVAudioPlayerNode()
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
            voices.append(voice)
        }
        engine.mainMixerNode.outputVolume = Self.volume
        do { try engine.start() } catch { return nil }
        self.engine = engine
        return engine
    }

    private func buffer(_ sfx: WrappedSfx) -> AVAudioPCMBuffer? {
        if let made = buffers[sfx] { return made }
        let samples = WrappedSynth(rate: rate).sound(sfx)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        buffers[sfx] = buffer
        return buffer
    }

    // MARK: - when

    /// What plays on a screen, by seconds into it.
    static func cues(_ screen: WrappedScreen, story: WrappedStory) -> [(at: Double, sfx: WrappedSfx)] {
        var out: [(Double, WrappedSfx)] = [(0, .roll)]
        func ticks(from: Double, to: Double, every: Double = 0.12) {
            var t = from
            while t < to { out.append((t, .tick)); t += every }
        }
        switch screen {
        case .coin:
            out.append((0.25, .coin))
        case .rhythm:
            ticks(from: 0.2, to: 1.1, every: 0.09)
        case let .level(_, _, boss):
            let intro = boss ? 1.4 : 0
            if boss { out.append((0, .boss)) }
            ticks(from: intro + 0.4, to: intro + 2.0)
            out.append((intro + 2.1, .clear))
        case let .bonus(level):
            if level.id == "ads" {
                for i in 0..<18 {
                    let dies = 0.5 + Double(i) * 0.09
                    out.append((dies - 0.2, .zap))
                    out.append((dies, .pop))
                }
            } else {
                ticks(from: 0.6, to: 2.0)
            }
        case .character:
            let select = WrappedArcade.select(story)
            out += select.ticks.map { ($0, .step) }
            out.append((select.land, .land))
            for i in 0..<min(4, story.character.bars.count) {
                out.append((select.land + 0.3 + Double(i) * 0.15, [WrappedSfx.bar0, .bar1, .bar2, .bar3][i]))
            }
            if story.character.dash != nil { out.append((select.land + 1.2, .dash)) }
        case .score:
            ticks(from: 0.3, to: 1.9)
            for i in story.levels.indices { out.append((1.8 + Double(i) * 0.35, .step)) }
            out.append((1.8 + Double(story.levels.count) * 0.35 + 0.2, .score))
        case .icon:
            out.append((0.1, .unlock))
        case .again:
            for s in 0...9 { out.append((Double(s), .count)) }
            if story.festive {
                for k in 0..<6 { out.append((10 + Double(k) * 0.6, .firework)) }
            } else {
                out.append((10, .over))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

/// The waves. The same recipes as the arcade's sound sheet in
/// work/visualizations/yab-wrapped-sounds.
struct WrappedSynth {
    let rate: Double

    private func count(_ seconds: Double) -> Int { Int(rate * seconds) }

    /// A square wave sweeping from one frequency to another.
    func square(_ from: Double, _ to: Double? = nil, _ seconds: Double, duty: Double = 0.5) -> [Float] {
        let n = count(seconds)
        var phase = 0.0
        return (0..<n).map { i in
            let f = to.map { from + ($0 - from) * Double(i) / Double(max(1, n - 1)) } ?? from
            phase += f / rate
            return phase.truncatingRemainder(dividingBy: 1) < duty ? 1 : -1
        }
    }

    func triangle(_ freq: Double, _ seconds: Double) -> [Float] {
        (0..<count(seconds)).map { i in
            let p = (Double(i) * freq / rate).truncatingRemainder(dividingBy: 1)
            return Float(4 * abs(p - 0.5) - 1)
        }
    }

    func noise(_ seconds: Double, seed: UInt64, decay: Double = 0) -> [Float] {
        var x = seed &* 0x9E3779B97F4A7C15 | 1
        return (0..<count(seconds)).map { i in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            let v = Double(x % 20_001) / 10_000 - 1
            return Float(v * (decay > 0 ? exp(-Double(i) / rate * decay) : 1))
        }
    }

    func envelope(_ s: [Float], attack: Double = 0.002, release: Double = 0.05) -> [Float] {
        let a = max(1, count(attack)), r = max(1, count(release)), n = s.count
        return s.enumerated().map { i, v in
            var e: Float = 1
            if i < a { e = Float(i) / Float(a) }
            if i > n - r { e *= Float(n - i) / Float(r) }
            return v * e
        }
    }

    func note(_ semitonesFromA4: Double) -> Double { 440 * pow(2, semitonesFromA4 / 12) }

    /// Notes one after another, square unless `triangle`.
    func line(_ notes: [(Double, Double)], triangle tri: Bool = false) -> [Float] {
        notes.flatMap { f, s in f == 0 ? [Float](repeating: 0, count: count(s)) : envelope(tri ? triangle(f, s) : square(f, nil, s)) }
    }

    func scaled(_ s: [Float], _ k: Float) -> [Float] { s.map { $0 * k } }

    func mix(_ parts: [[Float]]) -> [Float] {
        let n = parts.map(\.count).max() ?? 0
        return (0..<n).map { i in parts.reduce(0) { $0 + (i < $1.count ? $1[i] : 0) } / Float(parts.count) }
    }

    // C5 is 3 semitones over A4.
    private var c5: Double { note(3) }

    func sound(_ sfx: WrappedSfx) -> [Float] {
        switch sfx {
        case .coin: return line([(note(14), 0.07), (note(19), 0.28)])
        case .roll: return scaled(envelope(noise(0.12, seed: 1, decay: 30), attack: 0.001), 0.6)
        case .tick: return scaled(envelope(square(1046, nil, 0.025, duty: 0.25), attack: 0.001, release: 0.015), 0.5)
        case .clear: return line([(c5, 0.07), (note(7), 0.07), (note(10), 0.07), (note(15), 0.22)])
        case .boss: return line(Array(repeating: [(note(-12), 0.14), (note(-6), 0.14)], count: 3).flatMap { $0 })
        case .zap: return scaled(envelope(square(1800, 300, 0.12, duty: 0.3), attack: 0.001, release: 0.04), 0.6)
        case .pop: return scaled(envelope(noise(0.08, seed: 3, decay: 45), attack: 0.001, release: 0.03), 0.7)
        case .step: return scaled(envelope(square(660, nil, 0.018, duty: 0.25), attack: 0.0005, release: 0.01), 0.45)
        case .land:
            let stab = envelope(mix([square(c5, nil, 0.35), square(note(7), nil, 0.35), square(note(10), nil, 0.35)]), release: 0.2)
            let rise = scaled(envelope(square(note(10), note(27), 0.25, duty: 0.25), release: 0.1), 0.5)
            return stab + rise
        case .bar0, .bar1, .bar2, .bar3:
            let i = Double(["bar0", "bar1", "bar2", "bar3"].firstIndex(of: sfx.rawValue) ?? 0)
            return scaled(envelope(square(c5 * pow(2, i * 4 / 12), nil, 0.06, duty: 0.25), attack: 0.001, release: 0.04), 0.5)
        case .dash: return scaled(line([(note(19), 0.05), (note(26), 0.05), (note(31), 0.16)], triangle: true), 0.6)
        case .score: return line([(note(-2), 0.1), (c5, 0.1), (note(7), 0.1), (note(10), 0.18), (0, 0.04), (note(7), 0.08), (note(10), 0.4)])
        case .unlock: return scaled(envelope(square(300, 2400, 0.45), release: 0.1), 0.5)
        case .count: return envelope(triangle(note(0), 0.09), attack: 0.001)
        case .over: return line([(c5, 0.16), (note(-2), 0.16), (note(-5), 0.16), (note(-9), 0.5)], triangle: true)
        case .firework:
            let whistle = scaled(envelope(square(900, 2200, 0.5, duty: 0.1), attack: 0.01), 0.25)
            var crackle = noise(0.6, seed: 7)
            var gate: UInt64 = 9
            for i in crackle.indices {
                gate ^= gate << 13; gate ^= gate >> 7; gate ^= gate << 17
                if gate % 100 < 93 { crackle[i] = 0 }
            }
            return whistle + scaled(envelope(crackle, attack: 0.001, release: 0.3), 0.8)
        }
    }
}
