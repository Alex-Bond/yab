// What hidden pages cost WebKit at idle, outside Yab: N web views out of
// any window (as Yab's hidden tabs are), each on a page with a 1 s timer, a
// 15 s fetch and a heavy DOM, and their content processes' CPU, wakeups and
// footprint counted in windows over time, for a WebKit setting at a time.
//
//   swiftc -O evals/memory/wkidle.swift -o /tmp/wkidle
//   /tmp/wkidle --pages 20 --policy none|throttle|suspend [--auto] [--minutes 12] [--url http://…/app/]
//
// Prints one JSON line per window: {"t": seconds hidden, "cpu_pct", "wakes_s", "mb", "procs"}.
import AppKit
import WebKit

let args = CommandLine.arguments
func value(_ name: String, _ fallback: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return fallback
}
let count = Int(value("--pages", "20"))!
let policy = value("--policy", "none")
let auto = args.contains("--auto")
let minutes = Double(value("--minutes", "12"))!
let base = value("--url", "")
let sites = Int(value("--sites", "0"))!
let limit = Int(value("--limit", "0"))!

typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
func set(_ object: AnyObject, _ name: String, _ on: Bool) {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { print("no \(name)"); return }
    unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, on)
}

let page = """
<!doctype html><meta charset=utf-8><title>App</title><body><h1>App</h1><p id=clock></p><ul id=feed></ul>
<script>
window.heap = Array.from({length: 60000}, (_, i) => ({i, s: 'item ' + i}));
const feed = document.getElementById('feed');
for (let i = 0; i < 300; i++) { const li = document.createElement('li'); li.textContent = 'row ' + i; feed.appendChild(li); }
setInterval(() => { document.getElementById('clock').textContent = new Date().toISOString();
  feed.children[(Math.random() * 300) | 0].textContent = Math.random().toFixed(5); }, 1000);
</script>
"""

struct Usage { var cpu: Double; var wakes: UInt64; var mb: Double }
func usage(_ pid: Int32) -> Usage? {
    var info = rusage_info_v2()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    guard ok == 0 else { return nil }
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    let cpu = Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom) / 1e9
    return Usage(cpu: cpu, wakes: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups, mb: Double(info.ri_phys_footprint) / 1048576)
}
func pids() -> [Int32] {
    let selector = NSSelectorFromString("_webContentProcessInfo")
    guard let list = WKProcessPool.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return [] }
    var out = list.compactMap { ($0.value(forKey: "pid") as? NSNumber)?.int32Value }
    if args.contains("--family") { out += helpers() }
    return out
}

/// --family: WebKit's GPU and network processes this one is responsible for, too.
typealias Responsible = @convention(c) (Int32) -> Int32
let responsible = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid"), to: Responsible.self)
func helpers() -> [Int32] {
    var buffer = [Int32](repeating: 0, count: 8192)
    let n = proc_listallpids(&buffer, Int32(buffer.count * 4))
    let me = getpid()
    return buffer.prefix(Int(max(0, n))).filter { pid in
        guard pid > 0, pid != me, responsible(pid) == me else { return false }
        var path = [CChar](repeating: 0, count: 4096)
        proc_pidpath(pid, &path, 4096)
        let name = String(cString: path)
        return name.contains("WebKit.GPU") || name.contains("WebKit.Networking")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if limit > 0 { typealias SetLimit = @convention(c) (AnyObject, Selector, UInt) -> Void; let s = NSSelectorFromString("_setWebProcessCountLimit:"); unsafeBitCast(WKProcessPool.method(for: s), to: SetLimit.self)(WKProcessPool.self, s, UInt(limit)) }
let pool = WKProcessPool()
var views: [WKWebView] = []
let store = WKWebsiteDataStore.nonPersistent()
for i in 0..<count {
    let config = WKWebViewConfiguration()
    config.processPool = pool
    config.websiteDataStore = store
    config.preferences.inactiveSchedulingPolicy = policy == "suspend" ? .suspend : policy == "throttle" ? .throttle : .none
    if auto { set(config.preferences, "_setHiddenPageDOMTimerThrottlingAutoIncreases:", true) }
    if args.contains("--no-page-cache") { set(config.preferences, "_setUsesPageCache:", false) }
    // --no-hidden-autoplay: a video out of sight doesn't autoplay.
    if args.contains("--no-hidden-autoplay") { set(config, "_setInvisibleAutoplayNotPermitted:", true) }
    // --inject a.js,b.js: these scripts in every page, in a world of their
    // own, as Yab's page scripts are: what they cost a page.
    for path in value("--inject", "").split(separator: ",") {
        if let source = try? String(contentsOfFile: String(path), encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                                    forMainFrameOnly: true, in: WKContentWorld.world(name: "yab")))
        }
    }
    // --relate: a page on a site already open goes in that page's process.
    if args.contains("--relate"), sites > 0, i >= sites { config.perform(NSSelectorFromString("_setRelatedWebView:"), with: views[i % sites]) }
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
    if base.isEmpty { view.loadHTMLString(page, baseURL: URL(string: "https://example\(sites > 0 ? i % sites : i).test/")) }
    else { view.load(URLRequest(url: URL(string: base + String(i))!)) }
    views.append(view)
}
let started = Date()
var last: [Int32: Usage] = [:]
var lastAt = Date()
// This process, the host app: what the hidden pages cost it.
var lastSelf: Usage?
func sample() {
    var now: [Int32: Usage] = [:]
    for pid in pids() { if let u = usage(pid) { now[pid] = u } }
    let me = usage(getpid())
    let dt = Date().timeIntervalSince(lastAt)
    defer { lastSelf = me }
    if !last.isEmpty {
        var cpu = 0.0, wakes: UInt64 = 0
        for (pid, u) in now { if let was = last[pid] { cpu += u.cpu - was.cpu; wakes += u.wakes &- was.wakes } }
        let mb = now.values.reduce(0) { $0 + $1.mb }
        let row: [String: Any] = ["t": Int(Date().timeIntervalSince(started)), "policy": policy, "auto": auto, "pages": count,
                                  "cpu_pct": (cpu / dt * 1000).rounded() / 10, "wakes_s": (Double(wakes) / dt * 10).rounded() / 10,
                                  "mb": Int(mb), "procs": now.count, "pids": now.keys.map { Int($0) }.sorted(),
                                  "host_wakes_s": me.flatMap { m in lastSelf.map { (Double(m.wakes &- $0.wakes) / dt * 10).rounded() / 10 } } ?? -1,
                                  "host_cpu_pct": me.flatMap { m in lastSelf.map { ((m.cpu - $0.cpu) / dt * 1000).rounded() / 10 } } ?? -1]
        print(String(data: try! JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
        fflush(stdout)
    }
    last = now
    lastAt = Date()
}
// --hops H: each view goes on to H more pages of its site, 15 s apart
// (each leaves the last in WebKit's back/forward cache). --clear-at T:
// every view's back/forward cache emptied T seconds in.
let hops = Int(value("--hops", "0"))!
let clearAt = Double(value("--clear-at", "0"))!
for k in 0..<hops {
    Timer.scheduledTimer(withTimeInterval: 15 * Double(k + 1), repeats: false) { _ in
        for (i, view) in views.enumerated() {
            if base.isEmpty { view.loadHTMLString(page + "<p>hop \(k)", baseURL: URL(string: "https://example\(sites > 0 ? i % sites : i).test/h\(k)")) }
            else { view.load(URLRequest(url: URL(string: base + String(i) + "?hop=\(k)")!)) }
        }
    }
}
// --gc-at T: a full JavaScript garbage collection in every page process T s in.
let gcAt = Double(value("--gc-at", "0"))!
if gcAt > 0 {
    Timer.scheduledTimer(withTimeInterval: gcAt, repeats: false) { _ in
        pool.perform(NSSelectorFromString("_garbageCollectJavaScriptObjectsForTesting"))
        print("{\"gc\": \(Int(Date().timeIntervalSince(started)))}")
    }
}
// --purge-at T: the store's in-memory cache emptied in every process T s in.
let purgeAt = Double(value("--purge-at", "0"))!
if purgeAt > 0 {
    Timer.scheduledTimer(withTimeInterval: purgeAt, repeats: false) { _ in
        store.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) {
            print("{\"purged\": \(Int(Date().timeIntervalSince(started)))}")
        }
    }
}
if clearAt > 0 {
    Timer.scheduledTimer(withTimeInterval: clearAt, repeats: false) { _ in
        let selector = NSSelectorFromString("_clearBackForwardCache")
        for view in views where view.responds(to: selector) { view.perform(selector) }
        print("{\"cleared\": \(Int(Date().timeIntervalSince(started)))}")
    }
}
Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
    sample()
    if Date().timeIntervalSince(started) > minutes * 60 { exit(0) }
}
app.run()
