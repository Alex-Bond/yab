import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Production chat views with an ordinary non-fixture AppModel. The supplied
/// words are render fixtures, not a claim of a provider answer or task effect.
@MainActor
final class ChatPageFeedbackTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var apps: [AppModel] = []
    private var previousKey: UIWindow?

    override func tearDown() {
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
        windows = []; apps = []
        previousKey?.makeKey(); previousKey = nil
    }

    private func live() -> AppModel {
        let world = World(name: "owned-chat-page", space: "owned", spaces: [
            Space(id: "owned", name: "Owned public space", emoji: "", tint: RGB(238, 233, 226))
        ])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        apps.append(app)
        return app
    }

    private func host(_ app: AppModel, large: Bool = false, colorScheme: ColorScheme = .light) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let controller = UIHostingController(rootView: ZStack {
            Color(uiColor: UIColor.magenta).ignoresSafeArea()
            ChatsLayer().environment(app)
        }.preferredColorScheme(colorScheme).environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, large ? .accessibility5 : .large))
        controller.view.backgroundColor = UIColor.magenta
        window.rootViewController = controller
        windows.append(window); window.makeKeyAndVisible(); controller.view.layoutIfNeeded()
        return window
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func descendants<T: UIView>(_ root: UIView, _ kind: T.Type) -> [T] {
        let current = (root as? T).map { [$0] } ?? []
        return current + root.subviews.flatMap { descendants($0, kind) }
    }

    private func shot(_ window: UIWindow, _ name: String) -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }

    private func pixel(_ image: UIImage, _ point: CGPoint) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))); return true
        }
        XCTAssertTrue(drawn)
        let x = min(cg.width - 1, max(0, Int(point.x * image.scale)))
        let y = min(cg.height - 1, max(0, Int(point.y * image.scale)))
        let offset = (y * cg.width + x) * 4
        return Array(bytes[offset..<offset + 4])
    }

    private func opaqueEdges(_ image: UIImage) throws {
        for point in [CGPoint(x: 2, y: 100), CGPoint(x: 400, y: 100), CGPoint(x: 2, y: 850), CGPoint(x: 400, y: 850)] {
            let color = try pixel(image, point)
            XCTAssertGreaterThan(color[1], 225, "the magenta page is still visible at \(point)")
            XCTAssertLessThan(abs(Int(color[0]) - Int(color[1])), 12)
            XCTAssertEqual(color[3], 255)
        }
    }

    func testMarkdownUsesActualInlineAttributesAndReadableBlocksWithoutLiteralMarks() {
        let source = "# Title\n\n- **Bold** and `code` with [source](https://example.com/read)\n\n```swift\nlet x = 1\n```\n\n| Name | Value |\n| --- | --- |\n| A | **2** |"
        let blocks = ChatMarkdown.blocks(source)
        XCTAssertEqual(blocks, [.heading("Title"), .item("**Bold** and `code` with [source](https://example.com/read)", mark: "•"),
                                .code("let x = 1"), .table([["Name", "Value"], ["A", "**2**"]])])
        let rich = ChatMarkdown.inline("**Bold** and `code` with [source](https://example.com/read)")
        XCTAssertEqual(String(rich.characters), "Bold and code with source")
        XCTAssertTrue(rich.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(rich.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(rich.runs.contains { $0.link?.absoluteString == "https://example.com/read" })
        XCTAssertEqual(ChatMarkdown.plain("# Title\n\n**A** [source](https://example.com)"), "Title\nA source")
        XCTAssertEqual(ChatMarkdown.plain("<b>Legacy bold</b>"), "Legacy bold")
    }

    func testStreamingIncompleteMarkupAndCustomSchemeLinksCannotBecomeActions() {
        XCTAssertEqual(ChatMarkdown.blocks("A **unfinished", streaming: true), [.words("A ")])
        XCTAssertEqual(ChatMarkdown.blocks("A [source](https://example", streaming: true), [.words("A ")])
        XCTAssertEqual(ChatMarkdown.blocks("| A | B |\n| --- | --- |\n| unfinished", streaming: true), [.table([["A", "B"]])])
        for text in ["[command](yab://run)", "[file](file:///private/tmp/owned)", "[script](javascript:alert(1))"] {
            XCTAssertFalse(ChatMarkdown.inline(text).runs.contains { $0.link != nil })
        }
    }

    func testNewChatIsAnOpaqueFullPageBeforeAnySendAndExtendsBehindKeyboard() async throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = live(), page = app.browser.tab
        app.newChat(focus: false)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        XCTAssertTrue(app.chatSheet.fresh.contains(id))
        XCTAssertEqual(app.chatSheet.pose.t, 1)
        XCTAssertTrue(app.chats.chat(id)?.messages.isEmpty == true)
        let window = try host(app)
        let ready = await until { !self.descendants(window, UITextField.self).isEmpty }
        XCTAssertTrue(ready)
        try opaqueEdges(shot(window, "production-new-chat-opaque-page"))
        app.chatSheet.keyboard = 302; app.chatSheet.pose.k = 302
        window.layoutIfNeeded()
        let resized = await until {
            self.descendants(window, UITextField.self).contains { $0.convert($0.bounds, to: window).maxY < 572 }
        }
        XCTAssertTrue(resized, "the actual compose control did not rise above the keyboard endpoint")
        let keyboardPose = SheetGeometry(screen: window.bounds.size, pose: app.chatSheet.pose, origin: nil,
                                         now: SheetGeometry.nowShape(screen: window.bounds.size), tray: true)
        XCTAssertEqual(keyboardPose.rest.rect.maxY, 572)
        XCTAssertEqual(keyboardPose.rest.bottom, 0)
        XCTAssertEqual(keyboardPose.underKeyboard, 302)
        try opaqueEdges(shot(window, "production-new-chat-keyboard-extension"))
        XCTAssertEqual(app.browser.tab, page)
    }

    func testLargestProductionConversationScrollerContinuesUnderHeaderAndInput() async throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = live()
        let words = (0..<30).map { "## Section \($0)\n\n**Readable answer** with `code` and a long paragraph that wraps at the largest accessibility size." }.joined(separator: "\n\n")
        app.chats.add(Chat(id: "owned-long", title: "Owned readable conversation", day: .today, time: "Now", by: .iphone,
                           messages: [Message(role: .you, text: "Owned question"), Message(role: .answer, text: words, by: .iphone)]))
        app.openChat("owned-long")
        let window = try host(app, large: true)
        let ready = await until { self.descendants(window, UIScrollView.self).contains { $0.contentSize.height > $0.bounds.height * 2 } }
        XCTAssertTrue(ready)
        let scroll = try XCTUnwrap(descendants(window, UIScrollView.self).first { $0.contentSize.height > $0.bounds.height * 2 })
        let frame = scroll.convert(scroll.bounds, to: window)
        XCTAssertLessThanOrEqual(frame.minY, 1, "the scroll view stops below the header")
        XCTAssertGreaterThanOrEqual(frame.maxY, 873, "the scroll view stops above the input")
        XCTAssertEqual(app.chatSheet.pose.t, 1)
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        try opaqueEdges(shot(window, "production-largest-chat-scrolled-under-controls"))
        XCTAssertTrue(app.chats.chat("owned-long")?.messages.last?.text == words)
    }

    func testNativeMenuActionsRefuseAStaleChatOwnerAndPreserveActualPinAction() throws {
        let app = live()
        app.chats.add(Chat(id: "owned-first", title: "First", day: .today, time: "Now"))
        app.chats.add(Chat(id: "owned-next", title: "Next", day: .today, time: "Now"))
        app.openChat("owned-first")
        let menu = ChatNativeMenu.menu(chat: "owned-first", app: app)
        let pin = try XCTUnwrap(menu.children.first { $0.title == "Pin Chat" } as? UIAction)
        let button = UIButton(type: .system)
        app.openChat("owned-next"); button.sendAction(pin)
        XCTAssertFalse(try XCTUnwrap(app.chats.chat("owned-first")).pinned)
        XCTAssertFalse(try XCTUnwrap(app.chats.chat("owned-next")).pinned)
        app.openChat("owned-first"); button.sendAction(pin)
        XCTAssertTrue(try XCTUnwrap(app.chats.chat("owned-first")).pinned)
        app.closeSheet(); button.sendAction(pin)
        XCTAssertTrue(try XCTUnwrap(app.chats.chat("owned-first")).pinned, "an inactive menu action changed the closed chat")
    }
    func testNativeMoreControlUsesTheActualDarkTraitAndFortyFourPointTarget() async throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = live()
        app.chats.add(Chat(id: "owned-dark", title: "Owned dark chat", day: .today, time: "Now"))
        app.openChat("owned-dark")
        let window = try host(app, colorScheme: .dark)
        let ready = await until { !self.descendants(window, ChatMenuControl.self).isEmpty }
        XCTAssertTrue(ready)
        let button = try XCTUnwrap(descendants(window, ChatMenuControl.self).first)
        XCTAssertEqual(button.traitCollection.userInterfaceStyle, .dark)
        XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        let color = try XCTUnwrap(button.configuration?.baseForegroundColor).resolvedColor(with: button.traitCollection)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertGreaterThan(red, 0.8); XCTAssertGreaterThan(green, 0.8); XCTAssertGreaterThan(blue, 0.8)
        _ = shot(window, "production-dark-native-more-control")
    }

    func testTheSameActualScrollViewSurvivesFullCompactReverseAndKeyboardResize() async throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = live()
        let text = (0..<30).map { "Owned paragraph \($0). **Readable text** long enough to scroll without a provider." }.joined(separator: "\n\n")
        app.chats.add(Chat(id: "owned-scroll", title: "Owned scroll", day: .today, time: "Now", messages: [Message(role: .answer, text: text)]))
        app.openChat("owned-scroll")
        let window = try host(app)
        let ready = await until { self.descendants(window, UIScrollView.self).contains { $0.contentSize.height > 1000 } }
        XCTAssertTrue(ready)
        let original = try XCTUnwrap(descendants(window, UIScrollView.self).first { $0.contentSize.height > 1000 })
        var observations: [[String: Any]] = []
        func record(_ phase: String, expected: CGRect? = nil) {
            func rect(_ value: CGRect) -> [String: Double] {
                ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
            }
            let mounted = self.descendants(window, UIScrollView.self)
            var row: [String: Any] = [
                "phase": phase, "poseT": app.chatSheet.pose.t, "poseH": app.chatSheet.pose.h,
                "poseK": app.chatSheet.pose.k, "poseO": app.chatSheet.pose.o,
                "poseP": app.chatSheet.pose.p, "poseE": app.chatSheet.pose.e,
                "window": rect(window.bounds), "originalMounted": mounted.contains { $0 === original },
                "originalFrame": rect(original.convert(original.bounds, to: window)),
                "offsetY": original.contentOffset.y, "contentHeight": original.contentSize.height,
                "scrollers": mounted.map { view in
                    ["original": view === original, "class": String(describing: type(of: view)),
                     "frame": rect(view.convert(view.bounds, to: window)), "bounds": rect(view.bounds),
                     "offsetY": view.contentOffset.y, "contentHeight": view.contentSize.height] as [String: Any]
                }
            ]
            if let expected { row["expected"] = rect(expected) }
            var ancestry: [[String: Any]] = []
            var parent = original.superview
            while let view = parent {
                ancestry.append(["class": String(describing: type(of: view)),
                                 "frame": rect(view.convert(view.bounds, to: window)),
                                 "bounds": rect(view.bounds), "clips": view.clipsToBounds])
                parent = view.superview
            }
            row["ancestry"] = ancestry
            observations.append(row)
        }
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "production-chat-native-scroll-phases"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        record("opened")
        original.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        record("reading-at-180")
        for pose in [0.6, 0.25, 0.7, 1.0] {
            app.chatSheet.pose.t = pose
            window.layoutIfNeeded()
            let expected = SheetGeometry(screen: window.bounds.size, pose: app.chatSheet.pose, origin: nil,
                now: SheetGeometry.nowShape(screen: window.bounds.size), tray: true).current.rect
            let retained = await until {
                let frame = original.convert(original.bounds, to: window)
                return self.descendants(window, UIScrollView.self).contains { $0 === original }
                    && abs(frame.minY - expected.minY) < 1 && abs(frame.height - expected.height) < 1
            }
            record("pose-\(pose)", expected: expected)
            if !retained { _ = shot(window, "production-chat-native-scroll-pose-\(pose)") }
            XCTAssertTrue(retained, "changing the page/glass endpoint rebuilt the scroller or left its native frame stale")
        }
        XCTAssertEqual(original.contentOffset.y, 180, accuracy: 1)
        app.chatSheet.pose.k = 302
        window.layoutIfNeeded()
        let keyboardResized = await until {
            self.descendants(window, UIScrollView.self).contains { $0 === original }
                && abs(original.convert(original.bounds, to: window).maxY - 572) < 1
        }
        record("keyboard-302", expected: CGRect(x: 0, y: 0, width: 402, height: 572))
        XCTAssertTrue(keyboardResized)
        XCTAssertEqual(original.contentOffset.y, 180, accuracy: 1)
        _ = shot(window, "production-chat-scroll-owner-after-reverse-keyboard")
    }

    func testActualNativeMenuRetiresItsPresentedOwnerBeforeTheNextChatMenu() async throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = live()
        for id in ["owned-presented", "owned-replacement"] {
            app.chats.add(Chat(id: id, title: id, day: .today, time: "Now"))
        }
        app.openChat("owned-presented")
        let window = try host(app)
        let mounted = await until { self.descendants(window, ChatMenuControl.self).contains { $0.owner == "owned-presented" } }
        XCTAssertTrue(mounted)
        let original = try XCTUnwrap(descendants(window, ChatMenuControl.self).first { $0.owner == "owned-presented" })
        original.performPrimaryAction()
        let displayed = await until { original.visible && app.chatSheet.moreMenu }
        XCTAssertTrue(displayed, "UIKit did not actually present the first native menu")
        _ = shot(window, "production-menu-before-owner-replacement")
        app.openChat("owned-replacement")
        let retired = await until { (!original.visible || original.window == nil) && !app.chatSheet.moreMenu && app.chatSheet.chatID == "owned-replacement" }
        XCTAssertTrue(retired)
        let replacement = try XCTUnwrap(descendants(window, ChatMenuControl.self).first { $0.owner == "owned-replacement" })
        replacement.performPrimaryAction()
        let nextDisplayed = await until { replacement.visible && app.chatSheet.moreMenu }
        XCTAssertTrue(nextDisplayed, "the new owner's actual menu could not present after the old one retired")
        XCTAssertEqual(app.chatSheet.chatID, "owned-replacement")
        app.chatSheet.moreMenu = false
        let dismissed = await until { !replacement.visible && !app.chatSheet.moreMenu }
        XCTAssertTrue(dismissed)
        XCTAssertEqual(app.chatSheet.chatID, "owned-replacement")
        _ = shot(window, "production-menu-after-replacement-dismissal")
    }

}
