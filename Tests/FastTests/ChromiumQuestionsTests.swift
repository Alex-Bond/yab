import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// Delivery adapters exercise metadata and reply shaping only. A real positive
/// receiveQuestion needs the original connected helper and remains native QA.
@Suite(.serialized)
@MainActor
struct ChromiumQuestionsTests {
    private final class Listener: PageEvents {
        var capture: (PageCapture, PageOrigin)?
        var location: PageOrigin?
        var notifications: PageOrigin?
        var auth: PageAuthentication?
        var dialogs: [PageDialog] = []
        var permissions: [(SitePermission, PageOrigin)] = []
        var permissionAnswer = false
        func page(_ page: any PageHandle, permission kind: SitePermission, origin: PageOrigin,
                  reply: @escaping @MainActor (Bool) -> Void) { permissions.append((kind, origin)); reply(permissionAnswer) }
        func page(_ page: any PageHandle, dialog: PageDialog,
                  reply: @escaping @MainActor (PageDialogReply) -> Void) { dialogs.append(dialog) }
        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) { }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
        func page(_ page: any PageHandle, capture type: PageCapture, origin: PageOrigin,
                  reply: @escaping @MainActor (PagePermission) -> Void) { capture = (type, origin); reply(.deny) }
        func page(_ page: any PageHandle, locate origin: PageOrigin,
                  reply: @escaping @MainActor (PagePermission) -> Void) { location = origin; reply(.deny) }
        func page(_ page: any PageHandle, notify origin: PageOrigin,
                  reply: @escaping @MainActor (Bool) -> Void) { notifications = origin; reply(false) }
        func page(_ page: any PageHandle, authenticate challenge: PageAuthentication,
                  reply: @escaping @MainActor (PageAuthenticationReply) -> Void) { auth = challenge; reply(.cancel) }
    }
    @Test func admittedCaptureAdapterRetainsNativeOriginAndCombinedDevices() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), listener = Listener()
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.events = listener
        var replies: [[String: JSONValue]] = []
        ChromiumQuestionDelivery.send(["request": .string("native-capture"), "kind": .string("capture"),
            "origin": .string("https://frame.example:8443"), "camera": .bool(true), "microphone": .bool(true)],
            page: page, events: listener) { values in
                replies.append(ChromiumQuestionDelivery.reply(values, token: "native-capture", remote: "original-capture-tab"))
            }
        #expect(replies == [["allow": .bool(false), "request": .string("native-capture"), "tab": .string("original-capture-tab")]])
        #expect(listener.capture?.0 == .cameraAndMicrophone)
        #expect(listener.capture?.1 == PageOrigin(scheme: "https", host: "frame.example", port: 8443))
        #expect(page.remoteID == nil)
    }
    @Test func admittedAuthAdapterRetainsTransportSchemeAndRealm() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), listener = Listener()
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.events = listener
        var replies: [[String: JSONValue]] = []
        ChromiumQuestionDelivery.send(["request": .string("native-auth"), "kind": .string("auth"), "origin": .string("http://router.example/login"),
            "host": .string("router.example"), "scheme": .string("basic"), "realm": .string("Router"), "failures": .number(1)],
            page: page, events: listener) { values in
                replies.append(ChromiumQuestionDelivery.reply(values, token: "native-auth", remote: "original-auth-tab"))
            }
        #expect(replies == [["allow": .bool(false), "request": .string("native-auth"), "tab": .string("original-auth-tab")]])
        #expect(listener.auth?.host == "router.example")
        #expect(listener.auth?.scheme == "http")
        #expect(listener.auth?.method == NSURLAuthenticationMethodHTTPBasic)
        #expect(listener.auth?.realm == "Router")
        #expect(listener.auth?.previousFailureCount == 1)
        #expect(listener.auth?.proposedPasswordIsEmpty == false)
    }
    @Test func absentEndpointCannotDeliverNativeCaptureOrAuth() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), listener = Listener()
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.events = listener
        page.receiveQuestion(["request": .string("native-capture"), "kind": .string("capture"),
            "origin": .string("https://frame.example"), "camera": .bool(true)])
        page.receiveQuestion(["request": .string("native-auth"), "kind": .string("auth"),
            "origin": .string("https://router.example"), "host": .string("router.example"), "scheme": .string("basic")])
        #expect(listener.capture == nil && listener.auth == nil)
        #expect(page.remoteID == nil && page.questionRequests.presentingPermission == nil)
    }

    @Test func boundEndpointWithoutOriginalClientCannotDeliverNativeQuestions() throws {
        _ = NSApplication.shared
        try #require(ChromiumProcess.shared.connectedClient == nil,
                     "This admission-negative fixture must not borrow another suite's real helper")
        let tab = Tab(shy: true), listener = Listener()
        let page = ChromiumPage(tab: tab)
        let remote = "question-no-client-" + UUID().uuidString
        page.adoptRemote(remote)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.events = listener
        page.receiveQuestion(["request": .string("native-capture"), "kind": .string("capture"),
            "profile": .string(page.profile), "origin": .string("https://frame.example"), "camera": .bool(true)])
        page.receiveQuestion(["request": .string("native-auth"), "kind": .string("auth"),
            "profile": .string(page.profile), "origin": .string("http://router.example"), "host": .string("router.example"), "scheme": .string("basic")])
        #expect(listener.capture == nil && listener.auth == nil)
        #expect(page.remoteID == remote && ChromiumProcess.shared.connectedClient == nil,
                "Question delivery must not start or replace a helper")
        #expect(page.questionRequests.presentingPermission == nil)
    }

    /// CEF patch 0097: File System Access's write prompt arrives as a
    /// "permission" question for "files", from an extension's page too, and
    /// Yab's answer is the request's answer (#1683).
    @Test func filesQuestionFromAnExtensionPageReachesTheFilesCard() {
        _ = NSApplication.shared
        let id = String(repeating: "a", count: 16) + String(repeating: "p", count: 16)
        for answer in [true, false] {
            let tab = Tab(shy: true), listener = Listener()
            let page = ChromiumPage(tab: tab)
            defer { page.retire(call: false, pictureInPicture: false); tab.close() }
            page.events = listener
            listener.permissionAnswer = answer
            var replies: [[String: JSONValue]] = []
            ChromiumQuestionDelivery.send(["request": .string("native-files"), "kind": .string("permission"),
                "origin": .string("chrome-extension://\(id)/"), "top": .string("chrome-extension://\(id)/options.html"),
                "permissions": .array([.string("files")])], page: page, events: listener) { values in
                    replies.append(ChromiumQuestionDelivery.reply(values, token: "native-files", remote: "original-files-tab"))
                }
            #expect(listener.permissions.count == 1)
            #expect(listener.permissions.first?.0 == .files)
            #expect(listener.permissions.first?.1 == PageOrigin(scheme: "chrome-extension", host: id, port: 0))
            #expect(replies == [["allow": .bool(answer), "request": .string("native-files"), "tab": .string("original-files-tab")]])
        }
    }

    /// A file's grant lasts as long as its handle: Yab keeps no answer of its
    /// own, so nothing it said is taken back from Chromium afterwards.
    @Test func aFilesAnswerIsNeverRememberedForTheSite() {
        let question: [String: JSONValue] = ["kind": .string("permission"), "permissions": .array([.string("files")])]
        #expect(!SitePermission.files.remembered)
        #expect(ChromiumPermissions.keeps(question, origin: PageOrigin(scheme: "https", host: "photos.example", port: 0)))
    }

    @Test func originalReplyIdentityOverridesForeignUIValues() {
        let reply = ChromiumQuestionDelivery.reply(["allow": .bool(true), "request": .string("foreign"), "tab": .string("replacement")],
                                                  token: "original-continuation", remote: "original-tab")
        #expect(reply == ["allow": .bool(true), "request": .string("original-continuation"), "tab": .string("original-tab")])
    }

    @Test func missingNativeTokenCannotAskForPermission() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), listener = Listener()
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.events = listener
        page.receiveQuestion(["kind": .string("capture"), "camera": .bool(true)])
        #expect(listener.capture == nil)
        #expect(page.remoteID == nil)
    }

    @Test func javascriptQuestionRequiresNativeTokenAndRetainsOrigin() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), listener = Listener()
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.events = listener
        let values: [String: JSONValue] = ["kind": .string("confirm"), "origin": .string("https://frame.example:8443/path"),
                                           "message": .string("Archive this note?")]
        page.receiveNavigation(YabCoreEvent(name: "dialog.open", params: values))
        #expect(listener.dialogs.isEmpty)
        var authenticated = values; authenticated["request"] = .string("native-continuation")
        page.receiveNavigation(YabCoreEvent(name: "dialog.open", params: authenticated))
        #expect(listener.dialogs.count == 1)
        #expect(listener.dialogs.first?.kind == .confirm)
        #expect(listener.dialogs.first?.message == "Archive this note?")
        #expect(listener.dialogs.first?.origin == PageOrigin(scheme: "https", host: "frame.example", port: 8443))
        #expect(page.remoteID == nil, "Question delivery must not create a replacement helper tab")
    }
}
