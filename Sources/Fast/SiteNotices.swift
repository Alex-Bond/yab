import AppKit
import Intents
import UserNotifications
import WebKit

// A site's notifications, while its tab is open, shown as macOS
// notifications (docs/site-notifications.md). WKWebView alone answers every
// Notification.requestPermission() "denied"; WebKit's C notification
// provider is how a browser built on it gets them instead.
//
// The site asks with its own button; Yab asks you on a card from its tab
// (Asks.swift, `notifications`), remembers the answer for the site at once,
// and asks macOS about Yab only after you said yes there. What the page or
// its service worker then shows comes here: a macOS banner with the site's
// picture large, as Messages shows a person (`face`), or, without the
// entitlement for that or without a picture, an ordinary one. A click
// brings Yab, the window, the space and the tab forward and tells the page,
// which opens what it was about. A site allowed this never sleeps out of
// sight (Sleep.swift): a page put down can't say anything.
//
// With its tab closed, a site reaches Yab by Web Push (WebPush.swift):
// Yab's own push service, and the push handed to its service worker here,
// which shows what it shows through the same provider.

@MainActor
enum SiteNotices {
    nonisolated static let category = "site.note"
    /// An extension's: no site to turn off or show controls for, and
    /// swept away still heard, for its onClosed.
    nonisolated static let extensionCategory = "site.extension"
    nonisolated static let turnOff = "site.off"
    nonisolated static let controls = "site.controls"

    // MARK: - what was said

    nonisolated static func key(_ origin: String) -> String { "notifications.\(origin)" }

    /// Allowed, blocked, or never asked, for an origin as Yab writes one
    /// (`Browser.origin`: scheme, host and port).
    static func said(_ origin: String) -> Bool? { Store.settings.object(forKey: key(origin)) as? Bool }

    struct Permission: Identifiable, Equatable {
        let origin: String
        let allowed: Bool
        var id: String { origin }
        var title: String { SiteNotices.webKitOrigin(origin) }
        var host: String { URL(string: origin)?.host() ?? origin }
    }

    /// Every remembered answer, including denied sites with no open tab.
    static func sites() -> [Permission] {
        Store.settings.dictionaryRepresentation().compactMap { key, value -> Permission? in
            guard key.hasPrefix("notifications."), let allowed = value as? Bool else { return nil }
            let origin = String(key.dropFirst("notifications.".count))
            guard Self.origin(webKit: origin) != nil else { return nil }
            return Permission(origin: origin, allowed: allowed)
        }.sorted { $0.origin < $1.origin }
    }

    /// A tab whose site may send notifications.
    static func allowed(_ tab: Tab) -> Bool {
        guard let origin = Browser.origin(of: tab.address) else { return false }
        return said(origin) == true
    }

    /// The answer, kept for the site and told to WebKit, which otherwise
    /// goes by what it heard when the page's process started.
    static func remember(_ origin: String, _ yes: Bool) {
        Store.settings.set(yes, forKey: key(origin))
        tell { manager in
            guard let site = makeOrigin(origin) else { return }
            fn("WKNotificationManagerProviderDidUpdateNotificationPolicy", (@convention(c) (Ref, Ref, Bool) -> Void).self)?(manager, site, yes)
            release(site)
        }
        if !yes {
            takeDown(origin)
            WebPush.shared.drop(origin: origin)
        }
    }

    /// Site Controls' cross: never said, so the site may ask again.
    static func forget(_ origin: String) {
        Store.settings.removeObject(forKey: key(origin))
        tell { manager in
            guard let site = makeOrigin(origin), let list = array([site]) else { return }
            fn("WKNotificationManagerProviderDidRemoveNotificationPolicies", (@convention(c) (Ref, Ref) -> Void).self)?(manager, list)
            release(list)
            release(site)
        }
        takeDown(origin)
        WebPush.shared.drop(origin: origin)
    }

    /// WebKit writes an origin without its scheme's own port; Yab keeps the
    /// port always, so http and https, or two ports of localhost, are each
    /// their own site.
    nonisolated static func webKitOrigin(_ origin: String) -> String {
        if origin.hasPrefix("http://"), origin.hasSuffix(":80") { return String(origin.dropLast(3)) }
        if origin.hasPrefix("https://"), origin.hasSuffix(":443") { return String(origin.dropLast(4)) }
        return origin
    }

    /// And back.
    nonisolated static func origin(webKit: String) -> String? {
        guard let url = URL(string: webKit), let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty else { return nil }
        // As Browser.origin writes it.
        let port = url.port ?? (scheme == "http" ? 80 : scheme == "https" ? 443 : 0)
        return "\(scheme)://\(host.lowercased()):\(port)"
    }

    // MARK: - one notification

    /// WKNotificationAlert: absent or false `silent` keeps the default sound.
    enum Alert: UInt32 {
        case standard = 1, silent = 2, enabled = 4

        init(webKit: UInt32?) {
            self = webKit.flatMap(Self.init(rawValue:)) ?? .standard
        }
    }

    /// A notification as WebKit gave it, and where it went.
    struct Note: Equatable {
        var id: UInt64
        /// From the site's service worker rather than its page.
        var worker: Bool
        var origin: String
        var title: String
        var body: String
        var tag: String
        var icon: String
        /// The tab of its site it was shown for, the one a click goes to.
        var tab: UUID?
        var alert: Alert = .standard
        /// How the face came out: "face" (as a message), "picture", "plain".
        var look = "plain"
        /// Chromium's own, when a Chromium page or worker showed it: where
        /// the person's answer goes back to (SiteNotices+Chromium.swift).
        var chromium: Chromium?
        /// Who said it when that isn't its host: an extension's name, and
        /// its icon for a notification that brought none.
        var from = ""
        var fromIcon: Data?

        var host: String { URL(string: origin)?.host() ?? origin }
        /// Under the title: the site, or the extension and what Chrome
        /// shows there for it (its contextMessage).
        var sender: String {
            guard chromium?.extensionID != nil else { return host }
            let name = from.isEmpty ? "Extension" : from
            let context = chromium?.subtitle ?? ""
            return context.isEmpty ? name : name + " · " + context
        }
        /// The same tag takes the place of the site's last one with it.
        var request: String { SiteNotices.request(origin: origin, tag: tag, id: id) }
    }

    nonisolated static func request(origin: String, tag: String, id: UInt64) -> String {
        "site.\(origin)|" + (tag.isEmpty ? "#\(id)" : tag)
    }

    /// One stack a site in Notification Center.
    nonisolated static func thread(_ origin: String) -> String { "site.\(origin)" }

    nonisolated static func info(_ note: Note) -> [String: Any] {
        var info: [String: Any] = ["site": note.origin, "note": String(note.id), "worker": note.worker,
                                   "silent": note.alert == .silent]
        if let tab = note.tab { info["tab"] = tab.uuidString }
        if let chromium = note.chromium { info["chromium"] = chromium.fields }
        return info
    }

    /// Up now, by the engine's id: what a close() from the page takes down.
    static var standing: [UInt64: Note] = [:]
    /// The last ones shown and clicked, for the bench.
    private(set) static var shown: [Note] = []
    static var clicked: [UInt64] = []

    // MARK: - WebKit's provider

    typealias Ref = UnsafeRawPointer
    private struct Base { var version: Int32; var info: UnsafeRawPointer? }
    /// WKNotificationProviderV0.
    private struct Provider {
        var base: Base
        var show: (@convention(c) (Ref?, Ref?, UnsafeRawPointer?) -> Void)?
        var cancel: (@convention(c) (Ref?, UnsafeRawPointer?) -> Void)?
        var destroyed: (@convention(c) (Ref?, UnsafeRawPointer?) -> Void)?
        var add: (@convention(c) (Ref?, UnsafeRawPointer?) -> Void)?
        var remove: (@convention(c) (Ref?, UnsafeRawPointer?) -> Void)?
        var permissions: (@convention(c) (UnsafeRawPointer?) -> Ref?)?
        var clear: (@convention(c) (Ref?, UnsafeRawPointer?) -> Void)?
    }

    nonisolated(unsafe) private static let webKit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)
    nonisolated private static func fn<T>(_ name: String, _ type: T.Type) -> T? {
        guard let symbol = dlsym(webKit, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
    private typealias Get = @convention(c) (Ref) -> Ref?
    private typealias Tell = @convention(c) (Ref, UInt64) -> Void

    private static var pages: Ref?
    private static var workers: Ref?
    private static var installed = false
    /// Every symbol was there: without one, sites hear "denied" as before.
    static var working: Bool { pages != nil }

    private static let needed: [String] = [
        "WKNotificationGetID", "WKNotificationCopyTitle", "WKNotificationGetSecurityOrigin", "WKSecurityOriginCopyToString",
        "WKStringCopyCFString", "WKStringCreateWithCFString", "WKMutableDictionaryCreate", "WKDictionarySetItem", "WKBooleanCreate",
        "WKNotificationManagerProviderDidShowNotification", "WKNotificationManagerProviderDidClickNotification",
    ]

    /// Once, before the first page: WebKit asks the provider what was
    /// allowed when each page's process starts.
    static func install() {
        guard !installed, !LinkGap.cut("notices") else { return }
        installed = true
        guard let context = fn("WKContextGetNotificationManager", Get.self),
              let set = fn("WKNotificationManagerSetProvider", (@convention(c) (Ref, UnsafeRawPointer) -> Void).self),
              let shared = fn("WKNotificationManagerGetSharedServiceWorkerNotificationManager", (@convention(c) () -> Ref?).self),
              needed.allSatisfy({ name in dlsym(webKit, name) != nil })
        else { return }
        pages = context(Unmanaged.passUnretained(Web.pool).toOpaque())
        workers = shared()
        for (manager, which) in [(pages, 1), (workers, 2)] {
            guard let manager else { continue }
            let provider = UnsafeMutablePointer<Provider>.allocate(capacity: 1)
            provider.initialize(to: Provider(
                base: Base(version: 0, info: UnsafeRawPointer(bitPattern: which)),
                show: { _, note, info in
                    guard let note else { return }
                    let worker = info == UnsafeRawPointer(bitPattern: 2)
                    MainActor.assumeIsolated { SiteNotices.show(note, worker: worker) }
                },
                cancel: { note, _ in
                    guard let note else { return }
                    MainActor.assumeIsolated { SiteNotices.cancel(note) }
                },
                destroyed: { _, _ in }, add: { _, _ in }, remove: { _, _ in },
                permissions: { _ in MainActor.assumeIsolated { SiteNotices.permissions() } },
                clear: { _, _ in }))
            set(manager, UnsafeRawPointer(provider))
        }
        listen(Store.websites)
        if AgentNotices.possible { AgentNotices.prepareCategories() }
    }

    /// Everything said, as WebKit writes origins.
    private static func permissions() -> Ref? {
        guard let make = fn("WKMutableDictionaryCreate", (@convention(c) () -> Ref?).self),
              let put = fn("WKDictionarySetItem", (@convention(c) (Ref, Ref, Ref) -> Bool).self),
              let bool = fn("WKBooleanCreate", (@convention(c) (Bool) -> Ref?).self),
              let dictionary = make()
        else { return nil }
        for (origin, yes) in policies() {
            guard let name = string(origin), let value = bool(yes) else { continue }
            _ = put(dictionary, name, value)
            release(name)
            release(value)
        }
        return dictionary
    }

    /// What was said, by WebKit's origin.
    static func policies() -> [String: Bool] {
        var all: [String: Bool] = [:]
        for (key, value) in Store.settings.dictionaryRepresentation() where key.hasPrefix("notifications.") {
            guard let yes = value as? Bool else { continue }
            all[webKitOrigin(String(key.dropFirst("notifications.".count)))] = yes
        }
        return all
    }

    private static func show(_ ref: Ref, worker: Bool) {
        let get = { (name: String) in fn(name, Get.self) }
        guard let id = fn("WKNotificationGetID", (@convention(c) (Ref) -> UInt64).self)?(ref) else { return }
        let site = get("WKNotificationGetSecurityOrigin")?(ref).flatMap { get("WKSecurityOriginCopyToString")?($0) }
        guard let origin = origin(webKit: text(site)) else { return }
        let note = Note(id: id, worker: worker, origin: origin,
                        title: text(get("WKNotificationCopyTitle")?(ref)), body: text(get("WKNotificationCopyBody")?(ref)),
                        tag: text(get("WKNotificationCopyTag")?(ref)), icon: text(get("WKNotificationCopyIconURL")?(ref)),
                        tab: tab(for: origin)?.tab.id,
                        alert: Alert(webKit: fn("WKNotificationGetAlert", (@convention(c) (Ref) -> UInt32).self)?(ref)))
        // The page's onshow fires now, as it would once the banner is up.
        if let manager = worker ? workers : pages { fn("WKNotificationManagerProviderDidShowNotification", Tell.self)?(manager, id) }
        Task { await post(note) }
        // A promise someone made you in it, kept as theirs (Promises.heard).
        if let page = URL(string: origin), page.host() != nil {
            let title = note.title, body = note.body
            Task { @MainActor in Promises.shared.heard(origin: page, title: title, body: body) }
        }
    }

    /// The page closed it: out of Notification Center too.
    private static func cancel(_ ref: Ref) {
        guard let id = fn("WKNotificationGetID", (@convention(c) (Ref) -> UInt64).self)?(ref),
              let note = standing.removeValue(forKey: id)
        else { return }
        if AgentNotices.possible, !Store.testing {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [note.request])
        }
    }

    /// Both managers, the pages' and the service workers'.
    private static func tell(_ each: (Ref) -> Void) {
        for manager in [pages, workers].compactMap({ $0 }) { each(manager) }
    }

    nonisolated private static func text(_ ref: Ref?) -> String {
        guard let ref, let copy = fn("WKStringCopyCFString", (@convention(c) (UnsafeRawPointer?, Ref) -> Unmanaged<CFString>?).self),
              let string = copy(nil, ref)
        else { return "" }
        let text = string.takeRetainedValue() as String
        release(ref)
        return text
    }

    nonisolated private static func string(_ text: String) -> Ref? {
        fn("WKStringCreateWithCFString", (@convention(c) (CFString) -> Ref?).self)?(text as CFString)
    }

    private static func makeOrigin(_ origin: String) -> Ref? {
        guard let name = string(webKitOrigin(origin)) else { return nil }
        defer { release(name) }
        return fn("WKSecurityOriginCreateFromString", Get.self)?(name)
    }

    private static func array(_ items: [Ref]) -> Ref? {
        var items = items.map { Optional($0) }
        return items.withUnsafeMutableBufferPointer { buffer in
            fn("WKArrayCreate", (@convention(c) (UnsafeMutablePointer<Ref?>?, Int) -> Ref?).self)?(buffer.baseAddress, buffer.count)
        }
    }

    nonisolated private static func release(_ ref: Ref) {
        fn("WKRelease", (@convention(c) (Ref) -> Void).self)?(ref)
    }

    // MARK: - the banner

    static func post(_ note: Note) async {
        var note = note
        let picture = await picture(for: note)
        note.look = picture == nil ? "plain" : "picture"
        let request = note.request
        standing = standing.filter { $0.value.request != request }
        if Store.testing || !AgentNotices.possible {
            if picture != nil, said(note.origin) == true, faces { note.look = "face" }
            record(note)
            return
        }
        guard await MailNotify.shared.center.permission() == .allowed else { return record(note) }
        let content = Self.content(note)
        await addButtons(note, to: content)
        var shown: UNNotificationContent = content
        if let picture {
            if let face = try? await face(note, picture: picture, content: content) {
                shown = face
                note.look = "face"
            } else if let attachment = attachment(picture) {
                content.attachments = [attachment]
            }
        }
        record(note)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request, content: shown, trigger: nil))
    }

    static func content(_ note: Note) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let own = note.chromium?.extensionID != nil
        content.title = note.title.isEmpty ? (own && !note.from.isEmpty ? note.from : note.host) : note.title
        content.subtitle = note.sender
        content.body = note.body
        content.sound = soundAllowed(info(note)) ? .default : nil
        content.threadIdentifier = thread(note.origin)
        content.categoryIdentifier = own ? extensionCategory : category
        content.userInfo = info(note)
        return content
    }

    private static func record(_ note: Note) {
        standing[note.id] = note
        shown.append(note)
        if shown.count > 50 { shown.removeFirst(shown.count - 50) }
    }

    /// Whether this copy of Yab may show a site's notification as a
    /// message: its signature carries Communication Notifications, which
    /// only the profile gives (build.sh).
    static let faces: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var details: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &details) == errSecSuccess,
              let entitlements = (details as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.developer.usernotifications.communication"] as? Bool == true
    }()

    /// The site's picture large and Yab's small, as Messages shows a
    /// person: the notification said as a message to you from it. Throws
    /// where macOS won't, without the entitlement.
    private static func face(_ note: Note, picture: Data, content: UNNotificationContent) async throws -> UNNotificationContent {
        let image = INImage(imageData: picture)
        let sender = INPerson(personHandle: INPersonHandle(value: note.origin, type: .unknown), nameComponents: nil,
                              displayName: content.title, image: image, contactIdentifier: nil,
                              customIdentifier: note.origin + "|" + note.tag)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: note.body,
                                         speakableGroupName: nil, conversationIdentifier: thread(note.origin) + "|" + note.tag,
                                         serviceName: note.host, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try await interaction.donate()
        return try content.updating(from: intent)
    }

    /// The ordinary banner's picture, at its side.
    private static func attachment(_ picture: Data) -> UNNotificationAttachment? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("site-notices", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? picture.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "picture", url: file)
    }

    /// The notification's own picture, fetched as its page would, so a
    /// picture behind a sign-in (a person's face on Slack) comes too; then
    /// without the page; then the site's icon. No more than a megabyte, no
    /// longer than two seconds.
    private static func picture(for note: Note) async -> Data? {
        if let image = note.chromium?.image { return png(image) ?? image }
        // An extension's own icon, as a site's falls back to its favicon.
        if note.chromium?.extensionID != nil { return note.fromIcon.flatMap { png($0) } }
        if let url = URL(string: note.icon), ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") {
            if let tab = note.tab.flatMap(find)?.tab, let built = tab.webKitOnly("WebKit notification source", build: false),
               let data = await within(2, { await fromPage(built, note.icon) }), let png = png(data) {
                return png
            }
            if let data = await within(2, { try? await URLSession.shared.data(from: url).0 }), data.count <= 1 << 20, let png = png(data) {
                return png
            }
        }
        let site = Browser.site(note.host)
        guard let icon = Favicons.shared.cached(note.host) ?? Favicons.shared.cached(site), let tiff = icon.tiffRepresentation else { return nil }
        return png(tiff)
    }

    private static func fromPage(_ web: WKWebView, _ url: String) async -> Data? {
        let script = """
            const response = await fetch(url, { credentials: 'include' });
            if (!response.ok) return null;
            const blob = await response.blob();
            if (blob.size > 1048576) return null;
            const bytes = new Uint8Array(await blob.arrayBuffer());
            let text = '';
            for (let i = 0; i < bytes.length; i += 32768) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
            return btoa(text);
            """
        guard let base64 = try? await web.callAsyncJavaScript(script, arguments: ["url": url], contentWorld: .defaultClient) as? String else { return nil }
        return Data(base64Encoded: base64)
    }

    private static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @MainActor () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Any picture as a PNG no bigger than macOS shows it.
    nonisolated static func png(_ data: Data, side: CGFloat = 256) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = NSSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - answered

    /// The buttons a site's banner wears under Options.
    nonisolated static var categories: Set<UNNotificationCategory> {
        let off = UNNotificationAction(identifier: turnOff, title: "Turn Off for This Site", options: [])
        let panel = UNNotificationAction(identifier: controls, title: "Site Controls…", options: [.foreground])
        return [UNNotificationCategory(identifier: category, actions: [off, panel], intentIdentifiers: [], options: [.customDismissAction]),
                UNNotificationCategory(identifier: extensionCategory, actions: [], intentIdentifiers: [], options: [.customDismissAction])]
    }

    /// Not over the site you are looking at: you see what it says already.
    static func presenting(_ info: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
        guard let origin = info["site"] as? String else { return [.banner, .sound, .list] }
        // An extension's, over its own page too, as Chromium shows it.
        if origin.hasPrefix("chrome-extension://") { return soundAllowed(info) ? [.banner, .sound, .list] : [.banner, .list] }
        if NSApp.isActive, let key = NSApp.keyWindow, let browser = BrowserWindows.shared.browser(for: key),
           let tab = browser.active, Browser.origin(of: tab.address) == origin {
            return []
        }
        return soundAllowed(info) ? [.banner, .sound, .list] : [.banner, .list]
    }

    /// Muting a tab or its site also quiets the site's native banners.
    /// Keep the notification's original tab when it still has this origin;
    /// navigation during an icon fetch must not mute a different site.
    private static func soundAllowed(_ info: [AnyHashable: Any]) -> Bool {
        if info["silent"] as? Bool == true { return false }
        guard let origin = info["site"] as? String else { return true }
        let addressed = (info["tab"] as? String).flatMap { UUID(uuidString: $0) }.flatMap { find($0) }
        let source = addressed.flatMap { Browser.origin(of: $0.tab.address) == origin ? $0 : nil }
            ?? tab(for: origin)
        guard let source else { return true }
        return !source.tab.muted && !source.browser.siteMuted(source.tab, at: URL(string: origin))
    }

    static func answer(_ action: String, _ info: [AnyHashable: Any]) {
        guard let origin = info["site"] as? String else { return }
        let id = (info["note"] as? String).flatMap(UInt64.init)
        let worker = info["worker"] as? Bool ?? false
        let tab = (info["tab"] as? String).flatMap(UUID.init)
        if let fields = info["chromium"] as? [String: Any], let chromium = Chromium(fields: fields),
           answer(action, chromium, origin: origin, id: id, tab: tab) { return }
        switch action {
        case UNNotificationDismissActionIdentifier:
            guard let id, let manager = worker ? workers : pages, let number = fn("WKUInt64Create", (@convention(c) (UInt64) -> Ref?).self)?(id),
                  let list = array([number])
            else { return }
            fn("WKNotificationManagerProviderDidCloseNotifications", (@convention(c) (Ref, Ref) -> Void).self)?(manager, list)
            release(list)
            release(number)
            standing[id] = nil
        case turnOff:
            remember(origin, false)
        case controls:
            guard let found = front(origin, tab: tab) else { return }
            ExtensionPanel.shared.toggle(tab: found.tab, page: .main)
        default:
            open(origin, id: id, worker: worker, tab: tab)
        }
    }

    /// A click: Yab, the window, the space and the tab forward, then the
    /// page told, which opens what it was about. Its tab closed since, the
    /// site opens in a new one; a service worker's opens its own window.
    static func open(_ origin: String, id: UInt64?, worker: Bool, tab: UUID?) {
        let found = front(origin, tab: tab)
        if let id, let manager = worker ? workers : pages, found != nil || worker {
            fn("WKNotificationManagerProviderDidClickNotification", Tell.self)?(manager, id)
            clicked.append(id)
            standing[id] = nil
        } else if found == nil, let url = URL(string: webKitOrigin(origin)) {
            let browser = BrowserWindows.shared.browser(for: NSApp.keyWindow) ?? BrowserWindows.shared.browsers.first
            _ = browser?.open(url, foreground: true)
        }
    }

    /// The site's tab brought forward, if one is open.
    @discardableResult
    static func front(_ origin: String, tab id: UUID?) -> (browser: Browser, tab: Tab)? {
        bringForward()
        // In whichever window and space it waits (BrowserWindows.reveal).
        if let id, let found = BrowserWindows.shared.reveal(id, front: !Store.testing) { return found }
        guard let found = tab(for: origin) else { return nil }
        return BrowserWindows.shared.reveal(found.tab.id, front: !Store.testing)
    }

    /// Yab in front, its windows shown if they were hidden.
    static func bringForward() {
        guard !Store.testing else { return }
        if Headless.hidden {
            Headless.show(.request)
            Links.showBrowser()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func find(_ id: UUID) -> (browser: Browser, tab: Tab)? {
        for browser in BrowserWindows.shared.browsers {
            if let tab = browser.everyTab.first(where: { $0.id == id }) { return (browser, tab) }
        }
        return nil
    }

    /// The site's tab: the one in front if it is the site's, or the one
    /// last looked at.
    static func tab(for origin: String) -> (browser: Browser, tab: Tab)? {
        var best: (browser: Browser, tab: Tab)?
        for browser in BrowserWindows.shared.browsers {
            for tab in browser.tabs + browser.parkedTabs where Browser.origin(of: tab.address) == origin {
                if tab.id == browser.activeID { return (browser, tab) }
                if best.map({ tab.touched > $0.tab.touched }) ?? true { best = (browser, tab) }
            }
        }
        return best
    }

    /// Everything a site showed, out of Notification Center: turned off or
    /// forgotten.
    private static func takeDown(_ origin: String) {
        let gone = standing.filter { $0.value.origin == origin }
        for id in gone.keys { standing[id] = nil }
        tellChromium(gone: gone.values.compactMap(\.chromium))
        guard AgentNotices.possible, !Store.testing else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let ids = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == thread(origin) }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: - a service worker's window

    /// A worker's notificationclick that calls clients.openWindow(): a new
    /// tab, in front, its web view handed back.
    private final class Opener: NSObject {
        /// What each site was told, as WebKit asks before it hands a push
        /// to a worker: a site it hears nothing of is "prompt", and WebKit
        /// throws the push away (WebPush.swift).
        @objc(notificationPermissionsForWebsiteDataStore:)
        func permissions(_ store: WKWebsiteDataStore) -> [String: NSNumber] {
            MainActor.assumeIsolated { SiteNotices.policies().mapValues { NSNumber(value: $0) } }
        }

        @objc(websiteDataStore:openWindow:fromServiceWorkerOrigin:completionHandler:)
        func openWindow(_ store: WKWebsiteDataStore, url: URL, origin: WKSecurityOrigin, completionHandler: @escaping (WKWebView?) -> Void) {
            MainActor.assumeIsolated {
                let browsers = BrowserWindows.shared.browsers
                let browser = browsers.first { Spaces.store(for: $0.spaceID) === store }
                    ?? BrowserWindows.shared.browser(for: NSApp.keyWindow) ?? browsers.first
                guard let browser else { return completionHandler(nil) }
                completionHandler(browser.open(url, foreground: true).webKitOnly("WebKit notification window"))
            }
        }
    }

    private static let opener = Opener()

    /// Each store of sign-ins, as it is made (Spaces.store).
    /// The property is `_delegate`, so its setter is `set_delegate:`:
    /// `_setDelegate:`, asked before, no WebKit answers (PrivateNamesTests).
    static func listen(_ store: WKWebsiteDataStore) {
        let set = NSSelectorFromString("set_delegate:")
        guard store.responds(to: set), !LinkGap.cut("notices") else { return }
        store.perform(set, with: opener)
    }

    // MARK: - macOS

    /// What macOS says about Yab, asked now: only after Allow on a site's
    /// card. A test world's answer is the bench's (os-yes, os-no).
    static func askMac() async -> Bool {
        let notify = MailNotify.shared
        if Store.testing, let record = notify.center as? MailNotify.Record {
            let yes = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in macAnswer = { done.resume(returning: $0) } }
            record.state = yes ? .allowed : .denied
        } else {
            await notify.center.ask()
        }
        await notify.refresh()
        return notify.permission == .allowed
    }

    private static var macAnswer: ((Bool) -> Void)?

    // MARK: - the bench

    /// A real press on the page's element, handed to its window as the
    /// mouse would hand it: WebKit asks about notifications only after the
    /// page was clicked, and a script's click() isn't one.
    nonisolated static func quoted(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    static func press(_ selector: String, in tab: Tab, done: @escaping ([String: Any]) -> Void) {
        let web = tab.page
        let script = "(() => { const e = document.querySelector(\(quoted(selector))); if (!e) return null; const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
        web.run(script) { result in
            MainActor.assumeIsolated {
                guard let point = (try? result.get()) as? [Double], point.count == 2, let window = web.window else { return done(["error": "nothing at \(selector)"]) }
                let inWeb = NSPoint(x: point[0], y: web.isFlipped ? point[1] : web.bounds.height - point[1])
                let at = web.convert(inWeb, to: nil)
                if !window.isKeyWindow { window.makeKey() }
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                         pressure: type == .leftMouseUp ? 0 : 1)
                    else { continue }
                    window.sendEvent(event)
                }
                // Answered once the page has had the whole click. WebKit
                // holds the mouse-up until the page has taken the mouse-down,
                // and a bench eval sent in between (a script runs as a
                // gesture) took the click's activation with it when it ended
                // (WebKit bug 324512, fixed after macOS 27's WebKit): the
                // page's Notification.requestPermission() then heard "denied"
                // without Yab being asked.
                afterMouse(web) { done(["ok": true, "at": [at.x, at.y]]) }
            }
        }
    }

    private static let afterMouseSelector = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")

    private static func afterMouse(_ web: NSView, _ then: @escaping () -> Void) {
        guard web.responds(to: afterMouseSelector) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: then)
            return
        }
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(web.method(for: afterMouseSelector), to: Call.self)(web, afterMouseSelector, then)
    }

    /// `{"do":"ui","notify":…}`: state; click[:N] and dismiss[:N] the
    /// last shown, or the Nth; allow:ORIGIN, block:ORIGIN, forget[:ORIGIN];
    /// in a test world os:unasked|allowed|denied for what macOS says, and
    /// os-yes or os-no for its answer to the question.
    static func bench(_ command: String, browser: Browser) -> [String: Any] {
        let record = MailNotify.shared.center as? MailNotify.Record
        let pick = { (prefix: String) -> Note? in
            let index = Int(command.dropFirst(prefix.count + 1)) ?? (shown.count - 1)
            return shown.indices.contains(index) ? shown[index] : nil
        }
        switch command {
        case "os-yes", "os-no":
            macAnswer?(command == "os-yes")
            macAnswer = nil
        case let set where set.hasPrefix("os:"):
            if let state = MailNotify.Permission(rawValue: String(set.dropFirst(3))) { record?.state = state }
            Task { await MailNotify.shared.refresh() }
        case let seed where seed.hasPrefix("allow:"): remember(String(seed.dropFirst(6)), true)
        case let seed where seed.hasPrefix("block:"): remember(String(seed.dropFirst(6)), false)
        case "forget":
            for key in Store.settings.dictionaryRepresentation().keys where key.hasPrefix("notifications.") {
                forget(String(key.dropFirst("notifications.".count)))
            }
        case let one where one.hasPrefix("forget:"): forget(String(one.dropFirst(7)))
        case "push": return WebPush.shared.bench()
        case let row where row.hasPrefix("revoke:"):
            // Site Controls' cross on one of the page in front's rows.
            if let tab = browser.active { SiteFacts(tab: tab).allowed.first { $0.title == String(row.dropFirst(7)) }?.forget() }
        case let press where press.hasPrefix("button"):
            // "button0" or "button1": the newest notification's own button.
            if let note = shown.last, let index = Int(press.dropFirst("button".count)) { answer(buttonAction(index), info(note)) }
        case let click where click.hasPrefix("click"):
            if let note = pick("click") { answer(UNNotificationDefaultActionIdentifier, info(note)) }
        case let dismiss where dismiss.hasPrefix("dismiss"):
            if let note = pick("dismiss") { answer(UNNotificationDismissActionIdentifier, info(note)) }
        default: break
        }
        return ["os": record?.state.rawValue ?? MailNotify.shared.permission.rawValue, "working": working, "faces": faces,
                "shown": shown.map { ["id": String($0.id), "worker": $0.worker, "origin": $0.origin, "title": $0.title, "body": $0.body,
                                      "tag": $0.tag, "icon": $0.icon, "look": $0.look, "request": $0.request,
                                      "from": $0.from, "sender": $0.sender, "category": content($0).categoryIdentifier,
                                      "engine": $0.chromium == nil ? "webkit" : "chromium", "buttons": $0.chromium?.buttons ?? [],
                                      "tab": $0.tab.map { String($0.uuidString.prefix(8)).lowercased() } ?? ""] },
                "standing": standing.keys.map(String.init).sorted(),
                "clicked": clicked.map(String.init),
                "said": policies(),
                "rows": browser.active.map { SiteFacts(tab: $0).allowed.map { "\($0.title): \($0.said ? "Allowed" : "Blocked")" } } ?? [],
                "front": browser.active.flatMap { Browser.origin(of: $0.address) } ?? "",
                "frontTab": browser.active.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? "",
                "asks": browser.tabs.flatMap { tab in tab.asks.map { "\($0.kind) \($0.stage) \($0.host)" } }]
    }
}
