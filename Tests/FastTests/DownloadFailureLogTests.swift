import Foundation
import Testing
@testable import Fast

@MainActor
struct DownloadFailureLogTests {
    @Test func publicationFailureIncludesBothPathsAndUnderlyingError() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: underlying])
        let fields = DownloadFailureLog.fields(error, destination: URL(fileURLWithPath: "/Volumes/Work/report.pdf"),
                                               staging: URL(fileURLWithPath: "/private/tmp/transfer"))
        #expect(fields["domain"] as? String == NSCocoaErrorDomain)
        #expect(fields["code"] as? Int == NSFileWriteNoPermissionError)
        #expect(fields["underlyingCode"] as? Int == Int(EACCES))
        #expect(fields["destination"] as? String == "/Volumes/Work/report.pdf")
        #expect(fields["staging"] as? String == "/private/tmp/transfer")
        #expect(JSONSerialization.isValidJSONObject(fields))
    }
}
