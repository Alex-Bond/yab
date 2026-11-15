import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Fast

// The card under an answer for a file a turn made (ChatFileCard): what its
// line says, and, with YAB_FARM_OUT set, a picture of each kind to look at.
@MainActor
struct ChatFileCardTests {
    /// A folder of the files a task could have saved.
    static func files() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tall = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 800, height: 3000)
        let context = CGContext(consumer: CGDataConsumer(data: tall as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.35, alpha: 1)
        context.fill(CGRect(x: 60, y: 2860, width: 520, height: 40))
        context.setFillColor(gray: 0.8, alpha: 1)
        for line in 0..<120 { context.fill(CGRect(x: 60, y: 2800 - line * 22, width: line % 5 == 4 ? 380 : 680, height: 8)) }
        context.endPDFPage()
        context.closePDF()
        try PageSave.pages(tall as Data)!.write(to: folder.appendingPathComponent("Room for ambition.pdf"))
        try "# Room for ambition\n\nKarri writes about the room a team leaves for ambition.\n".write(to: folder.appendingPathComponent("Room for ambition.md"), atomically: true, encoding: .utf8)
        try "<!DOCTYPE html><html><body><h1>Room for ambition</h1></body></html>".write(to: folder.appendingPathComponent("Room for ambition.html"), atomically: true, encoding: .utf8)
        let image = NSImage(size: NSSize(width: 160, height: 912), flipped: false) { rect in
            NSColor(calibratedRed: 0.75, green: 0.88, blue: 1, alpha: 1).setFill(); rect.fill(); return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("Room for ambition.png"))
        return folder
    }

    @Test func linesSayWhatIsInside() throws {
        let folder = try Self.files()
        let pdf = ChatFileCard.About.line(folder.appendingPathComponent("Room for ambition.pdf"))
        #expect(pdf.hasPrefix("3 pages · "))
        #expect(ChatFileCard.About.line(folder.appendingPathComponent("Room for ambition.md")).hasPrefix("14 words · "))
        #expect(ChatFileCard.About.line(folder.appendingPathComponent("Room for ambition.html")).hasPrefix("HTML page · "))
        #expect(ChatFileCard.About.line(folder.appendingPathComponent("Room for ambition.png")).hasPrefix("160 × 912 · "))
        #expect(ChatFileCard.format(URL(fileURLWithPath: "/a/b.pdf"))?.word == "PDF")
        #expect(ChatFileCard.format(URL(fileURLWithPath: "/a/b.png")) == nil)
    }

    /// Each kind drawn as the chat draws it, light and dark, into the job's
    /// folder: Room for ambition.pdf, .md, .html, .png and one moved away.
    @Test func picturesOfEachKind() async throws {
        guard let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] else { return }
        let folder = try Self.files()
        let paths = ["pdf", "html", "md", "png"].map { folder.appendingPathComponent("Room for ambition.\($0)").path } + ["/nowhere/Old page.pdf"]
        for dark in [false, true] {
            var cards: [ChatFileCard.About] = []
            for path in paths { cards.append(await ChatFileCard.About.read(URL(fileURLWithPath: path))) }
            let view = VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    ChatFileCard(path: path, group: paths, preread: cards[index])
                }
            }
            .padding(24)
            .background(Palette.ground)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = renderer.nsImage.flatMap { NSBitmapImageRep(data: $0.tiffRepresentation!)?.representation(using: .png, properties: [:]) }
            }
            try #require(data).write(to: URL(fileURLWithPath: out).appendingPathComponent(dark ? "cards-dark.png" : "cards-light.png"))
        }
    }
}
