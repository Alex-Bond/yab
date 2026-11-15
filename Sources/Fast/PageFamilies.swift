import Darwin
import WebKit

/// Settings › Websites › Fonts as the engines' own font settings, the ones
/// Chrome's Customize fonts and WebKit's preferences hold: the default face,
/// serif, sans-serif and monospace. A page that asks for sans-serif, or says
/// nothing, gets the face chosen with no script looking at its elements:
/// before, a MutationObserver read every added element's computed family in
/// every frame and cost 14% of Speedometer (#1889). The page's sheet
/// (PageFonts.css) still names the faces for the page, form controls and code.
enum PageFamilies {
    struct Names: Equatable, Sendable {
        var standard = "", serif = "", sans = "", fixed = ""
        /// The size of text set in the generic monospace family, nil for the
        /// engine's own (13 px).
        var fixedSize: Int?
        var all: [String] { [standard, serif, sans, fixed] }
    }

    /// The default size of both engines, the one `medium` is.
    static let defaultSize = 16

    /// The default face is the standard one, or serif's when only that is
    /// chosen, as the sheet's html and body rule has it. With a fixed-width
    /// face chosen, text asking for monospace keeps the default size: the
    /// engines draw the generic family smaller (13 px), and the script that
    /// named the face on such text before took it out of that rule.
    static func names(_ fonts: PageFonts) -> Names {
        Names(standard: fonts.standard.isEmpty ? fonts.serif : fonts.standard,
              serif: fonts.serif, sans: fonts.sans, fixed: fonts.fixed,
              fixedSize: fonts.fixed.isEmpty ? nil : defaultSize)
    }

    // WKPreferences sets only the default and fixed faces; WebKit's C API has
    // all four. In a Cocoa build a WKPreferencesRef is the WKPreferences object
    // itself (API::Object::wrap gives the wrapper), so the object goes to both.
    private typealias Copy = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    private typealias Put = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias Make = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
    private typealias Text = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer) -> Unmanaged<CFString>?
    private typealias Release = @convention(c) (UnsafeRawPointer) -> Void
    private typealias GetSize = @convention(c) (UnsafeRawPointer) -> UInt32
    private typealias PutSize = @convention(c) (UnsafeRawPointer, UInt32) -> Void

    // C function pointers and nothing else.
    private struct Calls: @unchecked Sendable {
        let copy: [Copy], put: [Put], make: Make, text: Text, release: Release
        let fixedSize: GetSize?, putFixedSize: PutSize?
    }

    private static let calls: Calls? = {
        // RTLD_DEFAULT: WebKit is already loaded.
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)
        func find<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(everywhere, name).map { unsafeBitCast($0, to: type) }
        }
        let kinds = ["Standard", "Serif", "SansSerif", "Fixed"]
        let copy = kinds.compactMap { find("WKPreferencesCopy\($0)FontFamily", Copy.self) }
        let put = kinds.compactMap { find("WKPreferencesSet\($0)FontFamily", Put.self) }
        guard copy.count == kinds.count, put.count == kinds.count,
              let make = find("WKStringCreateWithUTF8CString", Make.self),
              let text = find("WKStringCopyCFString", Text.self),
              let release = find("WKRelease", Release.self) else { return nil }
        return Calls(copy: copy, put: put, make: make, text: text, release: release,
                     fixedSize: find("WKPreferencesGetDefaultFixedFontSize", GetSize.self),
                     putFixedSize: find("WKPreferencesSetDefaultFixedFontSize", PutSize.self))
    }()

    /// WebKit's own faces, read from preferences nobody has changed, for a
    /// family whose name is taken away again.
    @MainActor private static let defaults: [String]? = {
        guard let calls else { return nil }
        let fresh = WKPreferences()
        return calls.copy.map { read(fresh, $0, calls) ?? "" }
    }()

    /// WebKit's own size for the generic monospace family.
    @MainActor private static let defaultFixedSize: UInt32? = {
        guard let size = calls?.fixedSize else { return nil }
        // Held for the call: a temporary passed unretained is freed before it.
        let fresh = WKPreferences()
        return withExtendedLifetime(fresh) { size(UnsafeRawPointer(Unmanaged.passUnretained(fresh).toOpaque())) }
    }()

    @MainActor private static func read(_ preferences: WKPreferences, _ copy: Copy, _ calls: Calls) -> String? {
        guard let string = copy(UnsafeRawPointer(Unmanaged.passUnretained(preferences).toOpaque())) else { return nil }
        defer { calls.release(string) }
        guard let text = calls.text(nil, string)?.takeRetainedValue() else { return nil }
        return text as String
    }

    /// The chosen faces on these preferences, each only where it differs:
    /// WebKit restyles every page using them when one changes.
    @MainActor static func apply(_ fonts: PageFonts, to preferences: WKPreferences) {
        guard let calls, let defaults else { return }
        let object = UnsafeRawPointer(Unmanaged.passUnretained(preferences).toOpaque())
        for (index, name) in names(fonts).all.enumerated() {
            let value = name.isEmpty ? defaults[index] : name
            guard !value.isEmpty, read(preferences, calls.copy[index], calls) != value,
                  let string = value.withCString({ calls.make($0) }) else { continue }
            calls.put[index](object, string)
            calls.release(string)
        }
        if let size = calls.fixedSize, let putSize = calls.putFixedSize,
           let fixed = names(fonts).fixedSize.map(UInt32.init) ?? defaultFixedSize, size(object) != fixed {
            putSize(object, fixed)
        }
    }

    /// What these preferences hold, standard, serif, sans-serif and fixed,
    /// for the tests.
    @MainActor static func current(_ preferences: WKPreferences) -> [String] {
        guard let calls else { return [] }
        return calls.copy.map { read(preferences, $0, calls) ?? "" }
    }

    /// The size these preferences give the generic monospace family, for the tests.
    @MainActor static func fixedSize(_ preferences: WKPreferences) -> Int? {
        guard let size = calls?.fixedSize else { return nil }
        return Int(size(UnsafeRawPointer(Unmanaged.passUnretained(preferences).toOpaque())))
    }
}
