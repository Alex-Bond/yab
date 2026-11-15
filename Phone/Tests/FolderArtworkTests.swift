import SwiftUI
import UIKit
import WebKit
import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class FolderArtworkSyncTests: XCTestCase {
    private var folder: URL!
    private var app: AppModel?
    private var mac: TestMac?
    private var leases: [OwnedLease] = []
    private final class OwnedLease {
        weak var engine: PhoneSync?
        weak var client: SyncClient?
        weak var journal: Journal?
        init(_ engine: PhoneSync) { self.engine = engine; client = engine.client; journal = engine.journal }
        init(_ client: SyncClient) { self.client = client; journal = client.journal }
        func stop() { if let engine { engine.stop() } else { client?.stop() } }
        var released: Bool { engine == nil && client == nil && journal == nil }
    }
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("folder-art-\(UUID().uuidString)") }
    override func tearDown() async throws {
        app?.sync.end(); app = nil; mac?.client.stop(); mac = nil; leases.forEach { $0.stop() }
        let end = Date().addingTimeInterval(4)
        while Date() < end, !leases.allSatisfy(\.released) { try? await Task.sleep(for: .milliseconds(10)) }
        guard leases.allSatisfy(\.released) else { return XCTFail("Preserving owned SQLite files while their weak native owners still live") }
        leases = []; try? FileManager.default.removeItem(at: folder)
    }
    private func setOffline(_ server: SyncMemoryServer, _ value: Bool) {
        server.lock.lock(); defer { server.lock.unlock() }; server.down = value
    }
    private func png(_ color: UIColor, side: CGFloat = 16) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { output in
            color.setFill(); output.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData())
    }
    private func until(_ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end { if done() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return done()
    }
    private func makeApp(_ server: SyncMemoryServer, _ seal: Seal) -> AppModel {
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        _ = keys.keep(seal, share: false)
        let made = AppModel(world: World(name: "owned", space: "local", spaces: [
            Space(id: "local", name: "Owned", emoji: "", tint: RGB(240, 240, 240))]), fixturesEnabled: false)
        made.sync.attach(made, setup: .init(base: URL(string: "https://sync.test")!, keys: keys,
            folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
            deviceName: "Owned iPhone", transport: server, ownWorld: false))
        if let engine = made.sync.engine { leases.append(OwnedLease(engine)) }
        app = made; return made
    }
    func testActualAccountIconArrivalReplacementTombstoneAndOfflineJournalRelaunch() async throws {
        let server = SyncMemoryServer(), seal = Seal.make(), owner = try TestMac(server: server, seal: seal)
        mac = owner; leases.append(OwnedLease(owner.client))
        let name = "owned-folder.png", red = try png(.red), green = try png(.green)
        try owner.write(SyncCollection.space, SyncCollection.firstSpace,
            SyncSpace(id: SyncCollection.firstSpace, name: "Owned", icon: "", order: "A").fields)
        try owner.write(SyncCollection.icon, name, ["data": .string(red.base64EncodedString())])
        owner.client.start()
        let uploaded = await until { owner.client.state == .live && owner.pending == 0 }; XCTAssertTrue(uploaded)
        let made = makeApp(server, seal)
        let hydrated = await until { made.sync.folderArtwork.image("image:" + name) != nil }; XCTAssertTrue(hydrated)
        let first = try XCTUnwrap(made.sync.folderArtwork.image("image:" + name)?.pngData())
        XCTAssertEqual(made.sync.engine?.icons().map(\.data), [red])
        XCTAssertNil(made.sync.folderArtwork.image("image:" + name, isPrivate: true), "Private never borrows account image pixels")
        try owner.write(SyncCollection.icon, name, ["data": .string(green.base64EncodedString())])
        let replaced = await until { made.sync.engine?.icons().first?.data == green && made.sync.folderArtwork.image("image:" + name)?.pngData() != first }
        XCTAssertTrue(replaced, "the actual remote batch invalidates the rendered image cache")
        made.sync.end(); XCTAssertNil(made.sync.folderArtwork.image("image:" + name))
        setOffline(server, true)
        let again = makeApp(server, seal)
        let restored = await until { again.sync.folderArtwork.image("image:" + name) != nil }; XCTAssertTrue(restored)
        XCTAssertEqual(again.sync.engine?.icons().map(\.data), [green], "hydration comes from the owned durable journal while the actual transport is offline")
        setOffline(server, false); again.sync.engine?.start()
        let disk = try Journal(path: folder.appendingPathComponent("journal/sync.sqlite").path, device: "read-only-test")
        XCTAssertEqual(disk.record(.init(collection: SyncCollection.icon, id: name))?["data"]?.string, green.base64EncodedString())
        try owner.journal.remove(.init(collection: SyncCollection.icon, id: name)); owner.client.kick()
        let gone = await until { again.sync.engine?.journal.record(.init(collection: SyncCollection.icon, id: name))?.alive() == false && again.sync.folderArtwork.image("image:" + name) == nil }
        XCTAssertTrue(gone)
    }
    func testPublicSiteIconSyncReplacementOfflineRestoreAndRemoval() async throws {
        let server = SyncMemoryServer(), seal = Seal.make(), owner = try TestMac(server: server, seal: seal)
        mac = owner; leases.append(OwnedLease(owner.client))
        let name = "site-example.png", red = try png(.red, side: 128), green = try png(.green, side: 128)
        let page = URL(string: "https://example.test/document")!
        try owner.write(SyncCollection.icon, name, ["data": .string(red.base64EncodedString()), "origin": .string("https://example.test")])
        owner.client.start()
        let uploaded = await until { owner.client.state == .live && owner.pending == 0 }
        XCTAssertTrue(uploaded)
        let made = makeApp(server, seal)
        let hydrated = await until { made.sync.folderArtwork.siteImage(for: page) != nil }
        XCTAssertTrue(hydrated)
        let first = try XCTUnwrap(made.sync.folderArtwork.siteImage(for: page)?.pngData())
        XCTAssertNil(made.sync.folderArtwork.siteImage(for: page, isPrivate: true))
        XCTAssertNil(made.sync.folderArtwork.siteImage(for: URL(string: "http://example.test/document")!))
        XCTAssertNil(made.sync.folderArtwork.siteImage(for: URL(string: "https://example.test:8443/document")!))
        try owner.write(SyncCollection.icon, name, ["data": .string(green.base64EncodedString()), "origin": .string("https://example.test")])
        let replaced = await until { made.sync.folderArtwork.siteImage(for: page)?.pngData() != first }
        XCTAssertTrue(replaced)
        made.sync.end()
        XCTAssertNil(made.sync.folderArtwork.siteImage(for: page))
        setOffline(server, true)
        let again = makeApp(server, seal)
        let restored = await until { again.sync.folderArtwork.siteImage(for: page) != nil }
        XCTAssertTrue(restored)
        setOffline(server, false); again.sync.engine?.start()
        try owner.journal.remove(.init(collection: SyncCollection.icon, id: name)); owner.client.kick()
        let gone = await until { again.sync.folderArtwork.siteImage(for: page) == nil }
        XCTAssertTrue(gone)
    }

    func testAccountReplacementAndLateOldAccountDeltaCannotExposeOldPixels() throws {
        let store = SyncFolderArtwork(), red = try png(.red), green = try png(.green)
        let key = "same.png"
        let a = try XCTUnwrap(SyncIcon(Record(collection: SyncCollection.icon, id: key, fields: ["data": .string(red.base64EncodedString())])))
        let b = try XCTUnwrap(SyncIcon(Record(collection: SyncCollection.icon, id: key, fields: ["data": .string(green.base64EncodedString())])))
        store.replace(account: "A", icons: [a]); let old = try XCTUnwrap(store.image("image:" + key)?.pngData())
        store.replace(account: "B", icons: []); XCTAssertNil(store.image("image:" + key))
        store.apply(account: "A", id: key, icon: a); XCTAssertNil(store.image("image:" + key))
        store.apply(account: "B", id: key, icon: b); XCTAssertNotEqual(store.image("image:" + key)?.pngData(), old)
        store.reset(); store.apply(account: "B", id: key, icon: b); XCTAssertNil(store.image("image:" + key))
    }
    func testMalformedOversizedNonPngAndOversizedPixelsCannotBecomeFolderArtwork() throws {
        let small = try png(.red)
        for name in ["../escape.png", ".hidden.png", "other/escape.png", "other\\escape.png", "other.svg", ""] {
            XCTAssertNil(SyncIcon(Record(collection: SyncCollection.icon, id: name, fields: ["data": .string(small.base64EncodedString())])))
        }
        XCTAssertNil(SyncIcon(Record(collection: SyncCollection.icon, id: "huge.png", fields: ["data": .string(Data(repeating: 1, count: 48_000).base64EncodedString())])))
        let store = SyncFolderArtwork()
        let invalid = try XCTUnwrap(SyncIcon(Record(collection: SyncCollection.icon, id: "bad.png", fields: ["data": .string(Data("not PNG".utf8).base64EncodedString())])))
        let wide = try XCTUnwrap(SyncIcon(Record(collection: SyncCollection.icon, id: "wide.png", fields: ["data": .string(try png(.red, side: 513).base64EncodedString())])))
        store.replace(account: "owned", icons: [invalid, wide])
        XCTAssertNil(store.image("image:bad.png")); XCTAssertNil(store.image("image:wide.png"))
        XCTAssertNil(store.image("future:unknown")); XCTAssertNil(MacIconMarks.image("future-unknown"))
    }
}

@MainActor
final class FolderArtworkVectorTests: XCTestCase {
    private var window: UIWindow?
    private weak var previous: UIWindow?
    override func tearDown() { window?.isHidden = true; window?.rootViewController = nil; window = nil; previous?.makeKey(); previous = nil }
    func testAllNinetyNineMacDrawingsProduceRealNonemptyTemplatePixels() throws {
        XCTAssertEqual(MacIconMarks.names.count, 99)
        for name in MacIconMarks.names {
            let image = try XCTUnwrap(MacIconMarks.image(name), name)
            XCTAssertEqual(image.renderingMode, .alwaysTemplate)
            let data = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
            XCTAssertTrue(data.contains { $0 > 0 }, name)
        }
    }
    func testActualWebKitRendersPinnedMacSvgWithTheSameNativePathSilhouette() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        previous = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene); window = owned; owned.frame = CGRect(x: 0, y: 0, width: 96, height: 120)
        let controller = UIViewController(); owned.rootViewController = controller; owned.makeKeyAndVisible()
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 24, height: 24), configuration: configuration)
        web.scrollView.contentInsetAdjustmentBehavior = .never; web.isOpaque = false; web.backgroundColor = .white
        controller.view.addSubview(web)
        for (name, body) in macSvg.sorted(by: { $0.key < $1.key }) {
            let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke-linecap='round' stroke-linejoin='round'>" + body + "</svg>"
            web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><title>\(name)</title><body style='margin:0;background:white'>\(svg)</body>", baseURL: nil)
            let end = Date().addingTimeInterval(5)
            while Date() < end, web.title != name || web.isLoading { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(web.title, name); XCTAssertFalse(web.isLoading)
            let settings = WKSnapshotConfiguration(); settings.rect = web.bounds
            let reference: UIImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: settings) { image, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: NSError(domain: "OwnedSvgSnapshot", code: 1)) }
                }
            }
            let native = try XCTUnwrap(MacIconMarks.image(name)).withTintColor(.black, renderingMode: .alwaysOriginal)
            let lhs = try bitmap(reference), rhs = try bitmap(native)
            var intersection = 0, union = 0
            for i in 0..<72 * 72 {
                // Compare actual ink coverage. Binary 127/128 rounding at a
                // half-pixel edge must not invent a different SVG silhouette.
                let a = 255 - Int(lhs[i * 4]), b = 255 - Int(rhs[i * 4])
                intersection += min(a, b); union += max(a, b)
            }
            XCTAssertGreaterThan(union, 50 * 255, name)
            XCTAssertGreaterThan(Double(intersection) / Double(max(1, union)), 0.9, "Exact Mac SVG \(name), independently rendered by native WebKit")
            for (label, image) in [("Mac SVG", reference), ("iPhone exact path", native)] {
                let attachment = XCTAttachment(image: image); attachment.name = "\(name): \(label)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
    func testSilhouetteCoverageRejectsAnActuallyShiftedKeyboardDrawing() throws {
        let image = try XCTUnwrap(MacIconMarks.image("keyboard")).withTintColor(.black, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let shifted = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { _ in
            image.draw(in: CGRect(x: 3, y: 0, width: 24, height: 24))
        }
        let lhs = try bitmap(image), rhs = try bitmap(shifted)
        var intersection = 0, union = 0
        for i in 0..<72 * 72 {
            let a = 255 - Int(lhs[i * 4]), b = 255 - Int(rhs[i * 4])
            intersection += min(a, b); union += max(a, b)
        }
        XCTAssertGreaterThan(union, 50 * 255)
        XCTAssertLessThan(Double(intersection) / Double(union), 0.9,
            "The unchanged silhouette threshold still rejects genuinely different path placement")
    }
    private func bitmap(_ image: UIImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: 72 * 72 * 4)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { output in
            UIColor.white.setFill(); output.fill(CGRect(x: 0, y: 0, width: 24, height: 24)); image.draw(in: CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let pixels = try XCTUnwrap(normalized.cgImage)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 72, height: 72, bitsPerComponent: 8, bytesPerRow: 72 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: 72, height: 72))
        }
        return bytes
    }
    // Pinned original SVG bodies, independent of the UIKit converter.
    private let macSvg: [String: String] = [
        "home": ##"<path d="M4 9.77313C4 9.2136 4 8.93383 4.07063 8.67517C4.1332 8.446 4.23609 8.22982 4.3745 8.03675C4.53071 7.81882 4.74784 7.6424 5.1821 7.28957L9.9821 3.38956C10.7014 2.80513 11.0611 2.51291 11.4609 2.40099C11.8135 2.30229 12.1865 2.30229 12.5391 2.40099C12.9389 2.51291 13.2986 2.80513 14.0179 3.38957L18.8179 7.28957C19.2522 7.6424 19.4693 7.81882 19.6255 8.03675C19.7639 8.22982 19.8668 8.446 19.9294 8.67517C20 8.93383 20 9.2136 20 9.77313V16.8C20 17.9201 20 18.4802 19.782 18.908C19.5903 19.2843 19.2843 19.5903 18.908 19.782C18.4802 20 17.9201 20 16.8 20H7.2C6.07989 20 5.51984 20 5.09202 19.782C4.71569 19.5903 4.40973 19.2843 4.21799 18.908C4 18.4802 4 17.9201 4 16.8V9.77313Z" stroke="#000" stroke-width="2" stroke-linejoin="round"></path>"##,
        "book": ##"<path d="M9 6C8.44772 6 8 6.44772 8 7C8 7.55228 8.44772 8 9 8V6ZM15 8C15.5523 8 16 7.55228 16 7C16 6.44772 15.5523 6 15 6V8ZM9 10C8.44772 10 8 10.4477 8 11C8 11.5523 8.44772 12 9 12V10ZM12 12C12.5523 12 13 11.5523 13 11C13 10.4477 12.5523 10 12 10V12ZM7 4H17V2H7V4ZM18 5V19H20V5H18ZM17 20H7V22H17V20ZM6 19V5H4V19H6ZM7 20C6.44771 20 6 19.5523 6 19H4C4 20.6569 5.34315 22 7 22V20ZM18 19C18 19.5523 17.5523 20 17 20V22C18.6569 22 20 20.6569 20 19H18ZM17 4C17.5523 4 18 4.44772 18 5H20C20 3.34315 18.6569 2 17 2V4ZM7 2C5.34315 2 4 3.34315 4 5H6C6 4.44772 6.44772 4 7 4V2ZM18 12V15H20V12H18ZM17 16H7V18H17V16ZM7 22H10V20H7V22ZM7 16C5.34315 16 4 17.3431 4 19H6C6 18.4477 6.44772 18 7 18V16ZM18 15C18 15.5523 17.5523 16 17 16V18C18.6569 18 20 16.6569 20 15H18ZM9 8H15V6H9V8ZM9 12H12V10H9V12Z" fill="#000"></path>"##,
        "calendar": ##"<path d="M4 7C4 5.89543 4.89543 5 6 5H18C19.1046 5 20 5.89543 20 7V18C20 19.1046 19.1046 20 18 20H6C4.89543 20 4 19.1046 4 18V7Z" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M4 10H20" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M8 5V3" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M16 5V3" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>"##,
        "crown": ##"<path d="M4.16831 17.4079L2 7L8 10L12 4L16 10L22 7L19.8317 17.4079C19.6385 18.3353 18.8211 19 17.8737 19H6.12628C5.17892 19 4.36153 18.3353 4.16831 17.4079Z" stroke="#000" stroke-width="2" stroke-linecap="square" stroke-linejoin="round"></path>"##,
        "keyboard": ##"<path d="M19.5 5.5H4.5C3.39543 5.5 2.5 6.39543 2.5 7.5V16.5C2.5 17.6046 3.39543 18.5 4.5 18.5H19.5C20.6046 18.5 21.5 17.6046 21.5 16.5V7.5C21.5 6.39543 20.6046 5.5 19.5 5.5Z" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M10 14H14" stroke="#000" stroke-width="2" stroke-linecap="round"></path><circle cx="6.75039" cy="13.9999" r="1.1" fill="#000"></circle><circle cx="6.75039" cy="9.9999" r="1.1" fill="#000"></circle><circle cx="17.2504" cy="9.9999" r="1.1" fill="#000"></circle><circle cx="13.7406" cy="9.9999" r="1.1" fill="#000"></circle><circle cx="10.2602" cy="9.9999" r="1.1" fill="#000"></circle><circle cx="17.2504" cy="13.9999" r="1.1" fill="#000"></circle>"##,
        "emoji.smileys": ##"<path d="M16.2159 14.9191C16.3118 14.7523 16.3477 14.5545 16.308 14.364C16.2684 14.1736 16.1576 14.007 15.9985 13.8998C15.8393 13.7925 15.6433 13.7524 15.4519 13.7871C15.2605 13.8218 15.0907 13.9294 14.972 14.0809C14.8981 14.1727 14.8222 14.2582 14.7416 14.3413C14.024 15.0857 13.0195 15.4772 12.0036 15.475C10.9877 15.4757 9.98262 15.0829 9.26224 14.3392C9.18134 14.2561 9.10515 14.1707 9.03083 14.079C8.91168 13.9278 8.7415 13.8208 8.54999 13.7867C8.35856 13.7525 8.16266 13.7933 8.00383 13.901C7.84499 14.0088 7.73472 14.1757 7.69568 14.3662C7.65658 14.5568 7.6931 14.7545 7.78949 14.921C7.87478 15.0645 7.96555 15.2011 8.06582 15.3356C8.95754 16.5537 10.4875 17.285 12.0023 17.275C13.5169 17.2876 15.0506 16.5568 15.9404 15.3349C16.0405 15.2 16.131 15.063 16.2159 14.9191Z" fill="#000"></path><path d="M10.75 9.9C10.75 11.0046 10.0784 11.75 9.25 11.75C8.42157 11.75 7.75 11.0046 7.75 9.9C7.75 8.79543 8.42157 8 9.25 8C10.0784 8 10.75 8.79543 10.75 9.9Z" fill="#000"></path><path d="M16.25 9.9C16.25 11.0046 15.5784 11.75 14.75 11.75C13.9216 11.75 13.25 11.0046 13.25 9.9C13.25 8.79543 13.9216 8 14.75 8C15.5784 8 16.25 8.79543 16.25 9.9Z" fill="#000"></path><circle cx="12" cy="12" r="9" stroke="#000" stroke-width="2"></circle>"##,
        "restore": ##"<path d="M4.4834 14.6667C5.58163 17.7738 8.54493 20 12.0282 20C16.4465 20 20.0282 16.4183 20.0282 12C20.0282 7.58172 16.4465 4 12.0282 4C8.93224 4 6.99986 5.5 4.99986 8" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M5 4V8H9" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>"##
    ]
}

@MainActor
final class FolderArtworkNativeTests: XCTestCase {
    private var window: UIWindow?
    private weak var previous: UIWindow?
    override func tearDown() { window?.isHidden = true; window?.rootViewController = nil; window = nil; previous?.makeKey(); previous = nil }
    private func check(dark: Bool) async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { output in
            UIColor.red.setFill(); output.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.pngData())
        let icon = try XCTUnwrap(SyncIcon(Record(collection: SyncCollection.icon, id: "owned.png", fields: ["data": .string(png.base64EncodedString())])))
        let artwork = SyncFolderArtwork(); artwork.replace(account: "owned-native", icons: [icon])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        previous = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene); owned.frame = CGRect(x: 0, y: 0, width: 320, height: 740); window = owned
        let marks: [String?] = [nil, "icon:home", "icon:code", "📊", "image:owned.png"]
        let host = UIHostingController(rootView: VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<5) { depth in
                // A folder's row as the spaces' pages nest it: its 22 mark
                // where icons start, 22 further in for each level.
                HStack(spacing: Metrics.Column.rowGap + Metrics.Column.rowIcon - Metrics.Column.folderIcon) {
                    FolderMark(mark: marks[depth], open: true, tint: RGB(238, 233, 226), dark: dark, artwork: artwork)
                    Text("Level \(depth + 1), a deliberately long original folder title").lineLimit(1)
                }
                .padding(.leading, Metrics.Column.rowPadding + CGFloat(depth) * Metrics.Column.folderIcon)
                .padding(.trailing, Metrics.Column.rowPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .frame(width: 296, height: 44).accessibilityIdentifier("art.folder.\(depth)")
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(dark ? Color.black : Color.white).environment(\.colorScheme, dark ? .dark : .light)
            .dynamicTypeSize(.accessibility5))
        host.safeAreaRegions = []; owned.rootViewController = host
        owned.overrideUserInterfaceStyle = dark ? .dark : .light; owned.makeKeyAndVisible()
        let end = Date().addingTimeInterval(5)
        while Date() < end, host.view.bounds.width == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        owned.layoutIfNeeded(); host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: owned.bounds).image { _ in
            XCTAssertTrue(owned.drawHierarchy(in: owned.bounds, afterScreenUpdates: true))
        }
        let imageScale = image.scale
        let pngSlot = CGRect(x: 12 + 12 + 4 * 22, y: 12 + 4 * 44 + 11, width: 22, height: 22)
        let actual = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: pngSlot.minX * imageScale, y: pngSlot.minY * imageScale,
            width: pngSlot.width * imageScale, height: pngSlot.height * imageScale)))
        var bytes = [UInt8](repeating: 0, count: actual.width * actual.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: actual.width, height: actual.height,
                bitsPerComponent: 8, bytesPerRow: actual.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(actual, in: CGRect(x: 0, y: 0, width: actual.width, height: actual.height))
        }
        var redPixels = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[i] > 200 && bytes[i + 1] < 50 && bytes[i + 2] < 50 && bytes[i + 3] > 200 { redPixels += 1 }
        }
        XCTAssertGreaterThan(redPixels, 80, "Actual account PNG is drawn in the fifth native folder slot, never tinted as a template")
        XCTAssertEqual(host.view.bounds.width, 320)
        let attachment = XCTAttachment(image: image); attachment.name = "Actual five-level Mac grid, original SVG, emoji, synced PNG and long-name fade, \(dark ? "dark" : "light"), XXXL"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testFiveLevelsRenderActualGridExactMacVectorsEmojiAndAccountPngInLight() async throws { try await check(dark: false) }
    func testFiveLevelsRenderActualGridExactMacVectorsEmojiAndAccountPngInDarkAtLargestText() async throws { try await check(dark: true) }
}
