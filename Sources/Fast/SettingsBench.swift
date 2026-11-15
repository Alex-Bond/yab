import AppKit

// ./bench scroll: Settings' page scrolled to its foot and back a few points
// every frame, the way a trackpad moves it, timed frame by frame, with the
// main thread's own CPU for the whole of it. For a page with many rows,
// Shortcuts, Search, to be seen to scroll without a hitch.

extension Bench {
    func settingsScroll(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "scroll only works on a --test run"]); return }
        guard let window = SettingsWindow.shared.window, let view = window.contentView,
              let scroller = Self.largestScroll(in: view) else { answer(["error": "open Settings first"]); return }
        // "sidebar": where the pages' list stands under the search.
        if request["sidebar"] as? Bool == true {
            answer(Self.sidebarPlace(window))
            return
        }
        // "hit": what the page has at a point of the screen, inside out.
        if let x = request["hitX"] as? Double, let y = request["hitY"] as? Double, let frame = view.superview {
            let screen = NSPoint(x: x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - y)
            let point = frame.convert(window.convertPoint(fromScreen: screen), from: nil)
            var chain: [String] = []
            var hit = frame.hitTest(point)
            while let found = hit, chain.count < 8 {
                chain.append(String(describing: type(of: found)))
                hit = found.superview
            }
            answer(["chain": chain])
            return
        }
        let clip = scroller.contentView
        // "go": a page, as the sidebar opens it; "travel": back (-1) or forward (1).
        if let page = (request["go"] as? String).flatMap(SettingsPage.init) {
            // "timed": the longest the main thread stood still over it.
            let longest = request["timed"] as? Bool == true ? Longest() : nil
            let meter = longest == nil ? nil : Busy()
            SettingsWindow.shared.benchGo(page)
            guard let longest, let meter else { answer(["page": page.rawValue]); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                answer(["page": page.rawValue, "longest_ms": (longest.stop() * 10).rounded() / 10,
                        "busy_ms": (meter.stop() * 10).rounded() / 10])
            }
            return
        }
        if let step = request["travel"] as? Int {
            SettingsWindow.shared.benchTravel(step)
            // Where the page is before a frame has gone by: back comes back
            // to where it was at once, not a beat later.
            answer(["travel": step, "y": Double(SettingsWindow.shared.pageScrolled ?? -1)])
            return
        }
        // "where": how far down the page is now, moving nothing. The page's
        // own scroll, the widest one: the sidebar's list can be the longer.
        if request["where"] as? Bool == true {
            guard let page = Self.widestScroll(in: view) else { answer(["error": "no page scroll"]); return }
            answer(["y": page.contentView.bounds.minY + page.contentInsets.top,
                    "height": page.documentView?.frame.height ?? 0])
            return
        }
        // "to": the page put that many points down and left there.
        if let y = request["to"] as? Double {
            let scroller = Self.widestScroll(in: view) ?? scroller
            let clip = scroller.contentView
            // No further than the page's foot, the way a trackpad stops there.
            let foot = max(0, (scroller.documentView?.frame.height ?? 0) - clip.bounds.height
                           + scroller.contentInsets.top + scroller.contentInsets.bottom)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(CGFloat(y), foot) - scroller.contentInsets.top))
            scroller.reflectScrolledClipView(clip)
            answer(["y": clip.bounds.minY + scroller.contentInsets.top])
            return
        }
        let step = request["step"] as? Double ?? 14
        let bottom = max(0, (scroller.documentView?.frame.height ?? 0) - clip.bounds.height)
        let pacer = ScrollPacer(clip: clip, scroller: scroller, bottom: bottom, step: step)
        let link = view.displayLink(target: pacer, selector: #selector(ScrollPacer.tick(_:)))
        let c0 = Self.mainCPU()
        let i0 = Self.instructions()
        let meter = Busy()
        link.add(to: .main, forMode: .common)
        pacer.done = {
            link.invalidate()
            let gaps = zip(pacer.times.dropFirst(), pacer.times).map { ($0 - $1) * 1000 }
            let frame = pacer.frame * 1000
            let sorted = gaps.sorted()
            answer([
                "frames": gaps.count,
                "height": (bottom * 10).rounded() / 10,
                "refresh_ms": (frame * 10).rounded() / 10,
                "median_ms": sorted.isEmpty ? 0 : (sorted[sorted.count / 2] * 10).rounded() / 10,
                "worst_ms": ((gaps.max() ?? 0) * 10).rounded() / 10,
                "dropped": gaps.filter { $0 > frame * 1.5 }.count,
                "cpu_ms": ((Self.mainCPU() - c0) * 10).rounded() / 10,
                "cpu_ms_per_frame": gaps.isEmpty ? 0 : ((Self.mainCPU() - c0) / Double(gaps.count) * 100).rounded() / 100,
                "minstr_per_frame": gaps.isEmpty ? 0 : ((Self.instructions() - i0) / Double(gaps.count) * 100).rounded() / 100,
                "busy_ms": (meter.stop() * 10).rounded() / 10,
            ])
        }
    }

    func settingsPace(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "settingspace only works on a --test run"]); return }
        guard let view = SettingsWindow.shared.window?.contentView else { answer(["error": "open Settings first"]); return }
        let seconds = request["seconds"] as? Double ?? 1
        let pacer = Pacer()
        let link = view.displayLink(target: pacer, selector: #selector(Pacer.tick(_:)))
        let c0 = Self.mainCPU()
        let meter = Busy()
        link.add(to: .main, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            link.invalidate()
            let gaps = zip(pacer.times.dropFirst(), pacer.times).map { ($0 - $1) * 1000 }
            let frame = pacer.frame * 1000
            let sorted = gaps.sorted()
            answer([
                "frames": gaps.count,
                "refresh_ms": (frame * 10).rounded() / 10,
                "median_ms": sorted.isEmpty ? 0 : (sorted[sorted.count / 2] * 10).rounded() / 10,
                "worst_ms": ((gaps.max() ?? 0) * 10).rounded() / 10,
                "dropped": gaps.filter { $0 > frame * 1.5 }.count,
                "cpu_ms": ((Self.mainCPU() - c0) * 10).rounded() / 10,
                "busy_ms": (meter.stop() * 10).rounded() / 10,
            ])
        }
    }

    private static func sidebarPlace(_ window: NSWindow) -> [String: Any] {
        var table: NSTableView?
        var search: NSTextField?
        func walk(_ view: NSView) {
            if let view = view as? NSTableView, view.accessibilityLabel() == SettingsWords.text("Settings pages") { table = view }
            if let view = view as? NSTextField, view.isEditable, view.placeholderString == SettingsWords.text("Search") { search = view }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        guard let table, let scroll = table.enclosingScrollView, let search else { return ["error": "no sidebar"] }
        let height = window.frame.height
        let row = table.convert(table.rect(ofRow: 0), to: nil)
        let field = search.convert(search.bounds, to: nil)
        let frame = scroll.convert(scroll.bounds, to: nil)
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.maxY
        return [
            "x": window.frame.minX,
            "y": top,
            "width": window.frame.width,
            "window": height,
            "firstRow": height - row.maxY,
            "searchFoot": height - field.minY,
            "gap": field.minY - row.maxY,
            "inset": scroll.contentView.contentInsets.top,
            "clipY": scroll.contentView.bounds.minY,
            "listTop": height - frame.maxY,
            "listHeight": frame.height,
            "tableHeight": table.frame.height,
            "tableY": table.frame.minY,
            "clipTop": scroll.contentView.frame.minY,
            "clipHeight": scroll.contentView.frame.height,
            "safeTop": search.safeAreaInsets.top,
            "rootSafeTop": window.contentView?.safeAreaInsets.top ?? -1,
        ]
    }

    private static func widestScroll(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor,
               scroll.frame.width > (best?.frame.width ?? 0) { best = scroll }
            view.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    private static func largestScroll(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = scroll }
            view.subviews.forEach(walk)
        }
        walk(view)
        return best
    }
}

/// Moves the page a step each frame, down to its foot and back to the top.
final class ScrollPacer: NSObject {
    let clip: NSClipView
    let scroller: NSScrollView
    let bottom: CGFloat
    let step: CGFloat
    var times: [CFTimeInterval] = []
    var frame: CFTimeInterval = 1.0 / 60
    var down = true
    var done: (() -> Void)?

    init(clip: NSClipView, scroller: NSScrollView, bottom: CGFloat, step: CGFloat) {
        self.clip = clip
        self.scroller = scroller
        self.bottom = bottom
        self.step = step
        clip.scroll(to: .zero)
    }

    @objc func tick(_ link: CADisplayLink) {
        times.append(link.timestamp)
        frame = link.targetTimestamp - link.timestamp
        var y = clip.bounds.origin.y + (down ? step : -step)
        if y >= bottom { y = bottom; down = false }
        if y <= 0, !down {
            clip.scroll(to: .zero)
            scroller.reflectScrolledClipView(clip)
            done?()
            done = nil
            return
        }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroller.reflectScrolledClipView(clip)
    }
}

/// How long the main run loop is kept from waiting, pass by pass, from now
/// until `stop`: the time it could not have answered a key or drawn a
/// frame, whatever it was doing. Unlike the thread's CPU time, a pass spent
/// waiting on the window server counts, and time spent asleep doesn't.
final class Busy {
    private var total: CFTimeInterval = 0
    private var woke = CACurrentMediaTime()
    private var observer: CFRunLoopObserver?

    init() {
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, Int.max) { [unowned self] _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { woke = now } else { total += now - woke }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// In milliseconds.
    func stop() -> Double {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        return total * 1000
    }
}

/// The longest pass of the main run loop from now until `stop`, in ms.
final class Longest {
    private var most: CFTimeInterval = 0
    private var woke = CACurrentMediaTime()
    private var observer: CFRunLoopObserver?

    init() {
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, Int.max) { [unowned self] _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { woke = now } else { most = max(most, now - woke) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() -> Double {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        return most * 1000
    }
}
