import JavaScriptCore
import Testing
@testable import Fast

@MainActor
struct ExtensionClientIdentityTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var base='chrome-extension://connector/', workerURL=base+'background-worker.js';
        var chrome={runtime:{id:'connector'}}, dead=false, retired=new Set(), owners=new Map(), documentID='receiver-one';
        """)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "const peer = (said, sender) => {"))
        let end = try #require(script.range(of: "const same =", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        try #require(context.exception == nil)
        return context
    }

    @Test func originOnlyWorkerCanAcknowledgeThePortItReceived() throws {
        let c = try context()
        c.evaluateScript("""
        var bare=peer({owner:'worker-one'},{id:'connector',url:'chrome-extension://connector'});
        var full=peer({owner:'worker-one'},{id:'connector',url:workerURL});
        """)
        #expect(c.exception == nil)
        #expect(c.evaluateScript("bare?.url===workerURL && bare.tab===-1")?.toBool() == true)
        #expect(c.evaluateScript("bare?.key===full?.key && !!bare && !!full")?.toBool() == true)
    }

    @Test func anOriginOnlySenderMustNotBeATabOrAFrame() throws {
        let c = try context()
        for extra in ["tab:{id:1}", "frameId:0", "frameId:1", "frameId:-1,tab:{id:1}"] {
            #expect(c.evaluateScript("peer({owner:'worker-one'},{id:'connector',url:'chrome-extension://connector',\(extra)})===null")?.toBool() == true)
        }
        #expect(c.evaluateScript("peer({owner:'worker-one'},{id:'connector',url:'chrome-extension://connector',frameId:-1})?.url===workerURL")?.toBool() == true)
    }

    @Test func otherExtensionsMissingURLsAndUnlistedWorkersStayRefused() throws {
        let c = try context()
        for sender in [
            "{id:'other',url:'chrome-extension://connector'}",
            "{id:'connector',url:'chrome-extension://other'}",
            "{id:'connector',url:'https://connector'}",
            "{id:'connector'}",
        ] {
            #expect(c.evaluateScript("peer({owner:'worker-one'},\(sender))===null")?.toBool() == true)
        }
        c.evaluateScript("workerURL=null")
        #expect(c.evaluateScript("peer({owner:'worker-one'},{id:'connector',url:'chrome-extension://connector'})===null")?.toBool() == true)
    }

    @Test func realPagesKeepTheirIdentityAndCannotBecomeTheWorker() throws {
        let c = try context()
        c.evaluateScript("""
        var page=peer({owner:'page-one'},{id:'connector',url:base+'options.html',frameId:0});
        var changed=peer({owner:'page-one'},{id:'connector',url:'chrome-extension://connector'});
        var rootPage=peer({owner:'page-two'},{id:'connector',url:base,frameId:0});
        """)
        #expect(c.evaluateScript("page?.url===base+'options.html' && changed===null")?.toBool() == true)
        #expect(c.evaluateScript("rootPage?.url===base && rootPage.url!==workerURL")?.toBool() == true)
    }

    @Test func retiredAndMismatchedRealmsCannotRejoinThePort() throws {
        let c = try context()
        c.evaluateScript("retired.add('worker-one')")
        #expect(c.evaluateScript("peer({owner:'worker-one'},{id:'connector',url:'chrome-extension://connector'})===null")?.toBool() == true)
        #expect(c.evaluateScript("peer({owner:'worker-two',toOwner:'someone-else'},{id:'connector',url:'chrome-extension://connector'})===null")?.toBool() == true)
    }
}
