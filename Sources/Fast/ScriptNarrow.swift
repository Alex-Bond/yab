import Foundation
import JavaScriptCore

/// Extensions' scripts kept to eight bits a character.
///
/// WebKit gives every page process its own copy of each content script, in
/// memory the app process owns for as long as that page process lives: Yab's
/// own footprint grew about 10 MB a tab with the heavy profile's twelve
/// extensions, 781 MB of it in 70 tabs, against 109 MB with the same
/// extensions kept off pages (evals/ram-446-whole, parts.sh). Chrome's
/// browser process grows by nothing of the kind. A script is held in eight
/// bits a character when every character is Latin-1, and in sixteen when a
/// single one isn't: a "…" in a comment doubles it (wkext.swift, 1 MB of
/// script in 4 extensions and 20 pages: 79 MB in the app, 156 MB with the
/// one character). Zotero Connector, AdGuard, Grammarly and Claude ship
/// such scripts, 1.3 MB of a page's 6.4 MB doubled for nothing.
///
/// So a package's scripts have each character past Latin-1 written as its
/// escape, which means the same character in a string, a template, a
/// regular expression, a comment or a name. A script is left as it is when
/// that could change what it does (a line separator, which ends a comment
/// where its escape doesn't; `String.raw`, which sees escapes as typed), or
/// when JavaScriptCore doesn't read the new text as a valid script where it
/// read the old one.
enum ScriptNarrow {
    /// Bigger files are left alone: checking them twice is too slow for an
    /// install, and no content script comes near.
    nonisolated static let largest = 16 << 20

    /// `source` with every character past Latin-1 escaped, nil when it has
    /// none or when escaping could change what it means. A byte order mark
    /// that opens it goes.
    nonisolated static func narrowed(_ source: String) -> String? {
        let scalars = source.unicodeScalars
        guard scalars.contains(where: { $0.value > 0xFF }) else { return nil }
        if scalars.contains(where: { $0.value == 0x2028 || $0.value == 0x2029 }) { return nil }
        if source.contains("String.raw") { return nil }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count + 64)
        var slashes = 0
        var first = true
        for scalar in scalars {
            defer { first = false }
            let value = scalar.value
            if value == 0xFEFF, first { continue }
            guard value > 0xFF else {
                out.append(scalar)
                slashes = scalar == "\\" ? slashes + 1 : 0
                continue
            }
            // `\…` is `…` in a string or a pattern: its escape takes the
            // backslash's place, or it would escape the backslash instead.
            if slashes % 2 == 1 { out.removeLast() }
            slashes = 0
            if value <= 0xFFFF {
                out.append(contentsOf: escape(value).unicodeScalars)
            } else {
                let offset = value - 0x10000
                out.append(contentsOf: (escape(0xD800 + (offset >> 10)) + escape(0xDC00 + (offset & 0x3FF))).unicodeScalars)
            }
        }
        return String(out)
    }

    private nonisolated static func escape(_ unit: UInt32) -> String {
        let hex = String(unit, radix: 16, uppercase: true)
        return "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    /// Whether JavaScriptCore reads `source` as a valid classic script, as
    /// a content script is run.
    nonisolated static func valid(_ source: String, in context: JSGlobalContextRef) -> Bool {
        let script = JSStringCreateWithCFString(source as CFString)
        defer { JSStringRelease(script) }
        var exception: JSValueRef?
        return JSCheckScriptSyntax(context, script, nil, 1, &exception)
    }

    /// `narrowed`, kept only when the old text and the new are both valid
    /// scripts.
    nonisolated static func checked(_ source: String, in context: JSGlobalContextRef) -> String? {
        guard let narrow = narrowed(source), valid(narrow, in: context), valid(source, in: context) else { return nil }
        return narrow
    }

    /// Every script in an extension's folder narrowed where it lies, but
    /// the files named in `except` (Yab's own). Returns how many were.
    @discardableResult
    nonisolated static func narrow(folder: URL, except: Set<String> = []) -> Int {
        let root = folder.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        else { return 0 }
        var context: JSGlobalContextRef?
        defer { if let context { JSGlobalContextRelease(context) } }
        var count = 0
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "js", !except.contains(url.lastPathComponent),
                  url.standardizedFileURL.path.hasPrefix(root),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= largest,
                  let source = try? String(contentsOf: url, encoding: .utf8),
                  source.unicodeScalars.contains(where: { $0.value > 0xFF })
            else { continue }
            if context == nil { context = JSGlobalContextCreate(nil) }
            guard let context, let narrow = checked(source, in: context) else { continue }
            if (try? narrow.write(to: url, atomically: true, encoding: .utf8)) != nil { count += 1 }
        }
        return count
    }
}
