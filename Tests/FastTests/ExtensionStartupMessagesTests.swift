import JavaScriptCore
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct ExtensionStartupMessagesTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var background = true, inContent = false, now = 0, timers = [], verdicts = [];
        Date.now = () => now;
        function setTimeout(f, ms) { const timer = {f, at:now+ms}; timers.push(timer); return timer; }
        function clearTimeout(timer) { timers = timers.filter(t => t !== timer); }
        function advance(ms) { now += ms; for (const t of [...timers]) if (t.at <= now) { clearTimeout(t); t.f(); } }
        function put(o, k, v) { o[k] = v; }
        function tell(message, verdict) { verdicts.push(verdict); }
        function join() {} function leave() {}
        var nativeListener, event = {addListener:f => nativeListener=f, removeListener:() => {nativeListener=null}};
        var replies=[], calls=0;
        var importing = 0, peers = new Set(); function afterImport() { return false; }
        """#)
        // Run the actual dispatcher, including listener registration. The
        // clock makes slow startup and expiry deterministic without sleeping.
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "const gather = (event, told) => {"))
        let end = try #require(script.range(of: "// Chrome's runtime functions work", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]) + "\ngather(event, true);")
        try #require(context.exception == nil)
        return context
    }

    @Test func firstMessageWaitsForItsHandlerWithoutReplayingOthers() throws {
        let c = try context()
        c.evaluateScript(#"""
        event.addListener(() => { calls++; });
        var kept = nativeListener({command:'fido2GetCredentialRequest'}, {}, value => replies.push(value));
        advance(2000);
        event.addListener((message, sender, reply) => {
          if (message.command !== 'fido2GetCredentialRequest') return;
          reply('credential-result');
        });
        event.addListener(() => { throw Error('answered messages must leave the queue'); });
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("kept")?.toBool() == true)
        #expect(c.objectForKeyedSubscript("calls")?.toInt32() == 1)
        #expect(c.evaluateScript("JSON.stringify(replies)")?.toString() == #"["credential-result"]"#)
        #expect(c.evaluateScript("timers.length")?.toInt32() == 0)
    }

    @Test func unansweredStartupMessageExpiresAndLaterMessagesPass() throws {
        let c = try context()
        c.evaluateScript(#"""
        var kept = nativeListener({command:'fido2GetCredentialRequest'}, {}, value => replies.push(value));
        advance(15000);
        var later = nativeListener({command:'unknown'}, {}, value => replies.push(value));
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("kept")?.toBool() == true)
        #expect(c.evaluateScript("replies.length")?.toInt32() == 1)
        #expect(c.objectForKeyedSubscript("later")?.isUndefined == true)
    }

    @Test func frameInitializationWaitsForLateWorkerHandlerOnce() throws {
        let c = try context()
        c.evaluateScript(#"""
        event.addListener(() => { calls++; });
        var kept = nativeListener({handler:'initializeFrame'}, {}, value => replies.push(value));
        advance(2000);
        event.addListener((message, sender, reply) => {
          if (message.handler === 'initializeFrame') reply({isEnabledForUrl:true, frameId:0});
        });
        event.addListener(() => { throw Error('answered messages must leave the queue'); });
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("kept")?.toBool() == true)
        #expect(c.objectForKeyedSubscript("calls")?.toInt32() == 1)
        #expect(c.evaluateScript("JSON.stringify(replies)")?.toString() == #"[{"isEnabledForUrl":true,"frameId":0}]"#)
        #expect(c.evaluateScript("timers.length")?.toInt32() == 0)
    }

    @Test func initialPreferencesWaitForTheirLateWorkerHandlerOnce() throws {
        let c = try context()
        c.evaluateScript(#"""
        event.addListener(() => { calls++; });
        var kept=nativeListener(['Prefs.getAll',[]],{},value=>replies.push(value));
        advance(2000);
        event.addListener((message,sender,reply) => {
          if (Array.isArray(message) && message[0]==='Prefs.getAll') reply({ready:true});
        });
        event.addListener(() => { throw Error('answered preference requests must leave the queue'); });
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("kept")?.toBool() == true)
        #expect(c.objectForKeyedSubscript("calls")?.toInt32() == 1)
        #expect(c.evaluateScript("JSON.stringify(replies)")?.toString() == #"[{"ready":true}]"#)
        #expect(c.evaluateScript("timers.length")?.toInt32() == 0)
    }

    @Test func claimedPreferencesAreNotReplayedToAnotherHandler() throws {
        let c = try context()
        c.evaluateScript(#"""
        nativeListener(['Prefs.getAll',[]],{},value=>replies.push(value));
        var complete;
        event.addListener((message,sender,reply) => {complete=reply;return true;});
        event.addListener(() => {calls++;});
        complete({ready:true});complete({duplicate:true});advance(15000);
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("calls")?.toInt32() == 0)
        #expect(c.evaluateScript("JSON.stringify(replies)")?.toString() == #"[{"ready":true}]"#)
    }

    @Test func unrelatedPreferencesAndRequestsAfterStartupAreNotHeld() throws {
        let c = try context()
        c.evaluateScript(#"""
        var unrelated = [ ['Prefs.set',['x',1]], ['Prefs.getAll',['x']], ['Other.getAll',[]], ['Prefs.getAll'] ]
          .map(message=>nativeListener(message,{},value=>replies.push(value))===undefined);
        advance(15000);
        var late=nativeListener(['Prefs.getAll',[]],{},value=>replies.push(value));
        """#)
        #expect(c.exception == nil)
        #expect(c.evaluateScript("unrelated.every(Boolean)")?.toBool() == true)
        #expect(c.objectForKeyedSubscript("late")?.isUndefined == true)
        #expect(c.evaluateScript("replies.length+timers.length")?.toInt32() == 0)
    }

    @Test func unclaimedPreferencesExpireWithoutBeingReplayed() throws {
        let c = try context()
        c.evaluateScript(#"""
        var kept=nativeListener(['Prefs.getAll',[]],{},value=>replies.push(value));
        advance(15000);
        event.addListener(()=>{calls++;return true;});
        """#)
        #expect(c.objectForKeyedSubscript("kept")?.toBool() == true)
        #expect(c.evaluateScript("replies.length===1 && replies[0]===undefined && timers.length===0 && calls===0")?.toBool() == true)
    }

    @Test func acceptedAsyncRequestIsNeverDeliveredToAnotherHandler() throws {
        let c = try context()
        c.evaluateScript(#"""
        nativeListener({command:'fido2GetCredentialRequest'}, {}, value => replies.push(value));
        var complete;
        event.addListener((message, sender, reply) => { complete = reply; return true; });
        event.addListener(() => { calls++; });
        complete('done');
        advance(15000);
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("calls")?.toInt32() == 0)
        #expect(c.evaluateScript("JSON.stringify(replies)")?.toString() == #"["done"]"#)
    }

    @Test(arguments: ["should-intercept-webauthn-request", "get-credential", "create-credential"])
    func onePasswordRequestWaitsForItsLateHandlerOnce(name: String) throws {
        let c = try context()
        c.setObject(name, forKeyedSubscript: "requestedName" as NSString)
        c.evaluateScript(#"""
        event.addListener(() => { calls++; });
        var kept = nativeListener({name:requestedName, data:{}}, {}, value => replies.push(value));
        // Before 1Password's two-second interception-settings deadline.
        advance(1000);
        event.addListener((message, sender, reply) => {
          if (message.name === requestedName) reply({type:'Success', data:{fillPasskeys:true, savePasskeys:true}});
        });
        event.addListener(() => { throw Error('answered messages must leave the queue'); });
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("kept")?.toBool() == true)
        #expect(c.objectForKeyedSubscript("calls")?.toInt32() == 1)
        #expect(c.evaluateScript("JSON.stringify(replies)")?.toString() == #"[{"type":"Success","data":{"fillPasskeys":true,"savePasskeys":true}}]"#)
        #expect(c.evaluateScript("timers.length")?.toInt32() == 0)
    }

    @Test func onePasswordRequestExpiresWithoutBeingReplayed() throws {
        let c = try context()
        c.evaluateScript(#"""
        var kept = nativeListener({name:'should-intercept-webauthn-request', data:{}}, {}, value => replies.push(value));
        advance(15000);
        event.addListener(() => { calls++; return true; });
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("kept")?.toBool() == true)
        #expect(c.evaluateScript("replies.length")?.toInt32() == 1)
        #expect(c.evaluateScript("replies[0] === undefined")?.toBool() == true)
        #expect(c.objectForKeyedSubscript("calls")?.toInt32() == 0)
        #expect(c.evaluateScript("timers.length")?.toInt32() == 0)
    }

    @Test(arguments: ["unknown", "cancel-credential", "notify-settings-changed"])
    func unrelatedMessagesKeepTheirNoReceivingEndBehavior(name: String) throws {
        let c = try context()
        c.setObject(name, forKeyedSubscript: "requestedName" as NSString)
        c.evaluateScript(#"""
        var kept = nativeListener({name:requestedName, data:{}}, {}, value => replies.push(value));
        event.addListener(() => { calls++; return true; });
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("kept")?.isUndefined == true)
        #expect(c.objectForKeyedSubscript("calls")?.toInt32() == 0)
        #expect(c.evaluateScript("replies.length + timers.length")?.toInt32() == 0)
    }

    @Test func onePasswordMessagesAreNotHeldAfterStartup() throws {
        let c = try context()
        c.evaluateScript(#"""
        advance(15000);
        var kept = nativeListener({name:'should-intercept-webauthn-request', data:{}}, {}, value => replies.push(value));
        event.addListener(() => { calls++; return true; });
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("kept")?.isUndefined == true)
        #expect(c.objectForKeyedSubscript("calls")?.toInt32() == 0)
        #expect(c.evaluateScript("replies.length + timers.length")?.toInt32() == 0)
    }

}
