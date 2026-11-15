import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Real production hosts and route-owned gestures with owned render data.
/// These cases do not run an answerer, task, or personal sync account.
@MainActor
final class ChatInteractiveInfoTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?

    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil
    }
    private func live() -> AppModel {
        let app = AppModel(world: World(name: "owned-interactive", space: "public", spaces: [
            Space(id: "public", name: "Public", emoji: "", tint: RGB(238, 233, 226)),
            Space(id: "private", name: "Private", emoji: "", tint: RGB(31, 31, 34), isPrivate: true)
        ]), fixturesEnabled: false, privateLockEnabled: { false })
        let words = (0..<60).map { "Owned readable paragraph \($0). This is long enough to exercise the actual production transcript and retained reading position." }.joined(separator: "\n\n")
        for id in ["owned-first", "owned-next"] {
            app.chats.add(Chat(id: id, title: "Owned chat " + id, by: .iphone,
                               messages: [Message(role: .you, text: "Owned question"), Message(role: .answer, text: words, by: .iphone)]))
        }
        return app
    }
    private func until(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if condition() { return true }
            await Task.yield(); try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func host(_ app: AppModel) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene); owned.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let controller = UIHostingController(rootView: ChatsLayer().environment(app).environment(\.colorScheme, .light))
        controller.safeAreaRegions = []; owned.rootViewController = controller; window = owned; owned.makeKeyAndVisible()
        controller.view.layoutIfNeeded(); return owned
    }
    private func shot(_ name: String, in window: UIWindow) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testAnOldNativeInfoDismissalCannotCloseAReopenedInfoOrAReplacedConversation() throws {
        let disabled = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = disabled }
        let app = live(); app.openChat("owned-first"); app.openChatInfo()
        let old = ChatInfoPresentation.binding(app: app, chat: "owned-first")
        let first = try XCTUnwrap(old.wrappedValue)
        app.closeChatInfo(); app.openChatInfo()
        let reopened = try XCTUnwrap(app.chatSheet.infoGeneration)
        XCTAssertNotEqual(first.id, reopened)
        old.wrappedValue = nil
        XCTAssertTrue(app.chatSheet.info); XCTAssertEqual(app.chatSheet.infoGeneration, reopened)
        app.openChat("owned-next"); app.openChatInfo()
        let next = app.chatSheet.infoGeneration
        old.wrappedValue = nil
        XCTAssertEqual(app.chatSheet.chatID, "owned-next"); XCTAssertEqual(app.chatSheet.infoGeneration, next)
        app.openHistory(); old.wrappedValue = nil
        XCTAssertFalse(app.chatSheet.shown); XCTAssertFalse(app.chatSheet.info)
    }

    func testAChatPageTakesNoVerticalPullAndKeepsItsDraft() {
        let disabled = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = disabled }
        let app = live(); app.openChat("owned-first"); app.chatSheet.draft = "Unsent owned draft"
        let pan = ChatSheetPan(app: app), before = app.chats.chat("owned-first")
        pan.begin(pose: app.chatSheet.pose); pan.move(180); pan.end(180, velocity: 1000, cancelled: false)
        XCTAssertEqual(app.chatSheet.pose.t, 1); XCTAssertEqual(app.chatSheet.pose.drag, 0)
        XCTAssertEqual(app.chatSheet.draft, "Unsent owned draft"); XCTAssertEqual(app.chats.chat("owned-first"), before)
        XCTAssertEqual(app.chatSheet.chatID, "owned-first"); XCTAssertTrue(app.chatSheet.shown)
    }

    func testBackLandsOnTheChatsPageAndChatsIsThatPage() {
        let disabled = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = disabled }
        let app = live(); app.openChat("owned-first")
        app.openHistory()
        XCTAssertFalse(app.chatSheet.shown, "‹ goes to New Tab's Chats page"); XCTAssertNil(app.surfaces.chat)
        XCTAssertNil(app.chatSheet.chatID)
        XCTAssertEqual(app.surfaces.field, .newTab); XCTAssertEqual(NewTabPager.shared.startAt, NewTabPager.chatsPage)
        app.surfaces.closeField()
        app.openChats()
        XCTAssertFalse(app.chatSheet.shown); XCTAssertNil(app.chatSheet.chatID)
        XCTAssertEqual(app.surfaces.field, .newTab); XCTAssertEqual(NewTabPager.shared.startAt, NewTabPager.chatsPage)
    }

    func testAChatFromItsCardStandsAsAPageInItsCoverOverTheChatsPage() throws {
        let disabled = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = disabled }
        let app = live()
        NewTabPager.shared.startAt = NewTabPager.chatsPage
        app.field.openSpaces()
        XCTAssertEqual(app.surfaces.field, .newTab)
        app.openChatFromSpaces("owned-first")
        let page = try XCTUnwrap(app.chatSheet.page, "a card opens its chat in a native cover")
        XCTAssertEqual(page.chat, "owned-first"); XCTAssertEqual(page.source, "owned-first", "it zooms out of the card itself")
        XCTAssertEqual(page.id, app.chatSheet.navigationGeneration)
        XCTAssertTrue(app.chatSheet.shown); XCTAssertEqual(app.chatSheet.mode, .chat); XCTAssertEqual(app.chatSheet.chatID, "owned-first")
        XCTAssertEqual(app.surfaces.field, .newTab, "the Chats page stays under the cover")
        XCTAssertEqual(app.surfaces.chat, .chat("owned-first"))
        XCTAssertEqual(app.surfaces.recede, 0, "nothing under the cover moves")
        XCTAssertEqual(app.chatSheet.pose, SheetPose(t: 1, h: app.chatSheet.pose.h), "no pose of its own")
        let binding = ChatPagePresentation.binding(app: app)
        XCTAssertEqual(binding.wrappedValue, page)
        // ‹: the cover zooms back into its card, the page in front as it was.
        app.openHistory()
        XCTAssertNil(app.chatSheet.page); XCTAssertNil(binding.wrappedValue)
        XCTAssertFalse(app.chatSheet.shown); XCTAssertNil(app.chatSheet.chatID); XCTAssertNil(app.surfaces.chat)
        XCTAssertEqual(app.surfaces.field, .newTab)
    }

    func testAPageInItsCoverIsAStillFullPageOnTheKeyboard() {
        let screen = CGSize(width: 402, height: 874)
        let page = SheetGeometry.page(screen: screen, keyboard: 0)
        XCTAssertTrue(page.cover); XCTAssertTrue(page.isPage); XCTAssertTrue(page.tray)
        XCTAssertEqual(page.current.rect, CGRect(origin: .zero, size: screen))
        XCTAssertEqual(page.current.top, 0); XCTAssertEqual(page.current.bottom, 0)
        XCTAssertEqual(page.words, 1); XCTAssertEqual(page.sheetOpacity, 1)
        let typing = SheetGeometry.page(screen: screen, keyboard: 336)
        XCTAssertEqual(typing.current.rect, CGRect(x: 0, y: 0, width: 402, height: 874 - 336), "its foot rides the keyboard")
    }

    func testOnlyTheCurrentCoverClosesItsPageAndACancelledPullKeepsIt() throws {
        let disabled = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = disabled }
        let app = live()
        app.field.openSpaces()
        app.openChatFromSpaces("owned-first"); app.chatSheet.draft = "Kept draft"
        let old = ChatPagePresentation.binding(app: app)
        let first = try XCTUnwrap(old.wrappedValue)
        // A pull UIKit cancels writes nothing: the page stays, its draft too.
        XCTAssertTrue(first.isCurrent(in: app)); XCTAssertEqual(app.chatSheet.draft, "Kept draft")
        app.openHistory()
        app.openChatFromSpaces("owned-next")
        let next = try XCTUnwrap(app.chatSheet.page)
        XCTAssertNotEqual(first.id, next.id)
        old.wrappedValue = nil
        XCTAssertEqual(app.chatSheet.page, next, "an old cover's finished dismissal can't close a newer page")
        XCTAssertTrue(app.chatSheet.shown)
        // UIKit's pull down finished on the current cover.
        ChatPagePresentation.binding(app: app).wrappedValue = nil
        XCTAssertNil(app.chatSheet.page); XCTAssertFalse(app.chatSheet.shown); XCTAssertEqual(app.surfaces.field, .newTab)
    }

    func testANewChatFromItsRowIsAPageAndLeavesNothingUnasked() async throws {
        let disabled = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = disabled }
        let app = live()
        app.field.openSpaces()
        app.newChatFromSpaces()
        let page = try XCTUnwrap(app.chatSheet.page)
        XCTAssertEqual(page.source, ChatPagePresentation.newChat)
        XCTAssertTrue(app.chatSheet.fresh.contains(page.chat)); XCTAssertTrue(app.chatSheet.focused)
        XCTAssertEqual(app.surfaces.field, .newTab)
        app.openHistory()
        let gone = await until { app.chats.chat(page.chat) == nil }
        XCTAssertTrue(gone, "nothing asked, nothing left once the zoom back is over")
    }

    func testAChatInTheSheetIsHandedToACoverThatZoomsIntoItsCard() async throws {
        let disabled = Motion.disabled; Motion.disabled = false; defer { Motion.disabled = disabled }
        let app = live(); app.openChat("owned-first")
        XCTAssertNil(app.chatSheet.page, "from anywhere but its card, a chat stands in the sheet")
        app.openHistory()
        XCTAssertEqual(app.surfaces.field, .newTab, "the Chats page comes under it")
        let handed = await until { app.chatSheet.page != nil }
        XCTAssertTrue(handed)
        let page = try XCTUnwrap(app.chatSheet.page)
        XCTAssertEqual(page.chat, "owned-first"); XCTAssertEqual(page.source, "owned-first", "into its own card")
        XCTAssertTrue(app.chatSheet.shown); XCTAssertFalse(app.chatSheet.pageOnScreen,
                                                          "the sheet draws it until the cover stands")
        // No Chats page here presents the cover: the chat goes anyway.
        let gone = await until { !app.chatSheet.shown }
        XCTAssertTrue(gone); XCTAssertNil(app.chatSheet.page); XCTAssertEqual(app.surfaces.field, .newTab)
    }

    func testTheActualNativeAvatarKeepsItsTargetAndCannotOpenAnOldOwner() throws {
        let disabled = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = disabled }
        let app = live(); app.openChat("owned-first")
        let control = ChatAvatarControl(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        control.configure(chat: try XCTUnwrap(app.chats.chat("owned-first")), app: app, large: false, style: .dark)
        control.layoutIfNeeded()
        XCTAssertEqual(control.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(control.accessibilityIdentifier, "chat.face")
        XCTAssertEqual(control.overrideUserInterfaceStyle, .dark)
        XCTAssertTrue(control.isEnabled); XCTAssertTrue(control.isUserInteractionEnabled)
        control.sendActions(for: .touchUpInside); XCTAssertTrue(app.chatSheet.info)
        app.closeChatInfo(); app.openChat("owned-next")
        control.sendActions(for: .touchUpInside)
        XCTAssertFalse(app.chatSheet.info); XCTAssertEqual(app.chatSheet.chatID, "owned-next")
        app.openChat("owned-first")
        control.sendActions(for: .touchUpInside)
        XCTAssertFalse(app.chatSheet.info, "same ID reopened in a new route cannot accept a retained old source")
        control.configure(chat: try XCTUnwrap(app.chats.chat("owned-first")), app: app, large: false, style: .dark)
        control.sendActions(for: .touchUpInside); XCTAssertTrue(app.chatSheet.info)
        app.closeChatInfo()
        control.retire(); control.sendActions(for: .touchUpInside); XCTAssertFalse(app.chatSheet.info)
    }

    func testNativeZoomInfoKeepsTheActualTranscriptAndRestoresItsReadingOffset() async throws {
        let disabled = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = disabled }
        let app = live(); app.openChat("owned-first"); app.chatSheet.draft = "Owned readable draft"
        let owned = try host(app)
        let loaded = await until { self.views(owned).compactMap { $0 as? UIScrollView }.contains { $0.contentSize.height > 1600 } }
        XCTAssertTrue(loaded)
        let scroll = try XCTUnwrap(views(owned).compactMap { $0 as? UIScrollView }.first { $0.contentSize.height > 1600 })
        scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        let avatar = try XCTUnwrap(views(owned).compactMap { $0 as? ChatAvatarControl }.first)
        XCTAssertEqual(avatar.bounds.size, CGSize(width: 44, height: 44))
        let avatarFrame = avatar.convert(avatar.bounds, to: owned)
        XCTAssertEqual(avatarFrame.minY, 54, accuracy: 1, "the face stands 4 over the head's buttons, as X's")
        XCTAssertEqual(avatarFrame.midX, 201, accuracy: 1)
        XCTAssertFalse(avatar.drawsFace, "SwiftUI draws the face edge to edge; the native control only takes the touch")
        let hit = owned.hitTest(CGPoint(x: avatarFrame.midX, y: avatarFrame.midY), with: nil)
        XCTAssertTrue(hit === avatar || hit?.isDescendant(of: avatar) == true)
        avatar.sendActions(for: .touchUpInside)
        let appeared = await until { owned.rootViewController?.presentedViewController?.view.window === owned
            && self.views(owned).contains { $0.accessibilityIdentifier == "chat.info.privateCurtain" } }
        XCTAssertTrue(appeared)
        let cover = try XCTUnwrap(owned.rootViewController?.presentedViewController)
        XCTAssertNotNil(cover.preferredTransition, "Info must use the actual native zoom transition")
        XCTAssertTrue(views(try XCTUnwrap(owned.rootViewController?.view)).contains { $0 === scroll },
                      "UIKit may detach a full-screen presenting view, but it must retain the original transcript")
        XCTAssertEqual(scroll.contentOffset.y, 180, accuracy: 1)
        shot("native-info-zoom-page-over-retained-transcript", in: owned)
        app.closeChatInfo()
        let returned = await until { owned.rootViewController?.presentedViewController == nil }
        XCTAssertTrue(returned)
        XCTAssertTrue(views(owned).contains { $0 === scroll }); XCTAssertEqual(scroll.contentOffset.y, 180, accuracy: 1)
        XCTAssertEqual(app.chatSheet.draft, "Owned readable draft"); XCTAssertEqual(app.chatSheet.pose.t, 1)
        let frame = scroll.convert(scroll.bounds, to: owned)
        XCTAssertLessThanOrEqual(frame.minY, 1); XCTAssertGreaterThanOrEqual(frame.maxY, 873)
        shot("native-info-returned-same-full-transcript", in: owned)
    }

    func testTheModalCurtainCoversPrivateBeforeSnapshotAndCannotReviveAfterRetirement() {
        let app = live(); app.browser.showSpace("private")
        let curtain = ChatInfoPrivacyView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        curtain.configure(app: app); XCTAssertTrue(curtain.isHidden)
        curtain.coverBeforeSnapshot()
        XCTAssertFalse(curtain.isHidden); XCTAssertTrue(curtain.isUserInteractionEnabled)
        XCTAssertEqual(curtain.backgroundColor, .black); XCTAssertTrue(curtain.isAccessibilityElement)
        app.browser.showSpace("public"); curtain.configure(app: app); XCTAssertTrue(curtain.isHidden)
        curtain.retire(); curtain.coverBeforeSnapshot(); XCTAssertTrue(curtain.isHidden)
    }

    func testPrivateSnapshotCurtainCoversTheActualInfoWindowIncludingItsNativeAlert() async throws {
        let app = live(); app.browser.showSpace("private")
        let owned = try host(app)
        let curtain = ChatInfoPrivacyView(frame: owned.bounds)
        curtain.configure(app: app); owned.addSubview(curtain)
        let alert = UIAlertController(title: "Owned rename", message: nil, preferredStyle: .alert)
        owned.rootViewController?.present(alert, animated: false)
        let appeared = await until { alert.view.window === owned }; XCTAssertTrue(appeared)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let shield = try XCTUnwrap(owned.subviews.last)
        XCTAssertEqual(shield.accessibilityIdentifier, "chat.info.privateWindowCurtain")
        XCTAssertEqual(shield.frame, owned.bounds); XCTAssertEqual(shield.backgroundColor, .black)
        XCTAssertTrue(shield.isUserInteractionEnabled); XCTAssertTrue(shield.isAccessibilityElement)
        app.browser.showSpace("public"); curtain.configure(app: app)
        XCTAssertNil(shield.superview); XCTAssertTrue(alert.view.window === owned)
        curtain.retire(); curtain.coverBeforeSnapshot(); XCTAssertNil(shield.superview)
        alert.dismiss(animated: false)
    }
}
