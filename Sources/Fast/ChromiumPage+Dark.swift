import AppKit
import YabCoreClient

/// The scheme and ground a Chromium page is drawn with. WebKit takes them
/// from its view: its appearance (Yab's theme, or the one dark pages put
/// on it, DarkPages.appearance) for CSS prefers-color-scheme, and the
/// under-page color for the ground before the first frame. Chromium's
/// renderer lives in YabCore, so each is told to it (`scripts.appearance`)
/// before a request leaves and whenever the view's appearance changes.
extension ChromiumPage {
    /// Dark pages' ground, or nil for the page's own.
    func darkGround(_ color: NSColor?) {
        scripts.ground = color
        layer?.backgroundColor = color?.cgColor
        scripts.appearanceChanged()
    }

    /// Dark Reader installed and on in this tab's own Chromium profile, as
    /// Chrome last listed it: Yab's engine then stays off, so a page is
    /// never darkened twice. WebKit's extensions say nothing about it.
    var darkReaderOn: Bool {
        !privateMode && extensions.items.contains { $0.id == DarkPages.extensionID && $0.enabled }
    }

    /// Whether the page should believe it has focus: one with no window of
    /// its own (an agent's) always; one in a window while that window is key
    /// and the person isn't typing in a field outside the page.
    var hearsFocus: Bool {
        // An agent's page has no window of its own and works unseen; a person's
        // tab out of its window is a hidden page, which hears no focus.
        guard let window else { return navigationTab?.bench == true }
        guard window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return false }
        return !(window.firstResponder is NSText)
    }

    /// The window's key state or the first responder changed.
    func focusChanged() { restoreSurfaceAttachment(); syncRemoteFocus(); scripts.appearanceChanged() }

    /// What the view wears now, as CSS reads it.
    var colorScheme: String {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    }
}

extension ChromiumScripts {
    /// The profiles whose extensions were read this launch for page features.
    @MainActor static var readProfiles: Set<String> = []
    @MainActor private static var readingProfiles: [String: Task<Void, Never>] = [:]

    /// Read before the first document is armed, so neither Dark Reader nor
    /// a JSON extension races Yab's own renderer. Same-profile tabs share
    /// the read; failed reads may retry on the next navigation.
    func readExtensions() async {
        guard let page, !page.privateMode, !Self.readProfiles.contains(page.profile) else { return }
        let profile = page.profile
        if let pending = Self.readingProfiles[profile] { await pending.value; return }
        // Chrome lists them only from its own page, with a renderer of its own,
        // ahead of the first document. A profile with none has nothing to wait for.
        if ChromiumExtensions.noneInstalled(profile: profile) { Self.readProfiles.insert(profile); return }
        let extensions = page.extensions
        let task = Task { @MainActor in
            do {
                _ = try await extensions.list()
                Self.readProfiles.insert(profile)
            } catch {
                DebugLog.note("scripts.extensions", ["error": String(describing: error)])
            }
        }
        Self.readingProfiles[profile] = task
        await task.value
        Self.readingProfiles[profile] = nil
    }

    /// The scheme and ground to tell the renderer, as the helper takes them.
    var appearance: JSONValue {
        var value: [String: JSONValue] = ["scheme": .string(page?.colorScheme ?? "light"), "ground": .null,
                                          "focused": .bool(page?.hearsFocus ?? true)]
        if let rgba = ground.flatMap(Self.rgba) { value["ground"] = rgba }
        return .object(value)
    }

    nonisolated static func rgba(_ color: NSColor) -> JSONValue? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> JSONValue { .number(Double(Int((min(1, max(0, v)) * 255).rounded()))) }
        return .object(["r": byte(srgb.redComponent), "g": byte(srgb.greenComponent), "b": byte(srgb.blueComponent),
                        "a": .number(Double(min(1, max(0, srgb.alphaComponent))))])
    }

    /// Before a navigation, with the helper tab in hand.
    func applyAppearance(core: YabCoreClient, tab: String) async throws {
        let wanted = appearance
        guard applied[tab] != wanted else { return }
        _ = try await core.request("scripts.appearance", params: ["tab": .string(tab), "appearance": wanted])
        applied[tab] = wanted
    }

    /// The view's appearance or the ground changed: a page that has its
    /// helper is told now; one not built yet hears it before its request.
    func appearanceChanged() {
        guard let page, page.remoteID != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let page = self.page, page.remoteID != nil,
                  let (core, id) = try? await page.endpoint() else { return }
            try? await self.applyAppearance(core: core, tab: id)
        }
    }
}
