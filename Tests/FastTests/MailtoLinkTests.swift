import Foundation
import Testing
@testable import MailCore

// A mailto: link clicked on a page, as the new mail it opens over it
// (Browser.mailto, docs/mail.md, Mailto links).
struct MailtoLinkTests {
    func link(_ text: String) -> MailtoLink? { URL(string: text).flatMap(MailtoLink.init) }

    @Test func plainAddress() {
        let made = link("mailto:hello@northwind.studio")
        #expect(made?.to == ["hello@northwind.studio"])
        #expect(made?.subject == "")
        #expect(made?.body == "")
    }

    @Test func everyFieldItAsksFor() {
        let made = link("mailto:a@x.com,b@y.com?cc=c@z.com&bcc=d@z.com&subject=Project%20inquiry&body=Hi%2C%0D%0Athere")
        #expect(made?.to == ["a@x.com", "b@y.com"])
        #expect(made?.cc == ["c@z.com"])
        #expect(made?.bcc == ["d@z.com"])
        #expect(made?.subject == "Project inquiry")
        #expect(made?.body == "Hi,\nthere")
        #expect(made?.people == ["a@x.com", "b@y.com", "c@z.com", "d@z.com"])
    }

    @Test func toInTheFieldsAndOnce() {
        let made = link("mailto:?to=a@x.com&To=A@x.com,b@y.com&SUBJECT=Hi")
        #expect(made?.to == ["a@x.com", "b@y.com"])
        #expect(made?.subject == "Hi")
    }

    @Test func notAnAddressLeftOut() {
        #expect(link("mailto:nobody?subject=x")?.to == [])
        #expect(link("mailto:%20a%40x.com%20")?.to == ["a@x.com"])
    }

    /// A line break in the subject is a space: it can't begin a header.
    @Test func subjectIsOneLine() {
        #expect(link("mailto:a@x.com?subject=Hi%0D%0ABcc:%20evil@x.com")?.subject == "Hi Bcc: evil@x.com")
    }

    @Test func otherSchemesAreNot() {
        #expect(link("https://x.com") == nil)
        #expect(link("tel:123") == nil)
    }
}
