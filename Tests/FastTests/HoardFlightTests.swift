import AppKit
import Testing
@testable import Fast

// A download's flight into the button (Hoard.swift, HoardSkyView).
@MainActor
struct HoardFlightTests {
    @Test func progressAlreadyUnderWayIsShownImmediately() {
        let progress = Progress(totalUnitCount: 1_000)
        progress.completedUnitCount = 250
        var steps: [Hoard.Step] = []
        let observation = Hoard.observeProgress(progress) { steps.append($0) }
        withExtendedLifetime(observation) {
            #expect(steps.last == Hoard.Step(fraction: 0.25, got: 250, total: 1_000))
        }
    }

    @Test func unknownLengthStillShowsReceivedBytesInitially() {
        let progress = Progress(totalUnitCount: -1)
        progress.completedUnitCount = 512
        var steps: [Hoard.Step] = []
        let observation = Hoard.observeProgress(progress) { steps.append($0) }
        withExtendedLifetime(observation) {
            #expect(progress.fractionCompleted == 0)
            #expect(steps.last == Hoard.Step(fraction: nil, got: 512, total: -1))
        }
    }

    /// A file sent without its length (Vercel Blob's Brotli DMG): the
    /// fraction stays 0 throughout, and the bytes must still be heard.
    @Test func unknownLengthKeepsReportingBytes() {
        let progress = Progress(totalUnitCount: -1)
        var steps: [Hoard.Step] = []
        let observation = Hoard.observeProgress(progress) { steps.append($0) }
        withExtendedLifetime(observation) {
            // Past the Gate's 50 ms, as the next chunk would be.
            Thread.sleep(forTimeInterval: 0.06)
            progress.completedUnitCount = 40_000_000
            #expect(steps.last == Hoard.Step(fraction: nil, got: 40_000_000, total: -1))
        }
    }

    @Test func zeroAndFinishedProgressKeepTheirMeaning() {
        let progress = Progress(totalUnitCount: 100)
        var steps: [Hoard.Step] = []
        let observation = Hoard.observeProgress(progress) { steps.append($0) }
        withExtendedLifetime(observation) {
            #expect(steps.last == Hoard.Step(fraction: 0, got: 0, total: 100))
            progress.completedUnitCount = 100
            #expect(steps.last == Hoard.Step(fraction: 1, got: 100, total: 100))
        }
    }

    /// A click point the sky can't place is no flight at all: Core Animation
    /// raises on a position that isn't a number, and 0.0.21 aborted setting
    /// the pill there (crash #23). The download still lands, at once.
    @Test func pointThatIsNotANumberDoesNotFly() throws {
        let sky = HoardSkyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let host = try #require(sky.layer)
        var landed = 0
        sky.fly(from: CGPoint(x: CGFloat.nan, y: 20), name: "report.pdf", to: { CGPoint(x: 10, y: 10) }) { landed += 1 }
        sky.fly(from: CGPoint(x: 20, y: CGFloat.infinity), name: "report.pdf", to: { CGPoint(x: 10, y: 10) }) { landed += 1 }
        #expect(landed == 2)
        #expect(host.sublayers?.isEmpty ?? true)

        var iconLanded: Bool?
        sky.fly(icon: NSImage(size: NSSize(width: 16, height: 16)), from: CGRect(x: CGFloat.nan, y: 0, width: 40, height: 40),
                to: { nil }) { iconLanded = $0 }
        #expect(iconLanded == false)
        #expect(host.sublayers?.isEmpty ?? true)
    }

    /// A number flies: the pill is in the sky until it lands.
    @Test func ordinaryPointFlies() throws {
        let sky = HoardSkyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let host = try #require(sky.layer)
        var landed = false
        sky.fly(from: CGPoint(x: 200, y: 300), name: "report.pdf", to: { nil }) { landed = true }
        #expect(!landed)
        #expect(host.sublayers?.count == 1)
    }

    /// The throw: the arc files flew before 2026-10-30, straight into the
    /// button, never up to the top of the window (owner, 2026-11-01).
    @Test func throwArcsIntoTheButtonWithoutTheTopOfTheWindow() throws {
        let start = CGPoint(x: 500, y: 306), end = CGPoint(x: 30, y: 25)
        let path = HoardSkyView.arc(from: start, to: end)
        #expect(path.currentPoint == end)
        let box = path.boundingBoxOfPath
        // Down to the column's foot it rises a little first, 90 at most.
        #expect(box.maxY <= start.y + 90 && box.maxY > start.y)
        #expect(box.maxY < 450)
        #expect(Hoard.lift + Hoard.arc < 0.7)
    }

    @Test func pointIsFinite() {
        #expect(CGPoint(x: 1, y: 2).isFinite)
        #expect(!CGPoint(x: CGFloat.nan, y: 2).isFinite)
        #expect(!CGPoint(x: 1, y: -CGFloat.infinity).isFinite)
    }
}
