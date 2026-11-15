import AppKit

// One list of extensions, whichever engine draws the page.
//
// A sign-in's list on disk (`Extensions.list(of:)`, installed.json for the
// shared one) says what is installed, in what order, on or off and pinned,
// for both engines, and Store.settings says where each may reach and what it
// was given later. WebKit's `Extensions` owns that list, at rest or running.
// A CEF profile is a copy kept in step with it: ChromiumExtensionSync.swift
// compares the two after any change and does what differs, so an install,
// a removal or a switch anywhere reaches both, and one missed while the helper
// was down is done the next time it is up.
//
// The first time a profile joins, the two lists Yab kept before come together
// here, once: everything in either, on if on anywhere, pinned if pinned
// anywhere, Chromium's pin order first since that is what was on screen.
// Store packages and approved unpacked folders use the same Chrome identity.

enum ExtensionOneList {
    /// One row of the profile's own list.
    struct Native: Equatable {
        let id: String
        let name: String
        let version: String
        let enabled: Bool
    }

    /// Test worlds only: the two lists as they were before, to set up the
    /// state a migration starts from.
    static var off: Bool {
        Store.testing && ProcessInfo.processInfo.environment["YAB_TWO_LISTS"] == "1"
    }

    /// An icon's average color, for the bench to compare the two engines'
    /// buttons: they draw the same image at different sizes.
    static func tint(_ image: NSImage?) -> [Int] {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        var pixels = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixels, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixels.prefix(3).map(Int.init)
    }

    /// Whether Chromium can hold this entry.
    static func crosses(_ item: Installed) -> Bool {
        (item.fromStore || item.source != nil) && ChromiumExtensions.validID(item.id)
    }

    /// Folder installs keep their WebKit runtime for their popup and developer
    /// Reload. Do not inject Chromium's bridge beside that runtime on WK tabs.
    static func webKitFolders(_ list: [Installed]) -> Set<String> {
        Set(list.filter { $0.source != nil }.map(\.id))
    }

    /// The union of the two lists, keeping the WebKit list's order and
    /// everything each entry knows.
    static func merged(webKit: [Installed], native: [Native], pins: [String]) -> [Installed] {
        var out = webKit
        let rows = Dictionary(native.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in out.indices {
            guard let row = rows[out[index].id], row.enabled else { continue }
            out[index].enabled = true
            // It runs on Chromium: it was allowed there.
            out[index].wants = nil
        }
        let have = Set(out.map(\.id))
        for row in native where !have.contains(row.id) {
            out.append(Installed(id: row.id, name: row.name, version: row.version, enabled: row.enabled,
                                 fromStore: true, permissions: []))
        }
        let pinned = Set(pins)
        for index in out.indices where pinned.contains(out[index].id) { out[index].pinned = true }
        // Tiles follow the order the list keeps them in.
        var placed = Set<String>()
        let first = pins.compactMap { id in out.first { $0.id == id } }.filter { placed.insert($0.id).inserted }
        let rest = out.filter { $0.pinned == true && placed.insert($0.id).inserted }
        return first + rest + out.filter { !placed.contains($0.id) }
    }

    /// What Chromium must do for its list to match. `known`: what the profile
    /// held when it last matched, which tells one removed from the list while
    /// the helper was down from one newly installed on Chromium.
    struct Plan: Equatable {
        var dropFromChromium: [String] = []
        var addToList: [Native] = []
        var bringToChromium: [Installed] = []
    }

    /// An entry missing from Chromium is always brought back rather than
    /// taken off the list: a damaged profile must not cost anyone an
    /// extension.
    static func plan(list: [Installed], native: [Native], known: Set<String>) -> Plan {
        var plan = Plan()
        let listed = Set(list.map(\.id))
        let here = Set(native.map(\.id))
        for row in native where !listed.contains(row.id) {
            if known.contains(row.id) { plan.dropFromChromium.append(row.id) } else { plan.addToList.append(row) }
        }
        plan.bringToChromium = list.filter { crosses($0) && !here.contains($0.id) }
        return plan
    }

    /// `known` as a pass leaves it: what Chrome holds that the list holds
    /// too, or that the list held when they last matched (taken off the
    /// list since: the next pass takes it off Chromium). One Chrome took in
    /// while the pass ran is in neither, so the next pass adds it to the
    /// list; called known, it would be taken for one the list had dropped
    /// and removed (extensions added a few seconds apart, 3 of 6 kept).
    static func matched(native: [String], list: [Installed], known: Set<String>) -> Set<String> {
        let listed = Set(list.map(\.id))
        return Set(native.filter { listed.contains($0) || known.contains($0) })
    }

    /// Whether Chrome's list, just read, wants a pass: it holds one the list
    /// doesn't. `known`: nil when no pass runs. While one runs, only one that
    /// pass may have read too late wants another, one in neither the list
    /// nor `known`; one the pass is taking off Chromium doesn't.
    static func wantsPass(native: [String], list: [Installed], known: Set<String>?) -> Bool {
        let listed = Set(list.map(\.id))
        let unlisted = native.filter { !listed.contains($0) }
        guard let known else { return !unlisted.isEmpty }
        return unlisted.contains { !known.contains($0) }
    }

    /// Who takes which key of two copies of one set, each key with a value
    /// that says when it differs. `shadow` is the set when they last matched,
    /// nil the first time, when nothing counts as removed. Where both moved,
    /// the side written last wins.
    struct Crossing: Equatable {
        var toChromium: [String] = []
        var toWebKit: [String] = []
        var removeFromChromium: [String] = []
        var removeFromWebKit: [String] = []
    }

    static func crossing(chromium: [String: String], webKit: [String: String], shadow: [String: String]?, chromiumNewer: Bool) -> Crossing {
        var out = Crossing()
        for key in Set(chromium.keys).union(webKit.keys).sorted() {
            let c = chromium[key], w = webKit[key]
            guard c != w else { continue }
            let takeChromium: Bool
            if let shadow {
                let was = shadow[key]
                let chromiumMoved = c != was, webKitMoved = w != was
                takeChromium = chromiumMoved && webKitMoved ? chromiumNewer : chromiumMoved
            } else if c == nil || w == nil {
                takeChromium = c != nil
            } else {
                takeChromium = chromiumNewer
            }
            if takeChromium {
                if c == nil { out.removeFromWebKit.append(key) } else { out.toWebKit.append(key) }
            } else {
                if w == nil { out.removeFromChromium.append(key) } else { out.toChromium.append(key) }
            }
        }
        return out
    }
}
