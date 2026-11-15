// What a flush costs the main thread, measured on a copy of a real journal
// (evals/sync-cost/run.sh): the counts Settings › Sync shows, read after
// every flush until 2026-10-08, and one chat's step told to the journal,
// every chat's steps read for it before `under`, only its own after.
// Compiled together with Sources/SyncKit, so `Journal` is this tree's.

import Foundation

let path = CommandLine.arguments[1]
let rounds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 15 : 15
let journal = try Journal(path: path, device: "bench")

func measure(_ name: String, _ body: () throws -> Void) rethrows -> Double {
    try body()
    var took: [Double] = []
    for _ in 0..<rounds {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        took.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    took.sort()
    let median = took[took.count / 2]
    print(name.padding(toLength: 40, withPad: " ", startingAt: 0) + String(format: "median %8.2f ms   min %8.2f   max %8.2f", median, took.first!, took.last!))
    return median
}

func living(_ collection: String) -> [Record] { journal.living(collection) }

var results: [String: Double] = [:]

// The counts, as SyncCenter.count reads them.
results["counts"] = measure("counts (every flush before)") {
    _ = [
        living("space").count, living("tab").count, living("bookmark").filter { $0["url"] != nil }.count,
        living("setting").count, living("file").count + living("icon").count + living("answer").count,
        living("routine").count, living("visit").count, living("chat").count,
        Set(living("memory").map { $0["day"]?.string ?? $0.id }).count,
        living("login").count, living("card").count + living("address").count,
    ]
}

// One chat's steps, as they stand, told again: nothing changes, so what is
// left is the reading.
let items = journal.all("chatitem")
let byChat = Dictionary(grouping: items, by: { $0.fields["chat"]?.string ?? "" })
if let (chat, steps) = byChat.max(by: { $0.value.count < $1.value.count }) {
    let now = Dictionary(uniqueKeysWithValues: steps.filter { $0.alive() }.map { ($0.id, $0.visible) })
    let touched: Set<String> = [chat]
    print("chat items: \(items.count) in \(byChat.count) chats; the biggest has \(steps.count)")
    results["chat_before"] = try measure("one chat's step, every chat read") {
        try journal.reconcile("chatitem", now, within: { touched.contains($0.fields["chat"]?.string ?? "") })
    }
    results["chat_after"] = try measure("one chat's step, its own read") {
        try journal.reconcile("chatitem", now, within: { touched.contains($0.fields["chat"]?.string ?? "") }, under: [chat + "/"])
    }
    let smallest = byChat.min(by: { $0.value.count < $1.value.count })!
    let few = Dictionary(uniqueKeysWithValues: smallest.value.filter { $0.alive() }.map { ($0.id, $0.visible) })
    results["chat_small_after"] = try measure("smallest chat's step, its own read") {
        try journal.reconcile("chatitem", few, within: { $0.fields["chat"]?.string == smallest.key }, under: [smallest.key + "/"])
    }
}

// What else a flush tells the journal often: the last two weeks of history
// every half minute, and a tab picked.
for collection in ["visit", "tab", "setting"] {
    let now = Dictionary(uniqueKeysWithValues: living(collection).map { ($0.id, $0.visible) })
    results[collection] = try measure("\(collection) told again (\(now.count))") { try journal.reconcile(collection, now) }
}

let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
print(String(decoding: data, as: UTF8.self))
