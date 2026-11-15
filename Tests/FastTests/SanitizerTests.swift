import XCTest
@testable import Fast

/// What a crash's own words keep and lose on their way to the site
/// (Sanitizer): messages as Swift, Foundation and AppKit write them.
final class SanitizerTests: XCTestCase {
    private let home = "/Users/jane"

    private func clean(_ text: String) -> String { Sanitizer.clean(text, home: home) }

    func testWhatSaysWhatWentWrongStays() {
        for text in [
            "Fatal error: Unexpectedly found nil while unwrapping an Optional value",
            "Fast/Tab.swift:1204: Fatal error: Index out of range",
            "Swift/ContiguousArrayBuffer.swift:691: Fatal error: Index out of range",
            "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '-[__NSCFString objectForKey:]: unrecognized selector sent to instance 0x600002c8a1e0'",
            "*** -[NSURL initFileURLWithPath:]: nil string parameter",
            "abort() called",
            "*** multi-threaded process forked ***",
            "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already owned by current thread",
            "Precondition failed: tab 3 of 2 at build 202610051200",
            "~/Library/Application Support/Yab/session.json is fine",
            "/Users/Shared/Yab/notes.txt",
        ] {
            XCTAssertEqual(clean(text), text)
        }
    }

    func testAddressesOfPagesGoWithTheirQueriesAndFragments() {
        XCTAssertEqual(clean("Fatal error: Couldn't load https://accounts.google.com/o/oauth2/auth?client_id=123&state=abc#frag"),
                       "Fatal error: Couldn't load <url>")
        XCTAssertEqual(clean("reason: 'Invalid URL http://user:secret@bank.example:8443/account?token=1'"),
                       "reason: 'Invalid URL <url>'")
        XCTAssertEqual(clean("WebKit gave up on file:///Users/jane/Downloads/statement.pdf, sorry"),
                       "WebKit gave up on <url>, sorry")
        XCTAssertEqual(clean(#"{"NSErrorFailingURLStringKey":"https:\/\/mail.google.com\/mail\/u\/0\/#inbox\/FMfcgz"}"#),
                       #"{"NSErrorFailingURLStringKey":"<url>"}"#)
        XCTAssertEqual(clean("yab://diary/day?d=2026-10-05 then about:blank"), "<url> then about:blank")
    }

    func testEmailAddressesGo() {
        XCTAssertEqual(clean("Precondition failed: keychain item for jane.doe+yab@gmail.com missing"),
                       "Precondition failed: keychain item for <email> missing")
        XCTAssertEqual(clean("mailto:boss@corp.co.uk"), "mailto:<email>")
    }

    func testTheHomeFolderIsTildeAndAnyonesToo() {
        XCTAssertEqual(
            clean(#"Fatal error: 'try!' expression unexpectedly raised an error: Error Domain=NSCocoaErrorDomain Code=260 "The file “history.json” couldn’t be opened." UserInfo={NSFilePath=/Users/jane/Library/Application Support/Yab/history.json}"#),
            #"Fatal error: 'try!' expression unexpectedly raised an error: Error Domain=NSCocoaErrorDomain Code=260 "The file “history.json” couldn’t be opened." UserInfo={NSFilePath=~/Library/Application Support/Yab/history.json}"#
        )
        // A build machine's path in a failed check's file name.
        XCTAssertEqual(clean("/Users/dev/Documents/GitHub/fast/Sources/Fast/Vault.swift:88: Precondition failed"),
                       "~/Documents/GitHub/fast/Sources/Fast/Vault.swift:88: Precondition failed")
        // JSON's escaped slashes.
        XCTAssertEqual(clean(#""path":"\/Users\/jane\/Library\/Yab""#), #""path":"~\/Library\/Yab""#)
        XCTAssertEqual(clean(#""path":"\/Users\/someone\/x""#), #""path":"~\/x""#)
        XCTAssertEqual(clean("moving /private/var/folders/7k/k1x9_h2d5bq/T/yab-update-1/yab.zip"),
                       "moving <tmp>/T/yab-update-1/yab.zip")
    }

    func testLongHexGoesShortStays() {
        XCTAssertEqual(clean("token 3f9a2c4b5d6e7f8091a2b3c4d5e6f708 rejected"), "token <hex> rejected")
        XCTAssertEqual(clean("tab 6F9619FF-8B86-D011-B42D-00C04FC964FF closed twice"), "tab <hex> closed twice")
        XCTAssertEqual(clean("card 4242424242424242 declined"), "card <hex> declined")
        XCTAssertEqual(clean("3   yab                                 0x0000000102b4c8a0 yab + 2361504"),
                       "3   yab                                 <hex> yab + 2361504")
        XCTAssertEqual(clean("instance 0x600002c8a1e0, code 0xdeadbeef"), "instance 0x600002c8a1e0, code 0xdeadbeef")
    }

    /// An uncaught exception as Links.watchForTrouble writes it.
    func testAnExceptionWithItsStack() {
        let logged = """
        2026-10-05 11:35:28 +0000: NSInvalidArgumentException: *** -[__NSPlaceholderDictionary initWithObjects:forKeys:count:]: attempt to insert nil object from objects[1] for https://www.youtube.com/watch?v=dQw4w9WgXcQ
        0   CoreFoundation                      0x000000018d0c2ec0 __exceptionPreprocess + 176
        1   libobjc.A.dylib                     0x000000018cba6cd8 objc_exception_throw + 88
        2   yab                                 0x0000000102b4c8a0 $s4Fast3TabC5startyyF + 120
        """
        let cleaned = clean(logged)
        XCTAssertTrue(cleaned.hasPrefix("2026-10-05 11:35:28 +0000: NSInvalidArgumentException: *** -[__NSPlaceholderDictionary initWithObjects:forKeys:count:]: attempt to insert nil object from objects[1] for <url>\n"))
        XCTAssertTrue(cleaned.contains("CoreFoundation                      <hex> __exceptionPreprocess + 176"))
        XCTAssertTrue(cleaned.contains("$s4Fast3TabC5startyyF + 120"))
        for gone in ["youtube", "dQw4w9WgXcQ", "000000018d0c2ec0"] {
            XCTAssertFalse(cleaned.contains(gone), gone)
        }
    }
}
