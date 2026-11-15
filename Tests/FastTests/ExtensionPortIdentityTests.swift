import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// Port wrappers are recreated by the native API. Extension-owned state must
/// remain on the endpoint whose onMessage listener was registered.
@Suite struct ExtensionPortIdentityTests {
    @Test func registeredEndpointKeepsExtensionState() throws {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "    const numbered = new WeakSet();"))
        let end = try #require(script.range(of: "    const connect = runtime.connect;", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript("""
        const setTimeout = f => { throw Error('Unexpected listener exception'); };
        function Event() { this.listeners = new Set(); }
        Event.prototype.addListener = function(f) { this.listeners.add(f); };
        Event.prototype.fire = function(...args) { for (const f of [...this.listeners]) f(...args); };
        const event = new Event(), messages = [], replies = [];
        const port = {name:'128', s:false, onMessage:event, postMessage(message) { messages.push(message); }};
        """ + String(script[start.lowerBound..<end.lowerBound]) + """
        number(port);
        const listener = (message, received) => replies.push({message, same:received === port, state:received && received.s});
        port.onMessage.addListener(listener);
        event.fire({__yabPort:['peer',1],message:{H:40}}, {name:'128'});
        event.fire({__yabPort:['peer',1],message:{H:40}}, {name:'128'});
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("replies[0].same === true && replies[0].state === false")?.toBool() == true,
                "PORT_ENDPOINT_IDENTITY: registered endpoint retains extension-owned state")
        #expect(context.evaluateScript("replies.length === 1 && replies[0].message.H === 40")?.toBool() == true)
        context.evaluateScript("""
        port.onMessage.removeListener(listener);
        event.fire({__yabPort:['peer',2],message:{H:40}}, port);
        port.postMessage({i:1,a:[{}]});
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("replies.length === 1 && !port.onMessage.hasListener(listener)")?.toBool() == true)
        #expect(context.evaluateScript("Array.isArray(messages[0].__yabPort) && messages[0].message.i === 1")?.toBool() == true)
    }

    /// A content script's port in the worker: both listeners get the port
    /// they were added to, as the extension API specifies.
    @Test func contentPortListenersGetTheirEndpoint() throws {
        let script = ExtensionShims.script
        let numbered = try #require(script.range(of: "    const numbered = new WeakSet();"))
        let start = try #require(script.range(of: "    const set = (target, key, value) =>", range: numbered.upperBound..<script.endIndex))
        let end = try #require(script.range(of: "    const number = (port) => {", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript("""
        function Event() { this.listeners = new Set(); }
        Event.prototype.addListener = function(f) { this.listeners.add(f); };
        Event.prototype.removeListener = function(f) { this.listeners.delete(f); };
        Event.prototype.hasListener = function(f) { return this.listeners.has(f); };
        Event.prototype.fire = function(...args) { for (const f of [...this.listeners]) f(...args); };
        const message = new Event(), gone = new Event(), seen = [];
        const port = {s:{m:7}, onMessage:message, onDisconnect:gone};
        """ + String(script[start.lowerBound..<end.lowerBound]) + """
        sameEndpoint(port, "onMessage");
        sameEndpoint(port, "onDisconnect");
        const heard = (m, p) => seen.push(['message', m.H, p.s.m]);
        port.onMessage.addListener(heard);
        port.onDisconnect.addListener((p) => seen.push(['gone', p.s.m]));
        message.fire({H:40}, {name:'other wrapper'});
        port.onMessage.removeListener(heard);
        message.fire({H:41}, {});
        gone.fire({name:'other wrapper'});
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("JSON.stringify(seen)")?.toString() == #"[["message",40,7],["gone",7]]"#)
    }
}
