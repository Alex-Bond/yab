import SwiftUI
import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class PinnedTabArtworkTests: XCTestCase {
    private func image(_ view: some View) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    func testStackRedrawsWhenASyncedSiteIconArrives() throws {
        let artwork = SyncFolderArtwork()
        artwork.replace(account: "icons", icons: [])
        let tab = Tab(id: "stack-site", title: "Example", site: "Example", icon: "example", url: "https://example.test")
        let stack = TabStackView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        stack.show(front: tab, back: nil, pictures: 0, artwork: artwork, picture: { _ in nil })
        let before = TabIcons.renders
        let pixels = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).pngData { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let icon = try XCTUnwrap(SyncIcon(Record(collection: SyncCollection.icon, id: "site-stack.png",
            fields: ["data": .string(pixels.base64EncodedString()), "origin": .string("https://example.test")])))
        artwork.apply(account: "icons", id: icon.id, icon: icon)
        stack.show(front: tab, back: nil, pictures: 0, artwork: artwork, picture: { _ in nil })
        XCTAssertEqual(TabIcons.renders, before + 1)
    }

    func testPinnedIconsUseTheMacDrawingEmojiAndUploadedImage() throws {
        let artwork = SyncFolderArtwork()
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }.pngData())
        let icon = try XCTUnwrap(SyncIcon(Record(collection: SyncCollection.icon, id: "workspace.png", fields: ["data": .string(png.base64EncodedString())])))
        artwork.replace(account: "test-account", icons: [icon])
        let symbol = try XCTUnwrap(MacIconMarks.names.first)
        for mark in ["icon:" + symbol, "🌻", "image:workspace.png"] {
            let synced = SyncTab(id: "pin", space: "s", url: "https://example.test/pin", title: "Website", pin: "E", name: "My workspace", customMark: mark)
            let tab = SyncMapping.tab(synced, id: "pin", old: nil, fixturesEnabled: false)
            let actual = try image(Favicon(icon: tab.icon, size: 32, mark: tab.customMark, artwork: artwork))
            let fallback = try image(Favicon(icon: tab.icon, size: 32))
            XCTAssertNotEqual(actual.pngData(), fallback.pngData(), "the custom mark must win over the site's icon: \(mark)")
            let attachment = XCTAttachment(image: actual)
            attachment.name = mark; attachment.lifetime = .keepAlways; add(attachment)
        }
        let marks = ["🌻", "icon:" + symbol, "image:workspace.png"]
        let board = HStack(spacing: 24) {
            ForEach(marks, id: \.self) { mark in
                VStack {
                    Favicon(icon: "example.test", size: 48, mark: mark, artwork: artwork)
                    Text("My workspace").font(.caption)
                }
            }
        }.padding(24).background(.white).environment(\.colorScheme, .light)
        let attachment = XCTAttachment(image: try image(board))
        attachment.name = "Pinned Mac icons on iPhone"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testImageArrivalReplacementAndAccountChangeInvalidateNativeIconCache() throws {
        let artwork = SyncFolderArtwork()
        artwork.replace(account: "account-a", icons: [])
        let synced = SyncTab(id: "pin", space: "s", url: "https://example.test", title: "Page", pin: "E", customMark: "image:icon.png")
        let tab = SyncMapping.tab(synced, id: "pin", old: nil, fixturesEnabled: false)
        let before = TabIcons.image(for: tab, size: 24, artwork: artwork)?.pngData()
        func upload(_ color: UIColor) throws {
            let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { c in
                color.setFill(); c.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            }.pngData())
            let icon = try XCTUnwrap(SyncIcon(Record(collection: SyncCollection.icon, id: "icon.png", fields: ["data": .string(data.base64EncodedString())])))
            artwork.apply(account: "account-a", id: icon.id, icon: icon)
        }
        try upload(.red)
        let red = TabIcons.image(for: tab, size: 24, artwork: artwork)?.pngData()
        XCTAssertNotEqual(red, before)
        try upload(.blue)
        XCTAssertNotEqual(TabIcons.image(for: tab, size: 24, artwork: artwork)?.pngData(), red)
        artwork.replace(account: "account-b", icons: [])
        XCTAssertEqual(TabIcons.image(for: tab, size: 24, artwork: artwork)?.pngData(), before)
    }
}
