import Network
import UIKit
import XCTest

/// A picture pinched larger on a page grows, even where the
/// page says user-scalable=no (Google Images' viewer does), and stays as
/// bright as it was (row 963).
final class ImageZoomTests: XCTestCase {
    private var site: ImageZoomSite!
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        folder = URL(fileURLWithPath: "/tmp/yab-image-zoom-\(UUID().uuidString)")
        site = try ImageZoomSite()
        let ready = expectation(description: "image site ready")
        site.ready = { ready.fulfill() }
        site.start()
        wait(for: [ready], timeout: 10)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        site?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func testPinchingAPictureKeepsThePageBright() throws {
        launch(site.url("picture"))
        XCTAssertTrue(app.webViews.staticTexts["Picture page"].waitForExistence(timeout: 15))
        let page = app.webViews.firstMatch
        settle()
        let picture = page.images["Picture"]
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        let small = picture.frame.width
        let before = app.screenshot()
        record(before, "1 before pinch")
        let start = brightness(before)
        page.pinch(withScale: 3, velocity: 2)
        settle()
        let zoomed = app.screenshot()
        record(zoomed, "2 after pinch out")
        let after = brightness(zoomed)
        let large = picture.frame.width
        page.pinch(withScale: 0.5, velocity: -2)
        settle()
        let back = app.screenshot()
        record(back, "3 after pinch in")
        let note = XCTAttachment(string: "picture width before=\(small) zoomed=\(large); page middle brightness before=\(start) zoomed=\(after) back=\(brightness(back))")
        note.name = "brightness"; note.lifetime = .keepAlways; add(note)
        // The picture is mid gray and white around it; a scrim of .2 or more
        // would take a quarter of its light.
        XCTAssertGreaterThan(large, small * 1.5, "a user-scalable=no page did not zoom: \(small) -> \(large)")
        XCTAssertGreaterThan(after, start * 0.85, "the zoomed page went dark: \(start) -> \(after)")
    }

    private func launch(_ url: URL) {
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", url.absoluteString, "-YabNoAnim", "NO"]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        app.passWelcome(timeout: 10)
        let input = app.textFields["field.input"]
        if input.waitForExistence(timeout: 3) { app.closeField() }
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(1.5)) }

    private func record(_ shot: XCUIScreenshot, _ name: String) {
        let image = XCTAttachment(screenshot: shot)
        image.name = name; image.lifetime = .keepAlways; add(image)
        // The job's folder, so the pictures come home with its outputs.
        let dir = Atlas.out.appendingPathComponent("shots/zoom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: dir.appendingPathComponent(name.replacingOccurrences(of: " ", with: "-") + ".png"))
    }

    /// Mean light of the screen's middle band (between the status bar and
    /// the chrome), 0 black to 1 white.
    private func brightness(_ shot: XCUIScreenshot) -> Double {
        guard let image = shot.image.cgImage else { return 0 }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0, count = 0.0
        for y in stride(from: height / 4, to: height * 3 / 4, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let i = (y * width + x) * 4
                total += (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
                count += 1
            }
        }
        return count > 0 ? total / count : 0
    }
}

/// A loopback page with one picture, as an image search's result shows it.
final class ImageZoomSite: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.image-zoom-site")
    private var connections: [NWConnection] = []
    var ready: (() -> Void)?
    private var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }

    init() throws {
        let options = NWParameters.tcp
        options.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: options)
    }
    func url(_ route: String) -> URL { baseURL.appendingPathComponent(route) }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready?() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, bytes: Data())
        }
        listener.start(queue: queue)
    }
    func stop() { queue.sync { connections.forEach { $0.cancel() }; connections.removeAll(); listener.cancel() } }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var all = bytes
            if let chunk { all.append(chunk) }
            guard all.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil { connection.cancel() } else { self.receive(connection, bytes: all) }
                return
            }
            let target = String(decoding: all, as: UTF8.self).components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = URL(string: target, relativeTo: self.baseURL)?.path ?? "/"
            let (type, body) = path == "/picture.svg" ? ("image/svg+xml", Self.svg) : ("text/html; charset=utf-8", Self.html)
            let data = Data(body.utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    private static let html = """
    <!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no'><title>Picture</title>
    <style>body{margin:0;background:#fff;font:16px -apple-system;color:#111}h1{font-size:18px;margin:70px 16px 12px}img{display:block;width:100%}</style>
    </head><body><h1>Picture page</h1><img src='/picture.svg' alt='Picture'><p style='margin:16px'>A result of an image search.</p></body></html>
    """

    private static let svg = """
    <svg xmlns='http://www.w3.org/2000/svg' width='800' height='1000' viewBox='0 0 800 1000'>
    <rect width='800' height='1000' fill='#9a9a9a'/><circle cx='400' cy='500' r='260' fill='#e8c26a'/>
    <rect x='120' y='120' width='160' height='160' fill='#5aa0e6'/></svg>
    """
}
