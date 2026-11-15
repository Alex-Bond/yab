import Testing

/// For suites whose tests rewrite the test world's spaces list (spaces.json:
/// `Spaces.write`, and every `switchSpace` through `keepPaint`). Each write
/// posts `Spaces.changed` and every live Browser reloads its spaces from the
/// file, so a test of one such suite takes away the made-up spaces of a test
/// of another running beside it. SharedPinsTests' call test lost its "Work"
/// space while it waited for its page as AssistantTabSpaceTests' worlds came
/// and went, and its switch there went nowhere. `.serialized` orders a
/// suite's own tests only; a suite marked `.spacesListAlone` runs while no
/// other one so marked does.
struct SpacesListAlone: SuiteTrait, TestScoping {
    typealias TestScopeProvider = SpacesListAlone

    // Not recursive: the scope is the whole suite's, once (a recursive suite
    // trait goes onto each test function, which takes only test traits).
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await Turns.shared.take(function)
    }

    private actor Turns {
        static let shared = Turns()
        private var held = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func take(_ body: @Sendable () async throws -> Void) async throws {
            while held { await withCheckedContinuation { waiting.append($0) } }
            held = true
            defer {
                held = false
                if !waiting.isEmpty { waiting.removeFirst().resume() }
            }
            try await body()
        }
    }
}

extension Trait where Self == SpacesListAlone {
    static var spacesListAlone: Self { Self() }
}
