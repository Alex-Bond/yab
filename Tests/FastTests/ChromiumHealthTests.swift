import Testing
import YabCoreClient
@testable import Fast

struct ChromiumHealthTests {
    @Test func onlyTheCurrentNativeRendererMayChangeResponsiveness() {
        let busy: [String: JSONValue] = ["rendererPID": .number(123), "responsive": .bool(false)]
        #expect(ChromiumResponsiveness(busy, rendererPID: 123)?.responsive == false)
        #expect(ChromiumResponsiveness(busy, rendererPID: 124) == nil)
        #expect(ChromiumResponsiveness(busy, rendererPID: nil) == nil)
        #expect(ChromiumResponsiveness(["rendererPID": .number(0), "responsive": .bool(true)], rendererPID: 0) == nil)
        #expect(ChromiumResponsiveness(["rendererPID": .number(123), "responsive": .bool(true)], rendererPID: 123)?.responsive == true)
        for value in [JSONValue.null, .string("false"), .number(0)] {
            #expect(ChromiumResponsiveness(["rendererPID": .number(123), "responsive": value], rendererPID: 123) == nil)
        }
    }
}
