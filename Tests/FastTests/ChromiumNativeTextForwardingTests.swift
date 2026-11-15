import Testing
import YabCoreClient

/// Typed helper-adapter contracts only. These controlled receipts do not
/// substitute for original-renderer applied/cancel/focus-race runtime proof.
struct ChromiumNativeTextForwardingTests {
    private func snapshot() -> [String: JSONValue] {
        ["stateVersion": .number(1), "focusIdentityVersion": .number(1), "editable": .bool(true),
         "focusToken": .string("41"), "nativeDocument": .string("original-native-document"),
         "frameId": .string("original-native-frame"), "nativeFocusEpoch": .string("7"),
         "nativeFrameFocusEpoch": .string("9"), "node": .number(13)]
    }
    private func command() throws -> NativeTextInputCommand {
        let focus = try #require(NativeTextFocusIdentity(snapshot()))
        return try #require(NativeTextInputCommand(identity: focus, kind: .compose, text: "日本🙂",
            selectionStart: 2, selectionEnd: 4, id: "original-command"))
    }
    private func reply(_ command: NativeTextInputCommand) -> [String: JSONValue] {
        var row = command.parameters; row["text"] = nil
        row["version"] = .number(1); row["status"] = .string("applied")
        row["tab"] = .string("original-remote"); row["profile"] = .string("original-profile")
        row["browserId"] = .number(5)
        row["nativeAcknowledged"] = .bool(true); row["resultSource"] = .string("native")
        return row
    }

    @Test func anOrdinaryFocusTokenOrMissingRendererStampCannotGrantNativeForwarding() {
        let state = snapshot()
        #expect(NativeTextFocusIdentity(state) != nil)
        for key in ["focusIdentityVersion", "nativeDocument", "frameId", "nativeFocusEpoch", "nativeFrameFocusEpoch", "node"] {
            var missing = state; missing[key] = nil
            #expect(NativeTextFocusIdentity(missing) == nil)
        }
        var cancelled = state; cancelled["cancelled"] = .bool(true)
        #expect(NativeTextFocusIdentity(cancelled) == nil)
        #expect(!NativeTextInputCommand.available(["nativeTextInput": .bool(true)]))
        #expect(!NativeTextInputCommand.available(["nativeTextFocus": .bool(true), "nativeTextFocusVersion": .number(2)]))
        #expect(NativeTextInputCommand.available(["nativeTextFocus": .bool(true), "nativeTextFocusVersion": .number(1)]))
    }

    @Test func uncertainOriginalFocusIdentityCannotPoisonItsReplacementOrABAStamp() throws {
        let original = try #require(NativeTextFocusIdentity(snapshot()))
        var newer = snapshot(); newer["nativeFocusEpoch"] = .string("8")
        let replacement = try #require(NativeTextFocusIdentity(newer))
        let uncertain = Set([original])
        #expect(uncertain.contains(original) && !uncertain.contains(replacement))
        newer = snapshot(); newer["nativeFrameFocusEpoch"] = .string("10")
        let sameNodeNewFrameFocus = try #require(NativeTextFocusIdentity(newer))
        #expect(!uncertain.contains(sameNodeNewFrameFocus))
    }

    @Test func UTF16CompositionAndRealCancelHaveDistinctExactCommands() throws {
        let focus = try #require(NativeTextFocusIdentity(snapshot()))
        let compose = try command()
        #expect(compose.parameters["selectionEnd"] == .number(4), "The emoji uses two UTF16 units")
        #expect(NativeTextInputCommand(identity: focus, kind: .compose, text: "🙂", selectionEnd: 3) == nil)
        #expect(NativeTextInputCommand(identity: focus, kind: .commit, text: "a", selectionEnd: 1) == nil)
        #expect(NativeTextInputCommand(identity: focus, kind: .cancel, text: "a") == nil)
        #expect(NativeTextInputCommand(identity: focus, kind: .unmark, replacementStart: 0, replacementEnd: 0) == nil)
        let cancel = try #require(NativeTextInputCommand(identity: focus, kind: .cancel))
        let finish = try #require(NativeTextInputCommand(identity: focus, kind: .unmark))
        #expect(cancel.parameters["kind"] == .string("cancel"))
        #expect(finish.parameters["kind"] == .string("unmark"))
        #expect(cancel.parameters["text"] == .string("") && cancel.parameters["replacementStart"] == .number(-1))
    }

    @Test func controlledAppliedReceiptRequiresEveryOriginalCommandAndOwnerField() throws {
        let original = try command(), valid = reply(try command())
        #expect(original.outcome(.object(valid), tab: "original-remote", profile: "original-profile") == .applied)
        for key in ["command", "focusToken", "nativeDocument", "frameId", "nativeFocusEpoch", "nativeFrameFocusEpoch", "node",
                    "nativeAcknowledged", "resultSource", "kind", "selectionStart", "selectionEnd", "replacementStart", "replacementEnd", "tab", "profile", "browserId"] {
            var missing = valid; missing[key] = nil
            #expect(original.outcome(.object(missing), tab: "original-remote", profile: "original-profile") == .unknown)
        }
        var replaced = valid; replaced["nativeDocument"] = .string("replacement-document")
        #expect(original.outcome(.object(replaced), tab: "original-remote", profile: "original-profile") == .unknown)
        replaced = valid; replaced["selectionEnd"] = .number(3)
        #expect(original.outcome(.object(replaced), tab: "original-remote", profile: "original-profile") == .unknown)
        #expect(original.outcome(.object(valid), tab: "foreign-remote", profile: "original-profile") == .unknown)
    }

    @Test func dispatchAndUnknownNeverBecomeAppliedOrBeforeEffectRejected() throws {
        let original = try command(); var row = reply(original)
        for status in ["accepted", "dispatched", "queued", "unknown", "retained", ""] {
            row["status"] = .string(status)
            #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .unknown)
        }
        row["status"] = .string("applied"); row["nativeAcknowledged"] = .bool(false)
        #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .unknown)
        row["status"] = .string("rejected")
        #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .unknown)
        row["resultSource"] = .string("native-dispatch-rejected")
        #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .rejected)
        row["text"] = .string("must-not-echo-native-input")
        #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .unknown)
    }

    @Test func rejectedRequiresOriginalNativeACKOrExplicitBeforeEffectRefusal() throws {
        let original = try command(); var row = reply(original)
        row["status"] = .string("rejected")
        #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .rejected)
        for source in ["helper-timeout", "helper-browser-closed", "malformed", "", "native-dispatch-rejected"] {
            row["resultSource"] = .string(source)
            #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .unknown)
        }
        row["nativeAcknowledged"] = .bool(false)
        row["resultSource"] = .string("native-dispatch-rejected")
        #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .rejected)
        for source in ["native", "helper-timeout", "helper-browser-closed", "malformed", ""] {
            row["resultSource"] = .string(source)
            #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .unknown)
        }
        row["resultSource"] = nil; row["nativeAcknowledged"] = nil
        #expect(original.outcome(.object(row), tab: "original-remote", profile: "original-profile") == .unknown)
    }

    @Test func uncertaintyExhaustionDisablesForwardingWithoutEvictingOldPoison() throws {
        let a = try #require(NativeTextFocusIdentity(snapshot()))
        var next = snapshot(); next["nativeFocusEpoch"] = .string("8")
        let b = try #require(NativeTextFocusIdentity(next))
        var state = NativeTextInputUncertainty(limit: 2)
        state.recordUnknown(tab: "a", profile: "p", focus: a)
        #expect(!state.permits(tab: "a", profile: "p", focus: a))
        #expect(state.permits(tab: "b", profile: "p", focus: b))
        state.recordUnknown(tab: "a", profile: "p", focus: a)
        #expect(state.count == 1 && !state.exhausted)
        state.recordUnknown(tab: "b", profile: "p", focus: b)
        #expect(state.exhausted && state.count == 2)
        #expect(!state.permits(tab: "fresh", profile: "fresh", focus: b))
        state.recordUnknown(tab: "third", profile: "p", focus: b)
        #expect(state.count == 2 && !state.permits(tab: "a", profile: "p", focus: a))
    }

}
