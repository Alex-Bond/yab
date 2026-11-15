import Foundation
import JavaScriptCore

/// WebKit's graph algorithm runs on a dedicated queue, away from AppKit.
/// A snapshot can be selected again without retaining another JavaScript VM.
final class DevHeapEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "devtools.heap", qos: .userInitiated)
    private var context: JSContext?
    private var snapshot: JSValue?
    private var loaded = ""
    private let scriptURL: URL?
    init(scriptURL: URL? = nil) { self.scriptURL = scriptURL }
    func read(_ text: String, method: String = "serialize", arguments: [Any] = [], done: @escaping ([String: Any]?, String?) -> Void) {
        queue.async { [self] in
            do {
                if text != loaded {
                    guard let data = text.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let nodes = raw["nodes"] as? [Int], let names = raw["nodeClassNames"] as? [String],
                          let edges = raw["edges"] as? [Int], let edgeTypes = raw["edgeTypes"] as? [String], let edgeNames = raw["edgeNames"] as? [String] else { throw Failure.invalid }
                    let stride = raw["type"] as? String == "GCDebugging" ? 7 : 4
                    guard nodes.count >= stride, nodes.count % stride == 0, edges.count % 4 == 0 else { throw Failure.invalid }
                    let ids = Set(Swift.stride(from: 0, to: nodes.count, by: stride).map { nodes[$0] })
                    guard ids.count == nodes.count / stride, nodes[0] == 0 else { throw Failure.invalid }
                    for at in Swift.stride(from: 0, to: nodes.count, by: stride) {
                        guard names.indices.contains(nodes[at + 2]), nodes[at + 1] >= 0 else { throw Failure.invalid }
                    }
                    var previousFrom = -1
                    for at in Swift.stride(from: 0, to: edges.count, by: 4) {
                        let from = edges[at], to = edges[at + 1], kind = edges[at + 2], label = edges[at + 3]
                        guard from >= previousFrom, ids.contains(from), ids.contains(to), edgeTypes.indices.contains(kind), label >= 0 else { throw Failure.invalid }
                        if edgeTypes[kind] == "Property", !edgeNames.indices.contains(label) { throw Failure.invalid }
                        previousFrom = from
                    }
                    guard let url = scriptURL ?? Bundle.main.url(forResource: "heap-snapshot", withExtension: "js", subdirectory: "DevTools"),
                          let js = try? String(contentsOf: url, encoding: .utf8), let vm = JSContext() else { throw Failure.missing }
                    vm.evaluateScript("var console = {assert:function(){},error:function(){}};")
                    vm.evaluateScript(js)
                    vm.setObject(text, forKeyedSubscript: "__snapshotText" as NSString)
                    let value = vm.evaluateScript("new HeapSnapshot(null, 0, __snapshotText)")
                    guard vm.exception == nil, let value, !value.isUndefined else { throw Failure.invalid }
                    vm.setObject(nil, forKeyedSubscript: "__snapshotText" as NSString)
                    context = vm; snapshot = value; loaded = text
                }
                context?.exception = nil
                let value = snapshot?.invokeMethod(method, withArguments: arguments)
                guard context?.exception == nil, let value, !value.isUndefined else { throw Failure.invalid }
                let result: [String: Any]
                if value.isArray { result = ["nodes": value.toArray() ?? []] }
                else { result = value.toDictionary() as? [String: Any] ?? [:] }
                DispatchQueue.main.async { done(result, nil) }
            } catch {
                DispatchQueue.main.async { done(nil, error.localizedDescription) }
            }
        }
    }
    private enum Failure: LocalizedError {
        case invalid, missing
        var errorDescription: String? { self == .missing ? "The bundled heap analyzer is missing" : "Invalid JavaScriptCore heap snapshot graph" }
    }
}
