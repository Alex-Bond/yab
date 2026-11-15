import CoreGraphics
import QuartzCore
import Foundation
import Testing
import SyncKit
@testable import Fast

// The step marks (StepMarks.swift): Codex's curves solved right, keyframes
// held and eased between, Central's path data read, and every mark's frames
// drawn with the same shape of path from one frame to the next, which is
// what lets Core Animation ease between them.

@MainActor
struct StepMarksTests {
    /// How many points and curves a path is made of, by kind.
    static func shape(_ path: CGPath) -> [Int32] {
        var kinds: [Int32] = []
        path.applyWithBlock { kinds.append($0.pointee.type.rawValue) }
        return kinds
    }

    @Test func curvesStartAndEndInPlace() {
        for curve in [StepCurve.both, .out, .inward, .tick, .even, .flipIn, .flipOut, .lift, .soft, .settle] {
            #expect(curve(0) == 0 && curve(1) == 1)
            var last = 0.0
            for step in 1...20 {
                let value = curve(Double(step) / 20)
                #expect(value >= last - 1e-9, "a curve went back")
                last = value
            }
        }
        // Out hard: most of the way in the first half.
        #expect(StepCurve.out(0.5) > 0.75)
        // In hard: little of the way in the first half.
        #expect(StepCurve.inward(0.5) < 0.3)
    }

    @Test func keysAreHeldAndEasedBetween() {
        let keys: [(Double, Double, StepCurve?)] = [(0, 0, nil), (10, 100, nil), (20, 50, nil)]
        #expect(stepKey(-5, keys) == 0)
        #expect(stepKey(5, keys) == 50)
        #expect(stepKey(10, keys) == 100)
        #expect(stepKey(15, keys) == 75)
        #expect(stepKey(40, keys) == 50)
    }

    @Test func centralsPathDataIsRead() {
        let lens = StepPaths.parse("M11 18C14.866 18 18 14.866 18 11C18 7.13401 14.866 4 11 4C7.13401 4 4 7.13401 4 11C4 14.866 7.13401 18 11 18Z")
        let box = lens.boundingBoxOfPath
        #expect(abs(box.minX - 4) < 0.01 && abs(box.maxX - 18) < 0.01 && abs(box.minY - 4) < 0.01 && abs(box.maxY - 18) < 0.01)
        let steps = StepPaths.parse("M3 5V9H7M12 12L15 15")
        #expect(steps.boundingBoxOfPath.equalTo(CGRect(x: 3, y: 5, width: 12, height: 10)))
        let relative = StepPaths.parse("m2 2l2 0v2h-2z")
        #expect(relative.boundingBoxOfPath.equalTo(CGRect(x: 2, y: 2, width: 2, height: 2)))
    }

    @Test func everyMarkKeepsItsShapeFromFrameToFrame() {
        for art in StepArt.allCases {
            let rest = art.draw(art.rest)
            #expect(!rest.isEmpty, "\(art) draws nothing")
            let shapes = rest.map { Self.shape($0.path) }
            for frame in stride(from: 0.0, through: art.frames, by: 1) {
                let drawn = art.draw(frame)
                #expect(drawn.count == rest.count, "\(art) has \(drawn.count) strokes at \(frame)")
                for (i, stroke) in drawn.enumerated() where i < shapes.count {
                    #expect(Self.shape(stroke.path) == shapes[i], "\(art) stroke \(i) changes shape at frame \(frame)")
                }
            }
        }
    }

    @Test func aGestureEndsWhereItStarted() {
        for art in StepArt.allCases where !art.once && ![StepArt.readFile, .command, .wait].contains(art) {
            let start = art.draw(0), end = art.draw(art.frames)
            for (a, b) in zip(start, end) {
                let da = a.path.boundingBoxOfPath, db = b.path.boundingBoxOfPath
                #expect(abs(da.minX - db.minX) < 0.01 && abs(da.maxY - db.maxY) < 0.01, "\(art) doesn't come back to rest")
                #expect(abs(a.opacity - b.opacity) < 0.01, "\(art) doesn't come back to rest")
            }
        }
    }

    @Test func theLensTurnsEdgeOnAlongItsHandle() {
        let rest = StepArt.search.draw(0)[0].path.boundingBoxOfPath
        let edge = StepArt.search.draw(10.256)[0].path.boundingBoxOfPath
        // Turned on its 45° axis the lens narrows to a line along the
        // handle, from its top left to its bottom right: still as long.
        #expect(abs(rest.width - 14) < 0.1)
        #expect(edge.width > 9 && edge.width < 11)
        #expect(abs(edge.midX - 11) < 0.01 && abs(edge.midY - 11) < 0.01)
    }

    @Test func aTickRestsWritten() {
        #expect(StepArt.done.rest == StepArt.done.frames)
        #expect(StepArt.done.draw(StepArt.done.rest)[0].opacity == 1)
        #expect(StepArt.done.draw(0)[0].opacity == 0)
        #expect(StepArt.hand.once && StepArt.fail.once && !StepArt.search.once)
    }

    @Test func aMarkSitsInTheMiddleOfItsBox() {
        // The grid's middle lands on the box's, whatever the box: a mark
        // centered on its words' line, its left edge where the column's is.
        for side in [CGFloat(14), 16] {
            let canvas = CALayer()
            canvas.frame = CGRect(x: 0, y: 0, width: side, height: side)
            canvas.isGeometryFlipped = true
            canvas.sublayerTransform = StepMarkView.grid(side, in: canvas.bounds.size)
            let art = CALayer()
            art.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
            canvas.addSublayer(art)
            let middle = canvas.convert(CGPoint(x: 12, y: 12), from: art)
            #expect(abs(middle.x - side / 2) < 0.01 && abs(middle.y - side / 2) < 0.01, "a \(side) pt mark sits at \(middle)")
            // A little over its box, as a Symbol's art is.
            let corner = canvas.convert(CGPoint(x: 0, y: 0), from: art)
            #expect(abs(corner.x + side * 0.05) < 0.01)
        }
    }

    @Test func eachKindIsSampledOnce() {
        let first = StepArt.folder.frames60
        #expect(first.paths.count == StepArt.folder.draw(0).count)
        #expect(first.paths[0].count == Int(StepArt.folder.frames) + 1)
        #expect(first.moves.contains(true))
    }
}
