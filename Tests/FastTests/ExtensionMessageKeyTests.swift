import JavaScriptCore
import Testing
@testable import Fast

@MainActor
struct ExtensionMessageKeyTests {
    @Test func sameMessageHasSameKeyAcrossObjectPropertyOrders() throws {
        let context = try #require(JSContext())
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "const keyOf = (message) => {"))
        let end = try #require(script.range(of: "const tell =", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        context.evaluateScript(#"""
        var worker = {type:'stateChange', l0:{type:'move', itemsMeta:[
          {itemId:'a', sourceParentId:'root'}], targetParentId:'trash'}};
        var page = {l0:{targetParentId:'trash', itemsMeta:[
          {sourceParentId:'root', itemId:'a'}], type:'move'}, type:'stateChange'};
        var same = keyOf(worker) === keyOf(page);
        var distinct = keyOf(worker) !== keyOf({type:'stateChange', l0:{
          type:'move', itemsMeta:[{itemId:'b', sourceParentId:'root'}],
          targetParentId:'trash'}});
        var orderedArraysDiffer = keyOf({items:[1,2]}) !== keyOf({items:[2,1]});
        """#)
        #expect(context.exception == nil)
        #expect(context.objectForKeyedSubscript("same")?.toBool() == true)
        #expect(context.objectForKeyedSubscript("distinct")?.toBool() == true)
        #expect(context.objectForKeyedSubscript("orderedArraysDiffer")?.toBool() == true)
    }
}
