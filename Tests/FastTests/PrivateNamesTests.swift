import AppKit
import ObjectiveC
import Testing
import WebKit
@testable import Fast

// Every name outside the public frameworks that Yab calls, asked of the
// WebKit and AppKit this Mac has. Each call site checks `responds(to:)`
// first, so a macOS that drops one turns a feature off without a word: no
// mute, no inspector docked, no reason a page ended. This says which, the
// day it happens (DuckDuckGo keeps the same list,
// WKWebViewPrivateMethodsAvailabilityTests). A name added to the code and
// not here fails `everyNameInTheCodeIsHere`.
struct PrivateNamesTests {
    /// Instance methods and properties, by the class that has them.
    static let instances: [(type: String, names: [String])] = [
        ("WKWebView", [
            "_webProcessIdentifier", "_gpuProcessIdentifier", "_networkProcessIdentifier",
            "_killWebContentProcess", "_setPageMuted:", "_mediaMutedState",
            "_setWindowOcclusionDetectionEnabled:", "_setDisplayCaptureState:completionHandler:",
            "_displayCaptureState", "_isPlayingAudio", "_hasActiveNowPlayingSession",
            "_setNowPlayingMetadataObserver:", "_requestActiveNowPlayingSessionInfo:",
            "_pauseNowPlayingMediaSession:", "_playPredominantOrNowPlayingMediaSession:",
            "_doAfterNextPresentationUpdate:", "_doAfterProcessingAllPendingMouseEvents:", "_setViewScale:", "_viewScale", "_setLayoutMode:",
            "_setAutomaticallyAdjustsContentInsets:", "_setInspectorAttachmentView:", "_inspector",
            "_frames:",
            // A site's window.print() opens the requested frame in the system sheet (#216).
            "_printOperationWithPrintInfo:forFrame:",
            // MailPane sets drawsBackground by key: without either setter,
            // that is an exception, not a quiet no.
            "_setDrawsBackground:",
            // Tab.end, the Live Text ask, and Stage moving a page between windows.
            "_close", "_startImageAnalysis:target:",
            "_beginDeferringViewInWindowChanges", "_endDeferringViewInWindowChanges",
            // A spare tab's process started ahead, and extensions' scripts
            // compiled in it (Tab.warm, ContentWarm).
            "_launchInitialProcessIfNecessary",
            "_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:",
            // YAB_BF_TRACE only: WebKit's own reasons Back missed its cache.
            "_setDiagnosticLoggingDelegate:",
            // A page's beforeunload asked before a tab, window or Yab closes (LeavePage).
            "_tryClose",
            // Full screen without the title bar's inset; the getter beside
            // the setter above (PageFullScreenMove).
            "_automaticallyAdjustsContentInsets",
        ]),
        // A call's voice plays without a click on call sites (CallSound).
        ("WKWebpagePreferences", ["_setAutoplayPolicy:"]),
        // BFTrace answers WebKit's diagnostic logging; the runtime has no
        // protocol for it to be looked up in, so the answers are asked here.
        ("Fast.BFTrace", [
            "_webView:logDiagnosticMessage:description:", "_webView:logDiagnosticMessageWithResult:description:result:",
            "_webView:logDiagnosticMessageWithValue:description:value:",
            "_webView:logDiagnosticMessageWithEnhancedPrivacy:description:",
        ]),
        ("WKPreferences", [
            "_setDeveloperExtrasEnabled:", "_setShouldAllowUserInstalledFonts:", "_shouldAllowUserInstalledFonts",
            "_setMockCaptureDevicesEnabled:", "_setMediaCaptureRequiresSecureConnection:",
            "_setUsesPageCache:", "_setAllowsPictureInPictureMediaPlayback:",
            // A step back or forward that loads its page again leaves the
            // page it leaves out of the cache (Tab.historyStep).
            "_usesPageCache",
            "_setHiddenPageDOMTimerThrottlingEnabled:", "_setHiddenPageDOMTimerThrottlingAutoIncreases:",
            "_setPageVisibilityBasedProcessSuppressionEnabled:",
            // YAB_NAVIGATION_API=0 only (NavigationAPI.off); OpenTrace.isOn
            // reads a feature back (45077c1d).
            "_setEnabled:forFeature:", "_isEnabledForFeature:",
            // WebKit's ⌫-goes-back, turned off on every page (#262, bb1c8dd4).
            "_setBackspaceKeyNavigationEnabled:",
        ]),
        // A new page joins a related view's process (SiteProcesses, Tab).
        ("WKWebViewConfiguration", ["_setWaitsForPaintAfterViewDidMoveToWindow:", "_setRelatedWebView:", "_relatedWebView"]),
        ("WKWebsiteDataStore", [
            // SiteNotices: the `_delegate` property's setter.
            "set_delegate:", "_configuration",
            "_resourceLoadStatisticsEnabled", "_setResourceLoadStatisticsEnabled:",
            // Developer tools' push and Background Fetch (DevApplicationPlatform).
            "_processPushMessage:completionHandler:", "_webPushPartition",
            "_getAllBackgroundFetchIdentifiers:", "_getBackgroundFetchState:completionHandler:",
        ]),
        ("WKHTTPCookieStore", ["_setCookieAcceptPolicy:completionHandler:", "_getCookiesForURL:completionHandler:"]),
        ("WKUserContentController", ["_userStyleSheets", "_addUserStyleSheet:", "_addContentRuleList:extensionBaseURL:"]),
        // A server's redirect is not a person's click (WebKitPageEvents.byPerson, 44df06f4b).
        ("WKNavigationAction", ["_isUserInitiated", "_isRedirect"]),
        // Hidden pages' garbage collected while the Mac is idle (Garbage).
        ("WKProcessPool", ["_garbageCollectJavaScriptObjectsForTesting"]),
        ("_WKWebsiteDataStoreConfiguration", ["generalStorageDirectory"]),
        ("WKWebExtensionContext", ["_backgroundWebView"]),
        ("WKWebExtensionControllerConfiguration", ["_storageDirectoryPath"]),
        ("_WKInspector", ["isVisible", "isElementSelectionActive", "show", "close", "attach", "detach",
                          "toggleElementSelection", "inspectorWebView"]),
        ("_WKContentRuleListAction", ["blockedLoad"]),
        ("_WKFrameTreeNode", ["info", "childFrames"]),
        ("_WKWebContentProcessInfo", ["pid", "webViews"]),
        ("NSWindow", ["_hasActiveAppearance", "_hasActiveAppearanceForStandardWindowButton:", "_draggableFrame", "_zoomFill:"]),
        // The sidebar's rows' clip view keeps a row's ask for the constraints
        // pass (RowsClip, ColumnQuiet.keepsAsks); without it, every ask climbs.
        ("NSView", ["_informContainerThatSubviewsNeedUpdateConstraints"]),
        // Moves heard while the rows scroll, told when they rest (ColumnQuiet,
        // YAB_SMOOTH_MOVED, off by default).
        ("_NSViewGeometryInWindowConcreteObservation", ["_geometryInWindowDidChange:"]),
    ]

    /// Names only a newer WebKit has (macOS 27's): the code asks
    /// `responds(to:)` and turns the feature off without them, so an older
    /// Mac isn't failed for lacking them. Find on Page through WebKit's own
    /// find, which reaches PDFs (WebFind, its _WKFindDelegate answers), and
    /// the Elements picker keeping the page's mouse to itself (DevPicker).
    static let newer = [
        "_findString:options:maxCount:", "_hideFindUI", "_setFindDelegate:", "_isDisplayingPDF",
        "_webView:didCountMatches:forString:", "_webView:didFindMatches:forString:withMatchIndex:",
        "_webView:didFailToFindString:", "_setIgnoresNonWheelEvents:",
        // A click's activation kept through every script (QuietScript, bug
        // 324512); macOS 26's WebKit doesn't reset it, so it needs none.
        "_setDontResetTransientActivationAfterRunJavaScript:",
    ]

    /// Optional PDF getters: Fill & Sign reads the PDF from WebKit when
    /// present, and otherwise fetches the original with the tab's cookies.
    static let optional = ["_getMainResourceDataWithCompletionHandler:", "_suggestedFilenameForDisplayedPDF",
                           // macOS 15 only: 26 sets obscuredContentInsets instead (PageFullScreenMove).
                           "_setTopContentInset:",
                           // Download Audio asks only when the page answers it (PageView.audioDocument).
                           "_isDisplayingStandaloneMediaDocument"]

    /// WebKit replaced the CALayer PDF HUD with NSButtons in macOS 27.
    /// The bench must still be able to show it through one real interface.
    static let alternatives: [(type: String, names: [String])] = [
        ("WKPDFHUDView", ["_setVisible:", "show"]),
    ]

    /// Class methods.
    static let classes: [(type: String, names: [String])] = [
        ("WKProcessPool", ["_webContentProcessInfo"]),
        ("WKPreferences", ["_features"]),
    ]

    /// Private delegate methods Yab answers, the protocol WebKit declares
    /// them in, and the class of Yab's that answers.
    static let delegates: [(proto: String, name: String, answerer: AnyClass)] = [
        ("WKUIDelegatePrivate", "_webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:completionHandler:", WebKitPageEvents.self),
        // First display retries a main video WebKit blocked (VideoOpening).
        ("WKUIDelegatePrivate", "_webView:handleAutoplayEvent:withFlags:", WebKitPageEvents.self),
        ("WKUIDelegatePrivate", "_webView:handleAutoplayEvent:withFlags:", Browser.self),
        ("WKNavigationDelegatePrivate", "_webView:webContentProcessDidTerminateWithReason:", Browser.self),
        ("WKNavigationDelegatePrivate", "_webView:contentRuleListWithIdentifier:performedAction:forURL:", Browser.self),
        ("WKNavigationDelegatePrivate", "_webView:navigationDidFinishDocumentLoad:", ExtensionPopup.self),
        // Deaf: a page whose process stops taking input in front of you.
        ("WKNavigationDelegatePrivate", "_webViewWebProcessDidBecomeUnresponsive:", Browser.self),
        ("WKNavigationDelegatePrivate", "_webViewWebProcessDidBecomeResponsive:", Browser.self),
        ("WKUIDelegatePrivate", "_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:", Browser.self),
        ("WKUIDelegatePrivate", "_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:", Browser.self),
        ("WKUIDelegatePrivate", "_webView:didAttachLocalInspector:", Browser.self),
        ("WKUIDelegatePrivate", "_webView:willCloseLocalInspector:", Browser.self),
        ("WKUIDelegatePrivate", "_webView:printFrame:", Browser.self),
        ("WKUIDelegatePrivate", "_webView:mouseDidMoveOverElement:withFlags:userInfo:", Browser.self),
        // The window a page is told it is in, its outerWidth (#155).
        ("WKUIDelegatePrivate", "_webView:getWindowFrameWithCompletionHandler:", Browser.self),
        ("WKUIDelegatePrivate", "_webView:hasVideoInPictureInPictureDidChange:", Browser.self),
        ("WKUIDelegatePrivate", "_webViewFullscreenMayReturnToInline:", Browser.self),
        // Where you are, on macOS 26, before the public method of 27 (Whereabouts).
        ("WKUIDelegatePrivate", "_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:", Browser.self),
        // A site's "Leave this page?" (LeavePage, request 1033).
        ("WKUIDelegatePrivate", "_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:", Browser.self),
        // The right-click menu held while the selection is read (PageView.readBeforeMenu).
        ("WKUIDelegatePrivate", "_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:", Browser.self),
        // The PDF viewer's Download button.
        ("WKUIDelegatePrivate", "_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:", Browser.self),
        // A link into a named window brings that tab forward (NamedWindowFocus, register 1661).
        ("WKUIDelegatePrivate", "_focusWebView:", Browser.self),
        // A page's requestPointerLock() asks the site's question (#1921, c8936884a).
        ("WKUIDelegatePrivate", "_webViewDidRequestPointerLock:completionHandler:", WebKitPageEvents.self),
    ]

    @Test func everyPrivateNameStillAnswers() throws {
        for (type, names) in Self.instances {
            let cls = try #require(NSClassFromString(type), "\(type) is gone")
            for name in names {
                // drawsBackground: either setter is enough for key-value coding.
                let answers = class_respondsToSelector(cls, NSSelectorFromString(name))
                    || (name == "_setDrawsBackground:" && class_respondsToSelector(cls, NSSelectorFromString("setDrawsBackground:")))
                #expect(answers, "\(type) no longer answers \(name)")
            }
        }
        for (type, names) in Self.alternatives {
            let cls = try #require(NSClassFromString(type), "\(type) is gone")
            #expect(names.contains { class_respondsToSelector(cls, NSSelectorFromString($0)) },
                    "\(type) no longer supports any visibility interface: \(names)")
        }
        for (type, names) in Self.classes {
            let cls: AnyClass = try #require(NSClassFromString(type), "\(type) is gone")
            // A class method is its metaclass's.
            for name in names {
                #expect(class_respondsToSelector(object_getClass(cls), NSSelectorFromString(name)), "+[\(type) \(name)] is gone")
            }
        }
    }

    @Test func everyPrivateDelegateMethodIsStillAskedAndAnswered() throws {
        for (proto, name, answerer) in Self.delegates {
            let selector = NSSelectorFromString(name)
            // Ours: the Swift method really has WebKit's name.
            #expect(class_respondsToSelector(answerer, selector), "\(answerer) doesn't answer \(name)")
            // WebKit's: still in the protocol it asks through.
            let declared = try #require(objc_getProtocol(proto), "\(proto) is gone")
            let optional = protocol_getMethodDescription(declared, selector, false, true).name
            let required = protocol_getMethodDescription(declared, selector, true, true).name
            #expect(optional != nil || required != nil, "\(proto) no longer has \(name)")
        }
    }

    // The list above is the code's: every private name the sources use,
    // found the way they spell them, is in it.
    @Test func everyNameInTheCodeIsHere() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Fast")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        try #require(files.count > 100)
        let listed = Set(Self.instances.flatMap(\.names) + Self.alternatives.flatMap(\.names) + Self.classes.flatMap(\.names) + Self.delegates.map(\.name) + Self.newer + Self.optional)
        let patterns = [
            #"NSSelectorFromString\("(_[A-Za-z][A-Za-z:]*)"\)"#,
            #"forKey(?:Path)?: "(_[A-Za-z][A-Za-z:]*)""#,
            #"@objc\((_[A-Za-z][A-Za-z:]*)\)"#,
            #"(?:let|var) \w*[Kk]ey = "(_[A-Za-z][A-Za-z:]*)""#,
            #"put\(\w+, "(_[A-Za-z][A-Za-z:]*)""#,
            #""(_set[A-Z][A-Za-z]*:)""#,
        ].map { try! NSRegularExpression(pattern: $0) }
        var missing: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                for match in pattern.matches(in: text, range: range) {
                    guard let found = Range(match.range(at: 1), in: text) else { continue }
                    let name = String(text[found])
                    if !listed.contains(name) { missing.append("\(file.lastPathComponent): \(name)") }
                }
            }
        }
        #expect(missing.isEmpty, "private names used and not listed here: \(Set(missing).sorted())")
    }
}
