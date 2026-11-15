import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// Native forwarding needs the prepared-app original renderer probe. These
/// exercise the actual page's local invalidation and adapter refusal only.
@Suite(.serialized)
@MainActor
struct ChromiumInputMethodTests {
    private func native(_ token: String = "41") -> [String: JSONValue] {
        ["stateVersion": .number(1), "coordinateSpace": .string("rootPage"),
         "editable": .bool(true), "focusToken": .string(token), "revision": .string("8"),
         "selection": .object(["valid": .bool(true), "start": .number(2), "end": .number(4)])]
    }

    @Test func helperLossClearsTheActualInputClientCompositionWithoutRecreatingAnEndpoint() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        // Direct AppKit client state is local. With no helper/view it cannot
        // forward any input or serve as native composition acceptance.
        page.setMarkedText("に🙂", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        page.imeHandled = true; page.imeKeys.insert(7)
        #expect(page.hasMarkedText())
        let generation = page.inputMethodGeneration
        page.helperExited()
        #expect(!page.hasMarkedText() && page.markedRange().location == NSNotFound)
        #expect(!page.imeHandled && page.imeKeys.isEmpty && page.nativeText == nil)
        #expect(page.inputMethodGeneration > generation)
        #expect(page.remoteID == nil && page.inputMethodDispatched == 0)
    }

    @Test func nativeFocusChangeAndCancellationDiscardLocalMarkedStateWithoutUnmarkingANewTarget() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.receiveNativeTextInput(native())
        page.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        page.receiveNativeTextInput(native())
        #expect(page.hasMarkedText(), "An unchanged native focus does not drop a local composition")
        page.receiveNativeTextInput(native("42"))
        #expect(!page.hasMarkedText())
        let range = page.selectedRange()
        #expect(range == NSRange(location: 2, length: 2))
        page.setMarkedText("さ", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        var cancelled = native("42"); cancelled["cancelled"] = .bool(true)
        page.receiveNativeTextInput(cancelled)
        #expect(!page.hasMarkedText() && page.selectedRange().location == NSNotFound)
        #expect(page.remoteID == nil && page.inputMethodDispatched == 0)
    }

    @Test func focusMetadataAndUTF16RangesRejectMissingOrMalformedNativeAuthority() {
        var state = native()
        #expect(ChromiumNativeTextInput.focusToken(state) == "41")
        for invalid in [nil, .string("0"), .string("-1"), .string("+1"), .string(""), .string("18446744073709551616")] as [JSONValue?] {
            state["focusToken"] = invalid
            #expect(ChromiumNativeTextInput.focusToken(state) == nil)
        }
        for (start, end) in [(-1.0, 2.0), (1.5, 2.0), (2.0, 1.0), (0.0, Double(Int.max)), (0.0, .infinity)] {
            let value = JSONValue.object(["valid": .bool(true), "start": .number(start), "end": .number(end)])
            #expect(ChromiumNativeTextInput.range(value) == nil)
        }
        #expect(ChromiumNativeTextInput.range(native()["selection"]) == NSRange(location: 2, length: 2))
    }

    @Test func anEarlierDispatchedCommandCannotAcknowledgeARefusedCurrentTicket() {
        let earlier = ChromiumInputMethodTicket(), current = ChromiumInputMethodTicket()
        earlier.result = .dispatched
        current.result = .refused
        let first = earlier.dispatchReport, second = current.dispatchReport
        #expect(first["dispatched"] as? Bool == true)
        #expect(second["dispatched"] as? Bool == false)
        #expect(first["dispatchTicket"] as? String != second["dispatchTicket"] as? String)
        current.result = .unknown
        let uncertain = current.dispatchReport
        #expect(uncertain["dispatched"] is NSNull)
        #expect(uncertain["dispatchResult"] as? String == "unknown")
    }

    // MARK: - A page field's keys through Yab's input context

    private typealias Heard = ChromiumKeyInterpretation
    private var none: NSRange { NSRange(location: NSNotFound, length: 0) }

    @Test func aPlainCharacterOrAnEditingCommandGoesToThePageAsTheKey() {
        // The page reads the key into the same character, with its keydown,
        // keypress and input events, as the Mac's own field would.
        #expect(Heard(edits: [.insert("e", replacing: none)]).route(typed: "e", inputMethod: false, taken: true) == .page)
        #expect(Heard(edits: [.insert("ß", replacing: none)]).route(typed: "ß", inputMethod: false, taken: true) == .page)
        // A repeat the context typed again (no accents, or press and hold off).
        #expect(Heard(edits: [.insert(" ", replacing: none)]).route(typed: " ", inputMethod: false, taken: true) == .page)
        #expect(Heard(commands: 1).route(typed: "\u{7F}", inputMethod: false, taken: true) == .page)
        #expect(Heard(commands: 1).route(typed: "\u{F702}", inputMethod: false, taken: true) == .page)
        #expect(Heard().route(typed: "\u{F704}", inputMethod: false, taken: false) == .page)
    }

    @Test func aHeldLettersRepeatsAndTheMenusPickKeyStayWithTheAccentMenu() {
        // Yab Alpha, 2026-11-05: holding a letter in a Chromium tab gave no
        // accent menu.
        #expect(Heard().route(typed: "e", inputMethod: false, taken: true) == .kept)
        // Still kept once the menu marked the letter.
        #expect(Heard().route(typed: "e", inputMethod: true, taken: true) == .kept)
        // The digit that picks from the open menu: the accent comes a moment
        // later as an insert of its own, and the digit is never typed
        // (m4, 2026-11-05: "hello é2" until this).
        #expect(Heard().route(typed: "2", inputMethod: false, taken: true) == .kept)
        // Not taken: the page decides.
        #expect(Heard().route(typed: "e", inputMethod: false, taken: false) == .page)
    }

    @Test func anAccentPickADeadKeyOrAnInputMethodsWordsGoAsTextEdits() {
        let letter = NSRange(location: 4, length: 1)
        // The menu's pick replaces the letter typed, by digit or by the menu.
        #expect(Heard(edits: [.insert("é", replacing: letter)]).route(typed: "2", inputMethod: false, taken: true) == .inputMethod)
        #expect(Heard(edits: [.insert("é", replacing: none)]).route(typed: "2", inputMethod: false, taken: true) == .inputMethod)
        #expect(Heard(edits: [.mark("e", selected: NSRange(location: 1, length: 0), replacing: letter)])
            .route(typed: "e", inputMethod: false, taken: true) == .inputMethod)
        // Option-E on U.S.: the dead key's accent is marked, then the letter commits.
        #expect(Heard(edits: [.mark("´", selected: NSRange(location: 1, length: 0), replacing: none)])
            .route(typed: "", inputMethod: false, taken: true) == .inputMethod)
        #expect(Heard(edits: [.insert("é", replacing: none)]).route(typed: "e", inputMethod: false, taken: true) == .inputMethod)
        // Another letter closing the menu commits the marked one and types itself.
        #expect(Heard(edits: [.insert("e", replacing: none), .insert("x", replacing: none)])
            .route(typed: "x", inputMethod: false, taken: true) == .inputMethod)
        // With an input method selected its words are always its own.
        #expect(Heard(edits: [.insert("a", replacing: none)]).route(typed: "a", inputMethod: true, taken: true) == .inputMethod)
    }

    @Test func editsWaitForTheKeysRouteAndCarryTheirReplacementRange() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.receiveNativeTextInput(native())
        page.keyInterpretation = ChromiumKeyInterpretation()
        page.setMarkedText("e", selectedRange: NSRange(location: NSNotFound, length: 0), replacementRange: NSRange(location: 3, length: 1))
        #expect(page.markedRange() == NSRange(location: 3, length: 1), "The held letter is marked where it stands, not at the field's start")
        page.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        page.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(page.keyInterpretation == ChromiumKeyInterpretation(edits: [
            .mark("e", selected: NSRange(location: 1, length: 0), replacing: NSRange(location: 3, length: 1)),
            .insert("é", replacing: none)], commands: 1))
        #expect(page.inputMethodTicket == nil, "Nothing is sent while the key is being read")
        page.keyInterpretation = nil
        #expect(ChromiumNativeTextInput.replacementFields(none).isEmpty)
        #expect(ChromiumNativeTextInput.replacementFields(NSRange(location: 3, length: 1)) ==
                ["replacementStart": .number(3), "replacementLength": .number(1)])
    }

    @Test func unboundProbeRefusesMutationsAndCancelDoesNotPretendToFinish() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.receiveNativeTextInput(native())
        var reply: [String: Any] = [:]
        page.probeNativeInputMethod(["action": "mark", "remote": "foreign", "localTurn": 0,
                                    "focusToken": "41", "text": "に", "selectionStart": 1,
                                    "selectionLength": 0]) { reply = $0 }
        #expect(reply["dispatched"] as? Bool == false)
        #expect(reply["refused"] as? String == "original-local-page-or-focus-changed")
        #expect(!page.hasMarkedText() && page.remoteID == nil)
        page.probeNativeInputMethod(["action": "cancel"]) { reply = $0 }
        #expect(reply["dispatched"] as? Bool == false)
        #expect(reply["unavailable"] as? String == "native-cancel-document-lease")
        #expect(reply["nativeLease"] as? Bool == false && reply["documentProof"] as? String == "unavailable")
        #expect(page.remoteID == nil && page.inputMethodDispatched == 0)
    }
}
