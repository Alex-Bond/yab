import JavaScriptCore
import Testing
@testable import Fast

/// WebKit bug 299460: a null icon reset can reach actionSetIcon without
/// JSON data. Empty icon maps follow the engine's safe reset path.
@MainActor
struct ExtensionIconResetTests {
    private func check(_ body: String) throws {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var root = globalThis, seen = [], returned = Promise.resolve(), callbackCalls = 0;
        function receiver(name) {
          return { setIcon(details, callback) {
            seen.push({ name, details, callback, receiver: this });
            if (typeof callback === 'function') callback();
            return returned;
          } };
        }
        var chrome = { action: receiver('action'), browserAction: receiver('browserAction'), pageAction: receiver('pageAction') };
        var browser = { action: receiver('browser.action') };
        function put(o, key, value) { o[key] = value; }
        """#)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // Older WebKit crashes when setIcon's null reset"))
        let end = try #require(script.range(of: "  // End of icon reset guard.", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        let result = context.evaluateScript("(() => {\n" + body + "\n})()")
        try #require(context.exception == nil)
        #expect(result?.toBool() == true)
    }

    @Test func nullAndMissingIconsBecomeSafeResetsWithoutChangingTheCaller() throws {
        try check(#"""
        for (const input of [{path: null, tabId: 7}, {imageData: null, tabId: 8}, {variants: null, windowId: 9}, {}]) {
          const before = JSON.stringify(input);
          chrome.action.setIcon(input);
          const safe = seen.at(-1).details;
          const key = 'imageData' in input ? 'imageData' : 'path';
          if (safe === input || !safe[key] || Object.keys(safe[key]).length ||
              safe.tabId !== input.tabId || safe.windowId !== input.windowId || JSON.stringify(input) !== before) return false;
        }
        return seen.length === 4;
        """#)
    }

    @Test func normalIconsKeepTheirIdentityAndCallbackAndPromise() throws {
        try check(#"""
        const image = {width: 32, height: 32, data: [1, 2, 3, 4]};
        const inputs = [{path: 'icon.png'}, {path: {'16': 'icon.png'}}, {imageData: image}, {variants: [{'16': 'dark.png'}]}, {path: 'icon.png', variants: null}];
        const callback = () => callbackCalls++;
        for (const input of inputs) {
          if (chrome.action.setIcon(input, callback) !== returned) return false;
          const call = seen.at(-1);
          if (call.details !== input || call.callback !== callback || call.receiver !== chrome.action) return false;
        }
        return callbackCalls === inputs.length;
        """#)
    }

    @Test func bothNamespacesAndAllActionAPIsAreGuarded() throws {
        try check(#"""
        for (const action of [chrome.action, chrome.browserAction, chrome.pageAction, browser.action]) action.setIcon({path: null});
        return seen.length === 4 && seen.every(call => call.details.path && !Object.keys(call.details.path).length);
        """#)
    }

    @Test func invalidInputsAndConflictingIconKeysStillReachEngineValidation() throws {
        try check(#"""
        for (const input of [null, undefined, 7, [], {path: 7}, {path: null, imageData: null}]) {
          chrome.action.setIcon(input);
          const safe = seen.at(-1).details;
          if (input && input.path === null && input.imageData === null) {
            if (!('path' in safe) || !('imageData' in safe)) return false;
          } else if (safe !== input) return false;
        }
        return seen.length === 6;
        """#)
    }

    @Test func mixedNullResetFieldsNeverProduceAnEmptyJSONPayload() throws {
        try check(#"""
        const input = Object.freeze({path: null, variants: null, tabId: 7});
        chrome.action.setIcon(input);
        const safe = seen[0].details;
        return safe.tabId === 7 && safe.path && !('variants' in safe) && input.path === null;
        """#)
    }
}
