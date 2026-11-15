import XCTest

/// The approval tray's every movement made with a real finger, each frame
/// read back from the app's trace (Approvals/ApprovalTrace.swift) and checked:
/// nothing jumps (a piece's speed doesn't spike between two frames), nothing
/// pops in or out (a piece comes and goes invisible, or exactly where its
/// counterpart is: the window over its row, a page over its thumbnail, the
/// tray off screen or shrunk into its head), and no frame is dropped long. Every
/// path a person takes, and the ones taken in the middle of another.
final class ApprovalMotionTests: XCTestCase {
    private var app: XCUIApplication!
    private var trace: URL!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func open(_ state: String, proof: String = "faceID") {
        trace = Atlas.out.appendingPathComponent("approval-trace-\(name.filter { $0.isLetter || $0.isNumber }).jsonl")
        try? FileManager.default.removeItem(at: trace)
        XCTAssertTrue(Atlas.launch(app, state: state, ready: Atlas.readyFolder(), still: false, extra: ["-YabProof", proof],
                                   environment: ["YAB_APPROVAL_TRACE": trace.path]), "\(state) never settled")
        // XCTest reads the app's accessibility tree when it looks for an
        // element, ~50 ms on the main thread: not while the tray rises.
        settle(1.2)
        XCTAssertTrue(element("approval.tray").waitForExistence(timeout: 10), "no tray")
        settle()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func tap(_ id: String, wait: Double = 0) {
        let e = element(id)
        XCTAssertTrue(e.waitForExistence(timeout: 5), "\(id) isn't there")
        e.tap()
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    private func settle(_ seconds: Double = 0.9) { Thread.sleep(forTimeInterval: seconds) }

    private func drag(_ id: String, dx: CGFloat = 0, dy: CGFloat, speed: CGFloat = 600, seconds: Double = 0.25) {
        let e = element(id)
        let start = e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        // A finger's pace (XCUITest's default jumps tens of points a frame).
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)),
                    withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Reads the trace and fails on every jump, pop and long gap in it.
    private func verify(_ label: String = "", file: StaticString = #filePath, line: UInt = #line) {
        settle(1.6)
        let frames = ApprovalTraceCheck.read(trace)
        XCTAssertGreaterThan(frames.count, 20, "\(label): the trace has \(frames.count) frames", file: file, line: line)
        let report = ApprovalTraceCheck.problems(frames)
        let summary = ApprovalTraceCheck.summary(frames)
        print("approval motion \(name) \(label): \(summary)")
        try? (summary + "\n" + report.joined(separator: "\n")).write(to: trace.appendingPathExtension("report.txt"), atomically: true, encoding: .utf8)
        for problem in report.prefix(25) { XCTFail("\(label): \(problem)", file: file, line: line) }
    }

    // MARK: arriving and going

    func testRiseAndSwipeAway() {
        open("approval.pay")
        drag("approval.tray", dy: 420)
        verify("rise, then pulled down: no")
    }

    func testPulledShortSpringsBack() {
        open("approval.mails")
        drag("approval.tray", dy: 60, seconds: 0.8)
        drag("approval.tray", dy: -80, seconds: 0.8)
        tap("approval.no", wait: 0.6)
        verify("pulled short, pushed up, ×")
    }

    // MARK: rows into windows

    func testMailOpensPagesAndFolds() {
        open("approval.mails")
        tap("approval.row.1", wait: 0.9)
        drag("approval.window", dx: -260, dy: 0, speed: 900); settle()
        drag("approval.window", dx: 220, dy: 0, speed: 500); settle()
        drag("approval.window", dy: 260)
        settle()
        verify("row 2 into its window, next, back, pulled down")
    }

    func testFoldIntoAnotherRow() {
        open("approval.mails")
        tap("approval.row.0", wait: 0.9)
        drag("approval.window", dx: -200, dy: 0, speed: 1600); settle(0.7)
        drag("approval.window", dx: -200, dy: 0, speed: 1600); settle(0.7)
        tap("approval.window.fold")
        verify("opened on the first, folded into the third")
    }

    func testFoldInTheMiddleOfOpening() {
        open("approval.mails")
        tap("approval.row.2", wait: 0.12)
        tap("approval.window.fold", wait: 0.1)
        tap("approval.row.1", wait: 0.2)
        drag("approval.window", dy: 300, seconds: 0.1)
        verify("interrupted both ways")
    }

    func testScrollThenPull() {
        open("approval.mail")
        tap("approval.paper", wait: 0.9)
        drag("approval.window", dy: -320, speed: 1400); settle()
        drag("approval.window", dy: 260, speed: 1400); settle()
        drag("approval.window", dy: 300)
        verify("paper into its window, scrolled, back up, folded")
    }

    // MARK: pages full screen

    func testAttachmentFromWindow() {
        open("approval.mails")
        tap("approval.row.2", wait: 0.9)
        tap("approval.attachment.f2", wait: 0.8)
        drag("approval.picture", dy: 280)
        settle()
        tap("approval.window.fold")
        verify("attachment out of the window and back")
    }

    func testFilePageAndUpload() {
        open("approval.files")
        tap("approval.file.f1", wait: 0.8)
        tap("approval.picture.close", wait: 0.8)
        tap("approval.file.f2", wait: 0.2)
        tap("approval.picture.close", wait: 0.8)
        tap("approval.yes")
        verify("pages, then the yes into its head")
    }

    // MARK: steps

    func testPaymentSteps() {
        open("approval.pay")
        tap("approval.card", wait: 0.6)
        tap("approval.card.1", wait: 0.6)
        tap("approval.place", wait: 0.6)
        tap("approval.back", wait: 0.6)
        tap("approval.card", wait: 0.15)
        tap("approval.back", wait: 0.7)
        verify("cards, a pick, addresses, back, interrupted")
    }

    func testAddAddressOverTheKeyboard() {
        open("approval.pay")
        tap("approval.place", wait: 0.6)
        tap("approval.addPlace", wait: 1.0)
        let street = element("approval.form.Street and number")
        street.tap(); street.typeText("1 Main St")
        let city = element("approval.form.City")
        city.tap(); city.typeText("Brooklyn")
        tap("approval.savePlace", wait: 0.9)
        verify("Add Address on the keyboard, saved")
    }

    func testPaidIntoItsHead() {
        open("approval.pay")
        tap("approval.yes")
        settle(3.5)
        verify("paying, paid, into its head")
    }

    func testArchiveMoreStep() {
        open("approval.archive")
        tap("approval.more", wait: 0.7)
        tap("approval.row.6", wait: 0.9)
        drag("approval.window", dy: 300)
        tap("approval.back", wait: 0.7)
        verify("11 more, a mail from the step, back")
    }

    func testNextQuestionRisesAfterTheFirst() {
        open("approval.queue")
        tap("approval.no", wait: 1.6)
        XCTAssertTrue(element("approval.row.0").waitForExistence(timeout: 3), "the mails came next")
        tap("approval.no", wait: 0.6)
        verify("the payment goes, the mails rise, they go")
    }

    func testAddCardThenBackWithTheKeyboard() {
        open("approval.pay")
        tap("approval.card", wait: 0.6)
        tap("approval.addCard", wait: 1.0)
        let number = element("approval.form.Card number")
        number.tap(); number.typeText("4242424242424242")
        tap("approval.back", wait: 0.8)
        tap("approval.back", wait: 0.8)
        verify("Add Card up on the keyboard, back twice, the keyboard down")
    }

    func testTouchIDAndPasscodeMarks() {
        open("approval.message", proof: "touchID")
        tap("approval.yes")
        verify("Touch ID's mark, sent into its head")
    }
}

/// The trace's frames and what is wrong with them.
enum ApprovalTraceCheck {
    struct Frame {
        let t: Double
        let dt: Double
        let expected: Double
        let phase: String
        let step: String
        let pieces: [String: [Double]]
        var cpu: Double = 0
        var marks: [String] = []
    }

    static func read(_ url: URL) -> [Frame] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let pieces = (json["pieces"] as? [String: [Any]] ?? [:]).mapValues { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
            return Frame(t: json["t"] as? Double ?? 0, dt: json["dt"] as? Double ?? 0, expected: json["frame"] as? Double ?? 16.7,
                         phase: json["phase"] as? String ?? "", step: json["step"] as? String ?? "", pieces: pieces,
                         cpu: json["cpu"] as? Double ?? 0, marks: json["marks"] as? [String] ?? [])
        }
    }

    static func summary(_ frames: [Frame]) -> String {
        let moving = zip(frames.dropFirst(), frames).filter { $0.0.pieces != $0.1.pieces }
        let long = moving.filter { $0.0.dt > max(25, $0.0.expected * 2.5) }
        let worst = moving.map(\.0.dt).max() ?? 0
        let ours = long.filter { $0.0.cpu > 0.5 * $0.0.dt }
        let worstCPU = long.map(\.0.cpu).max() ?? 0
        return "\(frames.count) frames, \(moving.count) moving, \(long.count) long (worst \(Int(worst)) ms), \(ours.count) of them busy in the app (most app work in one: \(Int(worstCPU)) ms)"
    }

    static func problems(_ frames: [Frame]) -> [String] {
        var out: [String] = []
        guard frames.count > 2 else { return ["too few frames"] }
        let rectNames = ["tray", "bodyIn", "bodyOut", "window", "ghost", "picture"]
        for i in 1..<frames.count {
            let a = frames[i - 1], b = frames[i]
            let at = String(format: "%.3f s", b.t)
            for missing in ["ghostMissing", "pictureMissing"] where b.pieces[missing] != nil {
                out.append("\(at): \(missing): grows out of a frame that isn't measured")
            }
            // A long frame in the middle of a movement: dropped frames. (A pause
            // before one starts, the keyboard's first load, shows nothing.)
            let wasMoving = i >= 2 && frames[i - 2].pieces != a.pieces
            // Only a gap the app spent working counts: one where the main
            // thread hardly ran is the Mac (a loaded farm host) not running it.
            if wasMoving, a.pieces != b.pieces, b.dt > 100, b.cpu > 0.5 * b.dt {
                out.append("\(at): a \(Int(b.dt)) ms gap while moving, \(Int(b.cpu)) ms of it the app's own work (\(b.phase), \(b.step); the tray did \(b.marks.isEmpty ? "nothing" : b.marks.joined(separator: ", ")))")
            }
            for name in Set(a.pieces.keys).union(b.pieces.keys) {
                let was = a.pieces[name], now = b.pieces[name]
                if was == nil, let now, now.count == 5, now[4] > 0.05, !arrivesInPlace(name, now, a, b) {
                    out.append("\(at): \(name) pops in at \(fmt(now)) (\(b.step))")
                }
                if now == nil, let was, was.count == 5, was[4] > 0.05, !leavesInPlace(name, was, a, b) {
                    out.append("\(at): \(name) pops out from \(fmt(was)) (\(a.step))")
                }
            }
            guard i + 1 < frames.count else { continue }
            let c = frames[i + 1]
            // The display link's first frame after a pause has no time of its own.
            guard b.dt > 0, c.dt > 0, b.dt < 200, c.dt < 200 else { continue }
            // A step begins: the body that was in is now the one going out, and
            // the new one starts unseen; the picture is the same.
            let stepBegins = a.pieces["bodyOut"] == nil && b.pieces["bodyOut"] != nil
            // Under a finger a piece goes where the finger goes; XCUITest's
            // fingers move in steps, so those frames aren't judged here
            // (ApprovalTrayTests checks a drag picks up where it is).
            let finger = a.pieces["finger"] != nil || b.pieces["finger"] != nil || c.pieces["finger"] != nil
            let screenHeight = b.pieces["screen"]?.last ?? 874
            for name in rectNames where !(name == "bodyIn" && stepBegins) && !finger {
                guard let p0 = a.pieces[name], let p1 = b.pieces[name], let p2 = c.pieces[name], p0.count == 5 else { continue }
                // Below the screen it moves where no one sees it.
                if p0[1] >= screenHeight, p1[1] >= screenHeight { continue }
                // What can't be seen can't jump.
                if p0[4] < 0.03, p1[4] < 0.03 { continue }
                // Speeds in points a second, so uneven frames don't read as jumps.
                for k in 0..<4 {
                    let d1 = p1[k] - p0[k], d2 = p2[k] - p1[k]
                    let v1 = d1 / max(1, b.dt) * 1000, v2 = d2 / max(1, c.dt) * 1000
                    let before = i >= 2 ? frames[i - 2].pieces[name].map { (p0[k] - $0[k]) / max(1, a.dt) * 1000 } ?? 0 : 0
                    if abs(d1) > 10, abs(v1) > 3.2 * max(abs(v2), abs(before)) + 400 {
                        out.append("\(at): \(name) jumps \(Int(d1)) pt in one frame (\(["x", "y", "w", "h"][k]); speeds \(Int(before)) → \(Int(v1)) → \(Int(v2)) pt/s)")
                    }
                }
                let o1 = p1[4] - p0[4], o2 = p2[4] - p1[4]
                if abs(o1) > 0.34, abs(o1) > 3 * abs(o2) + 0.1 { out.append("\(at): \(name) opacity jumps \(String(format: "%.2f", p0[4])) → \(String(format: "%.2f", p1[4]))") }
            }
            for name in ["dim", "pictureBlack", "windowGround", "windowWords"] {
                guard let p0 = a.pieces[name]?.last, let p1 = b.pieces[name]?.last, let p2 = c.pieces[name]?.last else { continue }
                if abs(p1 - p0) > 0.34, abs(p1 - p0) > 3 * abs(p2 - p1) + 0.1 {
                    out.append("\(at): \(name) jumps \(String(format: "%.2f", p0)) → \(String(format: "%.2f", p1))")
                }
            }
        }
        return out
    }

    /// A piece may come in shown only where it continues something already
    /// there: the window over its row, a page over its thumbnail, the body
    /// going out as the one that was in, the tray from below the screen.
    private static func arrivesInPlace(_ name: String, _ now: [Double], _ a: Frame, _ b: Frame) -> Bool {
        switch name {
        case "window", "windowWords": return near(now, b.pieces["ghost"]) && (b.pieces["windowGround"]?[4] ?? 1) < 0.2
        case "ghost": return near(now, b.pieces["window"])
        case "windowGround": return now[4] < 0.2
        case "bodyOut": return abs(now[4] - (a.pieces["bodyIn"]?[4] ?? 0)) < 0.05
        case "bodyIn": return a.pieces["tray"] == nil || abs(now[4] - (a.pieces["bodyIn"]?[4] ?? 0)) < 0.05
        case "tray": return now[1] > 700
        case "picture": return (b.pieces["pictureBlack"]?[4] ?? 1) < 0.1
        default: return false
        }
    }

    private static func leavesInPlace(_ name: String, _ was: [Double], _ a: Frame, _ b: Frame) -> Bool {
        switch name {
        case "window", "windowWords", "windowGround": return (a.pieces["ghost"]?[4] ?? 0) > 0.95 && near(was, a.pieces["ghost"])
        case "ghost": return near(was, a.pieces["window"])
        case "bodyOut": return was[4] < 0.05
        case "bodyIn": return a.pieces["tray"]?[1] ?? 0 > 700
        case "tray": return was[1] > 700
        case "picture": return (a.pieces["pictureBlack"]?[4] ?? 1) < 0.05
        default: return false
        }
    }

    private static func near(_ a: [Double], _ b: [Double]?) -> Bool {
        guard let b, a.count >= 4, b.count >= 4 else { return false }
        return (0..<4).allSatisfy { abs(a[$0] - b[$0]) < 1.5 }
    }

    private static func fmt(_ p: [Double]) -> String { p.map { String(format: "%.1f", $0) }.joined(separator: ",") }
}
