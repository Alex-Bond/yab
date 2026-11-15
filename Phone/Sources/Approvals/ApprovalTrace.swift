import QuartzCore
import UIKit

/// Every frame of the approval tray, as its views draw it, written for the
/// motion tests to check (UITests/ApprovalMotionTests.swift): each piece on
/// screen with its rect and how much of it shows, and the display link's own
/// times, so a jump, a piece that pops in or out, or a dropped frame is
/// found by reading the file. On with YAB_APPROVAL_TRACE=<path> in debug
/// builds; a line a frame while anything of the tray is up:
///
///     {"t":1.2345,"dt":8.3,"phase":"ready","step":"root","pieces":{"tray":[8,512,386,354,1],...}}
@MainActor
final class ApprovalTrace: NSObject {
    static let shared: ApprovalTrace? = {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["YAB_APPROVAL_TRACE"], !path.isEmpty else { return nil }
        return ApprovalTrace(path: path)
        #else
        return nil
        #endif
    }()

    private let path: String
    private var link: CADisplayLink?
    private var lines: [String] = []
    private var started: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var lastCPU: Double = 0
    /// What the tray did since the last frame, for a long frame to say why.
    private var marks: [String] = []

    static func mark(_ what: String) { shared?.marks.append(what) }

    /// The calling (main) thread's user and system time, in seconds.
    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }
    /// What the stage last laid out with.
    var screen: CGSize = .zero
    var safeTop: CGFloat = 0

    private init(path: String) {
        self.path = path
        super.init()
        try? Data().write(to: URL(fileURLWithPath: path))
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        if started == 0 { started = CACurrentMediaTime() }
        last = 0
    }

    @objc private func frame(_ link: CADisplayLink) {
        let tray = ApprovalTray.shared
        guard tray.isUp || tray.request != nil else {
            flush()
            link.invalidate()
            self.link = nil
            return
        }
        let g = ApprovalGeometry(tray: tray, screen: screen, safeTop: safeTop)
        var pieces: [String: [Double]] = [:]
        func put(_ name: String, _ r: CGRect, _ shown: Double) {
            pieces[name] = [r.minX, r.minY, r.width, r.height, shown].map { ($0 * 100).rounded() / 100 }
        }
        if tray.request != nil {
            put("tray", g.trayRect, 1)
            put("dim", .zero, g.dim)
            pieces["behind"] = [Double(g.behindScale)]
            put("bodyIn", g.restRect.offsetBy(dx: 0, dy: g.trayOffset + g.bodyRise), g.bodyIn * g.bodyShown)
            if tray.leaving != nil { put("bodyOut", g.restRect.offsetBy(dx: 0, dy: g.trayOffset), g.bodyOut * g.bodyShown) }
        }
        if tray.windowItem != nil {
            put("window", g.windowNow, 1)
            pieces["windowScale"] = [Double(g.windowScale)]
            put("windowWords", g.windowNow, g.windowWords)
            put("windowGround", g.windowNow, g.windowGround)
            if let from = g.windowFromRect { put("ghost", from, g.windowGhost) } else { pieces["ghostMissing"] = [1] }
            pieces["page"] = [Double(tray.page)]
            pieces["scroll"] = [Double(tray.scroll)]
        }
        if let file = tray.pictureFile {
            put("picture", g.pictureNow(fit: ApprovalPicture.fit(file, g)), 1)
            put("pictureBlack", .zero, g.pictureBlack)
            if g.onScreen(tray.pictureKey) == nil { pieces["pictureMissing"] = [1] }
        }
        if tray.receiptWords != nil { pieces["receipt"] = [tray.receiptShown] }
        let now = link.timestamp
        let dt = last == 0 ? 0 : (now - last) * 1000
        last = now
        let expected = (link.targetTimestamp - link.timestamp) * 1000
        pieces["screen"] = [Double(screen.width), Double(screen.height)]
        if tray.fingerDown { pieces["finger"] = [1] }
        // The main thread's own CPU time since the last frame: a long frame
        // with little of it is the Mac not running us, not our work.
        let cpu = Self.mainThreadCPU()
        let busy = lastCPU == 0 ? 0 : (cpu - lastCPU) * 1000
        lastCPU = cpu
        let line: [String: Any] = [
            "t": ((now - started) * 10000).rounded() / 10000, "dt": (dt * 100).rounded() / 100, "frame": (expected * 100).rounded() / 100,
            "cpu": (busy * 100).rounded() / 100, "marks": marks,
            "phase": "\(tray.phase)", "step": "\(tray.step)", "pieces": pieces,
        ]
        marks = []
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            lines.append(text)
        }
        if lines.count >= 120 { flush() }
    }

    func flush() {
        guard !lines.isEmpty, let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try? handle.close()
        lines = []
    }
}
