import AppKit
import Darwin
import SwiftUI
import Testing
@testable import Fast

/// The typing capsule growing into the answer (ChatWords.grow), the real
/// view on the test screen: which answers grow, a film of each beat light
/// and dark into the job's folder, and what the growth costs beside an
/// answer only written out.
@MainActor
@Suite(.serialized)
struct ChatGrowthTests {
    static let answer = "Stripe takes 2.9% + 30\u{00A2} a card charge in the US. Volume pricing starts at $100k a month; Billing adds 0.7%.\n\n"
        + "Custom rates are worked out with their sales team once you pass that, and they ask for a year's volume first."
    static let short = "Yes, it's free."

    @Test func growsOnlyIntoWords() {
        #expect(ChatWords.opensSaid(Self.answer))
        #expect(ChatWords.opensSaid(Self.short))
        #expect(!ChatWords.opensSaid("| Shop | Price |\n|---|---|\n| B&H | $195 |"))
        #expect(!ChatWords.opensSaid("```\nyab open\n```"))
        // Its first message, as the whole answer will have it.
        #expect(ChatWords.first(Self.answer) == [.words("Stripe takes 2.9% + 30\u{00A2} a card charge in the US. Volume pricing starts at $100k a month; Billing adds 0.7%.")])
    }

    /// Frames at 0, 50, 100, 150, 200, 300 ms and on to written out, as
    /// the screen showed them (presentation layers), light and dark.
    @Test(.enabled("no test screen; the built-in one is off-limits") { await TestScreen.available })
    func film() async throws {
        guard let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] else { return }
        let folder = URL(fileURLWithPath: out)
        for dark in [false, true] {
            for (name, text) in [("answer", Self.answer), ("short", Self.short)] {
                let host = Host(text: text, grow: true, dark: dark)
                var at = 0.0
                for time in [0.0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.6, 1.2, 2.2] {
                    await Self.wait(time - at)
                    at = time
                    let file = folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light")-\(Int(time * 1000)).png")
                    try #require(host.picture()).write(to: file)
                }
                host.close()
            }
        }
    }

    /// The process's CPU while an answer comes in, grown from the capsule
    /// or only written out, five times each, alternating.
    @Test(.enabled("no test screen; the built-in one is off-limits") { await TestScreen.available })
    func cost() async throws {
        var grown: [Double] = [], plain: [Double] = []
        for round in 0..<10 {
            let grow = round % 2 == 0
            let start = Self.cpu()
            let host = Host(text: Self.answer, grow: grow, dark: false)
            await Self.wait(2)
            let spent = Self.cpu() - start
            host.close()
            if grow { grown.append(spent) } else { plain.append(spent) }
            await Self.wait(0.3)
        }
        func median(_ all: [Double]) -> Double { all.sorted()[all.count / 2] }
        let line = String(format: "chat growth cpu ms over 2 s: grown %.0f (%@), written out only %.0f (%@)",
                          median(grown) * 1000, grown.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " "),
                          median(plain) * 1000, plain.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " "))
        print(line)
        if let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] {
            try line.write(to: URL(fileURLWithPath: out).appendingPathComponent("cost.txt"), atomically: true, encoding: .utf8)
        }
        #expect(median(grown) < median(plain) * 1.5 + 0.02)
    }

    /// A column's width of turns, an answer just come in its foot.
    @MainActor final class Host {
        let window: NSWindow
        let view: NSHostingView<AnyView>

        init(text: String, grow: Bool, dark: Bool) {
            let content = VStack(alignment: .leading, spacing: 6) {
                ChatWords(text: text, streaming: false, fresh: true, bubbles: true, grow: grow)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: 380, height: 220, alignment: .topLeading)
            .background(Palette.ground)
            view = NSHostingView(rootView: AnyView(content))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            if let screen = TestScreen.screen {
                let visible = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: visible.minX + 48, y: visible.maxY - 268))
            }
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }

        /// What is on screen now, at 2x: the presentation layers, so an
        /// animation shows where it has got to.
        func picture() -> Data? {
            guard let layer = view.layer else { return nil }
            let size = view.bounds.size
            guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            // render(in:) draws with y up from the foot; a PNG reads down from the top.
            context.translateBy(x: 0, y: size.height * 2)
            context.scaleBy(x: 2, y: -2)
            (layer.presentation() ?? layer).render(in: context)
            guard let image = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }

        func close() { window.close() }
    }

    /// Time passing with the main actor free, so the view's animations
    /// run and nothing of the test's own spins the CPU.
    static func wait(_ seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// User and system CPU of this process so far, in seconds.
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
