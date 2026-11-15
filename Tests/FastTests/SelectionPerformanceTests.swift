import Foundation
import Testing
import WebKit
@testable import Fast

struct SelectionPerformanceTests {
    @Test @MainActor func readLatencyWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["YAB_SELECTION_BENCH"] == "1" else { return }
        let web = await AgentKeysTests.page("<textarea id=body style='width:600px;height:180px'></textarea>")

        func measure(_ value: String, start: Int, end: Int) async throws -> (median: Double, p95: Double) {
            let quoted = String(data: try JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
            _ = try await web.evaluateJavaScript("(() => { const e = document.getElementById('body'); e.value = \(quoted)[0]; e.focus(); e.setSelectionRange(\(start), \(end)); return true })()")
            _ = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
            var times: [Double] = []
            for _ in 0..<30 {
                let began = ContinuousClock.now
                _ = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
                let duration = began.duration(to: .now).components
                times.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
            }
            times.sort()
            return ((times[14] + times[15]) / 2, times[28])
        }

        let short = try await measure("Please improve this short sentence.", start: 0, end: 34)
        let deep = try await measure(String(repeating: "x", count: 50_000) + "selection", start: 50_000, end: 50_009)
        print("Selection read: short p50=\(short.median)ms p95=\(short.p95)ms; deep p50=\(deep.median)ms p95=\(deep.p95)ms")
    }

    @Test @MainActor func menuOpenLatencyWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["YAB_SELECTION_BENCH"] == "1" else { return }
        let tab = Fast.Tab(bench: true)
        defer { tab.close() }
        tab.page.navigate(html:"<textarea id=body>Improve this sentence, please.</textarea>",
                               base: URL(string: "https://example.test/"))
        for _ in 0..<100 {
            if (try? await tab.page.run("document.getElementById('body') != null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await tab.page.run("(() => { const e = document.getElementById('body'); e.focus(); e.select(); return true })()")
        let commands = SelectionCommands()
        var times: [Double] = []
        for _ in 0..<20 {
            let began = ContinuousClock.now
            var read: SelectionSnapshot?
            commands.peek(on: tab) { read = $0 }
            for _ in 0..<200 where read == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(read != nil)
            let duration = began.duration(to: .now).components
            times.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
            commands.close()
        }
        let cold = times.first ?? 0
        times.sort()
        print("Selection read for the field: cold=\(cold)ms p50=\((times[9] + times[10]) / 2)ms p95=\(times[18])ms max=\(times[19])ms")
    }
}
