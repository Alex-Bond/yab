import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Actual production scrolling with owned text, without a provider or fixture world.
@MainActor
final class ChatScrollFollowTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?

    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil
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

    private func scrollers(_ view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollers)
    }

    private func host(_ app: AppModel) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let controller = UIHostingController(rootView: ChatsLayer().environment(app))
        owned.rootViewController = controller; window = owned; owned.makeKeyAndVisible()
        controller.view.layoutIfNeeded(); return owned
    }

    private func text(_ start: Int, _ count: Int) -> String {
        (start..<(start + count)).map { "Owned paragraph \($0). **Readable growing words** long enough to wrap and scroll in the real production transcript." }
            .joined(separator: "\n\n")
    }

    private func end(_ view: UIScrollView) -> CGFloat {
        max(-view.adjustedContentInset.top, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
    }

    func testActualGrowingTurnsFollowTheEndButPreserveReadingOffsetAndKeyboardResize() async throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let world = World(name: "owned-scroll-follow", space: "owned", spaces: [
            Space(id: "owned", name: "Owned public space", emoji: "", tint: RGB(238, 233, 226))
        ])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        app.chats.add(Chat(id: "owned-follow", title: "Owned growing transcript", day: .today, time: "Now",
                           messages: [Message(role: .answer, text: text(0, 24))]))
        app.openChat("owned-follow")
        let host = try host(app)
        let opened = await until {
            self.scrollers(host).contains { $0.contentSize.height > 1500 && abs($0.contentOffset.y - self.end($0)) < 1 }
        }
        XCTAssertTrue(opened, "the actual transcript did not open at its newest words")
        let scroll = try XCTUnwrap(scrollers(host).first { $0.contentSize.height > 1500 })
        var height = scroll.contentSize.height
        app.chats.update("owned-follow") { $0.messages[0].text += "\n\n" + text(24, 12) }
        let followed = await until {
            scroll.contentSize.height > height + 300 && abs(scroll.contentOffset.y - self.end(scroll)) < 1
        }
        XCTAssertTrue(followed, "new words must stay in view while the reader is at the end")
        XCTAssertTrue(scrollers(host).contains { $0 === scroll })

        // A real animated native scroll gives the production geometry callback
        // each intervening offset, rather than batching a jump with the next resize.
        scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: true)
        let reading = await until { abs(scroll.contentOffset.y - 180) < 1 }
        XCTAssertTrue(reading)
        height = scroll.contentSize.height
        app.chats.update("owned-follow") { $0.messages[0].text += "\n\n" + text(36, 12) }
        let grewAbove = await until { scroll.contentSize.height > height + 300 }
        XCTAssertTrue(grewAbove)
        XCTAssertEqual(scroll.contentOffset.y, 180, accuracy: 1, "new text stole the actual older reading position")
        app.chatSheet.pose.k = 302
        let keyboard = await until { abs(scroll.convert(scroll.bounds, to: host).maxY - 572) < 1 }
        XCTAssertTrue(keyboard)
        XCTAssertEqual(scroll.contentOffset.y, 180, accuracy: 1, "keyboard resize stole the actual older reading position")
        XCTAssertTrue(scrollers(host).contains { $0 === scroll })

        scroll.setContentOffset(CGPoint(x: 0, y: end(scroll)), animated: true)
        let returned = await until { abs(scroll.contentOffset.y - self.end(scroll)) < 1 }
        XCTAssertTrue(returned)
        height = scroll.contentSize.height
        app.chats.update("owned-follow") { $0.messages[0].text += "\n\n" + text(48, 12) }
        let followedAgain = await until {
            scroll.contentSize.height > height + 300 && abs(scroll.contentOffset.y - self.end(scroll)) < 1
        }
        XCTAssertTrue(followedAgain, "returning to the actual end must resume following new words")

        // A different chat owns fresh follow state even if the previous reader
        // was away from the end when the current owner changed.
        scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: true)
        let readAgain = await until { abs(scroll.contentOffset.y - 180) < 1 }
        XCTAssertTrue(readAgain)
        let previousHeight = scroll.contentSize.height
        app.chats.add(Chat(id: "owned-next-follow", title: "Owned next transcript", day: .today, time: "Now",
                           messages: [Message(role: .answer, text: text(0, 84))]))
        app.openChat("owned-next-follow")
        let replacementOpened = await until {
            self.scrollers(host).contains { $0.contentSize.height > previousHeight + 300 && abs($0.contentOffset.y - self.end($0)) < 1 }
        }
        XCTAssertTrue(replacementOpened)
        XCTAssertEqual(app.chatSheet.chatID, "owned-next-follow")
        let replacement = try XCTUnwrap(scrollers(host).first { $0.contentSize.height > previousHeight + 300 })
        let replacementHeight = replacement.contentSize.height
        app.chats.update("owned-next-follow") { $0.messages[0].text += "\n\n" + text(84, 12) }
        let replacementFollows = await until {
            replacement.contentSize.height > replacementHeight + 300 && abs(replacement.contentOffset.y - self.end(replacement)) < 1
        }
        XCTAssertTrue(replacementFollows, "the new owner inherited the prior chat's stopped follow state")
        let image = UIGraphicsImageRenderer(bounds: host.bounds).image { _ in
            host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "actual-transcript-resumed-following-over-keyboard"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testTheNativeEndReaderRefusesAnotherOwnerAmbiguityDetachedAndRetiredViews() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let controller = UIViewController()
        owned.rootViewController = controller; window = owned; owned.makeKeyAndVisible()
        let viewport = UIView(frame: CGRect(x: 8, y: 400, width: 386, height: 466))
        controller.view.addSubview(viewport)
        let transcript = UIScrollView(frame: viewport.bounds)
        transcript.contentInsetAdjustmentBehavior = .never
        transcript.contentSize = CGSize(width: 386, height: 1600)
        viewport.addSubview(transcript)
        // Other real scrollers may coexist but are not transcript registrations.
        let input = UITextView(frame: CGRect(x: 16, y: 400, width: 320, height: 50))
        viewport.addSubview(input)
        var revealed = true
        let reader = ChatViewportEndReader(owner: "owned-reader", eligible: { _ in revealed })
        reader.mount(viewport)
        let access = reader.access
        let token = UUID()
        access.register(token, "owned-reader", transcript)
        transcript.contentOffset.y = 180
        XCTAssertEqual(access.atEnd("owned-reader"), false)
        transcript.contentOffset.y = 1600 - transcript.bounds.height
        XCTAssertEqual(access.atEnd("owned-reader"), true)
        XCTAssertNil(access.atEnd("another-owner"))
        revealed = false
        XCTAssertNil(access.atEnd("owned-reader"), "Info/list/closed route eligibility must not borrow a retained body")
        revealed = true
        let duplicate = UUID()
        access.register(duplicate, "owned-reader", transcript)
        XCTAssertEqual(access.atEnd("owned-reader"), true, "two markers for the same actual view are not two scrollers")
        let other = UIScrollView(frame: viewport.bounds)
        viewport.addSubview(other)
        let otherToken = UUID()
        access.register(otherToken, "owned-reader", other)
        XCTAssertNil(access.atEnd("owned-reader"), "ambiguous actual transcript bindings must use the existing fallback")
        access.unregister(otherToken)
        transcript.removeFromSuperview()
        XCTAssertNil(access.atEnd("owned-reader"))
        viewport.addSubview(transcript)
        var frames: [CGRect] = []
        let field = ChatFieldWindowMarker(frame: CGRect(x: 20, y: 300, width: 200, height: 24))
        viewport.addSubview(field)
        field.configure(owner: "owned-reader", access: access) { _, frame in frames.append(frame) }
        field.reportWindowFrame()
        XCTAssertEqual(frames.last, field.convert(field.bounds, to: owned))
        let count = frames.count
        let otherField = ChatFieldWindowMarker(frame: CGRect(x: 20, y: 330, width: 200, height: 24))
        viewport.addSubview(otherField)
        otherField.configure(owner: "owned-reader", access: access) { _, _ in XCTFail("ambiguous field emitted") }
        field.reportWindowFrame(); otherField.reportWindowFrame()
        XCTAssertEqual(frames.count, count, "ambiguous native field bindings must not publish a guessed origin")
        otherField.retire()
        field.reportWindowFrame()
        XCTAssertEqual(frames.count, count + 1)
        reader.update(owner: "next-reader", eligible: { _ in true })
        field.reportWindowFrame()
        XCTAssertEqual(frames.count, count + 1, "a stale field owner survived the viewport owner change")
        XCTAssertNil(access.atEnd("owned-reader"))
        XCTAssertNil(access.atEnd("next-reader"), "changing owner must discard the previous transcript registration")
        access.register(token, "owned-reader", transcript)
        XCTAssertNil(access.atEnd("next-reader"))
        access.register(token, "next-reader", transcript)
        XCTAssertEqual(access.atEnd("next-reader"), true)
        reader.retire()
        access.register(token, "next-reader", transcript)
        XCTAssertNil(access.atEnd("next-reader"), "retired controller closures cannot revive a native binding")
        field.reportWindowFrame()
        XCTAssertEqual(frames.count, count + 1)
        field.retire()
    }

    func testTheActualChatFieldFrameRemainsAWindowRectThroughCompactAndKeyboardPoses() async throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let world = World(name: "owned-field-window", space: "owned", spaces: [
            Space(id: "owned", name: "Owned public space", emoji: "", tint: RGB(238, 233, 226))
        ])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        app.chats.add(Chat(id: "owned-field-window", title: "Owned field coordinates", day: .today, time: "Now",
                           messages: [Message(role: .answer, text: text(0, 12))]))
        app.openChat("owned-field-window")
        let owned = try host(app)
        func fields(_ view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        var phases: [[String: Double]] = []
        defer {
            if let bytes = try? JSONSerialization.data(withJSONObject: phases, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
                attachment.name = "production-chat-field-actual-window-origin"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for (pose, keyboard) in [(1.0, 0.0), (0.6, 0.0), (0.25, 0.0), (1.0, 302.0)] {
            app.chatSheet.pose.t = pose
            app.chatSheet.pose.k = keyboard
            let ready = await until {
                guard let field = fields(owned).first(where: { $0.bounds.width > 100 }) else { return false }
                let native = field.convert(field.bounds, to: owned)
                let saved = app.chatSheet.fieldFrame
                return native.height > 0 && abs(native.minX - saved.minX) < 1 && abs(native.minY - saved.minY) < 1
                    && abs(native.width - saved.width) < 1 && abs(native.height - saved.height) < 1
            }
            let field = try XCTUnwrap(fields(owned).first { $0.bounds.width > 100 })
            let native = field.convert(field.bounds, to: owned)
            let saved = app.chatSheet.fieldFrame
            phases.append(["pose": pose, "keyboard": keyboard,
                           "nativeX": Double(native.minX), "nativeY": Double(native.minY),
                           "savedX": Double(saved.minX), "savedY": Double(saved.minY),
                           "nativeWidth": Double(native.width), "savedWidth": Double(saved.width),
                           "nativeHeight": Double(native.height), "savedHeight": Double(saved.height)])
            XCTAssertTrue(ready, "the actual follow-up field origin is not the window rect used by FlightWords")
        }
    }

}
