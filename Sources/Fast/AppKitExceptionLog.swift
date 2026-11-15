import AppKit
import ObjectiveC

/// AppKit can report an exception and resume its event loop without calling
/// NSSetUncaughtExceptionHandler. Keep its original throw stack as well: a
/// later Swift executor crash only shows where the damaged state was read.
enum AppKitExceptionLog {
    private static let lock = NSLock()
    private static var file: URL?
    private static var installed = false

    @MainActor
    static func install(file: URL) {
        install(file: file, on: type(of: NSApplication.shared))
    }

    // The class parameter lets the isolated native regression exercise the
    // exact hook without changing the test runner's application class.
    @MainActor
    static func install(file: URL, on applicationClass: AnyClass) {
        precondition(Thread.isMainThread)
        guard !installed else { return }
        let selector = #selector(NSApplication.reportException(_:))
        guard let method = class_getInstanceMethod(applicationClass, selector) else { return }
        self.file = file
        typealias Report = @convention(c) (AnyObject, Selector, NSException) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Report.self)
        let hook = reporter(original, selector: selector)
        class_replaceMethod(applicationClass, selector, imp_implementationWithBlock(hook), method_getTypeEncoding(method))
        NSSetUncaughtExceptionHandler { AppKitExceptionLog.record($0) }
        installed = true
    }

    // Deliberately formed outside MainActor isolation. By the time AppKit
    // reports an exception, its unwinding may already have damaged the Swift
    // executor reference. The recorder must not consult that reference.
    private static func reporter(_ original: @escaping @convention(c) (AnyObject, Selector, NSException) -> Void,
                                 selector: Selector) -> @convention(block) (AnyObject, NSException) -> Void {
        { application, exception in
            record(exception)
            original(application, selector, exception)
        }
    }

    static func record(_ exception: NSException) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        let line = "\(Date()): \(exception.name.rawValue): \(exception.reason ?? "?")\n"
            + exception.callStackSymbols.joined(separator: "\n") + "\n\n"
        if let handle = FileHandle(forWritingAtPath: file.path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
