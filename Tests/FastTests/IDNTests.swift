import Foundation
import Testing
@testable import Fast

// Hosts in punycode, as they are read: decoded when the name is what it
// looks like, kept in xn-- form when it could pass for another.
struct IDNTests {
    @Test func decodesPunycode() {
        // RFC 3492's own samples and everyday names.
        #expect(IDN.decode("caf-dma") == "café")
        #expect(IDN.decode("mnchen-3ya") == "münchen")
        #expect(IDN.decode("bcher-kva") == "bücher")
        #expect(IDN.decode("e1afmkfd") == "пример")
        #expect(IDN.decode("p1ai") == "рф")
        #expect(IDN.decode("80ak6aa92e") == "аррӏе")
        #expect(IDN.decode("pple-43d") == "аpple")
        #expect(IDN.decode("wgv71a119e") == "日本語")
        #expect(IDN.decode("egbpdaj6bu4bxfgehfvwxn") == "ليهمابتكلموشعربي؟")
        #expect(IDN.decode("ihqwcrb4cv8a8dqg056pqjye") == "他们为什么不说中文")
        #expect(IDN.decode("CAF-DMA") == "café")
    }

    @Test func refusesWhatIsNotPunycode() {
        #expect(IDN.decode("") == nil)
        #expect(IDN.decode("abc-") == nil)            // plain ASCII never needs it
        #expect(IDN.decode("caf-dm!") == nil)
        #expect(IDN.decode("caf-") == nil)
        #expect(IDN.decode("99999999999999999999") == nil) // a number past 32 bits
        #expect(IDN.decode("café") == nil)
    }

    @Test func showsRealNamesDecoded() {
        #expect(IDN.shown("xn--caf-dma.fr") == "café.fr")
        #expect(IDN.shown("xn--mnchen-3ya.de") == "münchen.de")
        #expect(IDN.shown("www.xn--bcher-kva.de") == "www.bücher.de")
        #expect(IDN.shown("xn--e1afmkfd.xn--p1ai") == "пример.рф")
        #expect(IDN.shown("xn--wgv71a119e.jp") == "日本語.jp")
        #expect(IDN.shown("github.com") == "github.com")
        #expect(IDN.shown("192.168.0.1") == "192.168.0.1")
    }

    @Test func keepsSpoofsInPunycode() {
        // Latin with one Cyrillic а: two scripts in one label.
        #expect(IDN.shown("xn--pple-43d.com") == "xn--pple-43d.com")
        // A whole word of Cyrillic look-alikes outside Cyrillic's own domains.
        #expect(IDN.shown("xn--80ak6aa92e.com") == "xn--80ak6aa92e.com")
        // Any label failing keeps the whole host as it came.
        #expect(IDN.shown("xn--pple-43d.xn--mnchen-3ya.de") == "xn--pple-43d.xn--mnchen-3ya.de")
        // Not punycode at all.
        #expect(IDN.shown("xn--zz!.com") == "xn--zz!.com")
    }

    @Test func spoofRules() {
        // One script, or Japanese, Chinese or Korean beside Latin.
        #expect(IDN.safe("café", tld: "fr"))
        #expect(IDN.safe("пример", tld: "рф"))
        #expect(IDN.safe("ドメイン名例", tld: "jp"))
        #expect(IDN.safe("abc日本語ドメイン", tld: "jp"))
        #expect(IDN.safe("한국어abc", tld: "kr"))
        #expect(IDN.safe("ελληνικά", tld: "gr"))
        // Mixed scripts that only imitate.
        #expect(!IDN.safe("аpple", tld: "com"))            // Cyrillic а, Latin pple
        #expect(!IDN.safe("pаypal", tld: "com"))
        #expect(!IDN.safe("gοogle", tld: "com"))           // Greek ο
        #expect(!IDN.safe("한국어пример", tld: "com"))
        // Whole-script look-alikes: refused abroad, fine at home.
        #expect(!IDN.safe("аррӏе", tld: "com"))
        #expect(!IDN.safe("ехаmрlе", tld: "com"))
        #expect(IDN.safe("аррӏе", tld: "ru"))
        #expect(IDN.safe("аррӏе", tld: "рф"))
        #expect(!IDN.safe("ορο", tld: "com"))
        // A Cyrillic word with letters Latin has none of is just Russian.
        #expect(IDN.safe("яндекс", tld: "com"))
        // Letters that read as others or as punctuation.
        #expect(!IDN.safe("ıos", tld: "com"))               // dotless i
        #expect(!IDN.safe("gɑmes", tld: "com"))             // IPA alpha
        #expect(!IDN.safe("a\u{01C3}b", tld: "com"))        // click letter like !
        // Invisible and folding characters.
        #expect(!IDN.safe("ab\u{200D}c", tld: "com"))       // zero-width joiner
        #expect(!IDN.safe("ａｂｃé", tld: "com"))            // fullwidth
        #expect(!IDN.safe("Café", tld: "com"))              // uppercase never stored
        #expect(!IDN.safe("ﬁé", tld: "com"))                // ligature
        #expect(!IDN.safe("a/é", tld: "com"))
        // Marks: on a letter, once.
        #expect(IDN.safe("cafe\u{0301}".precomposedStringWithCanonicalMapping, tld: "fr"))
        #expect(!IDN.safe("cafe\u{0301}\u{0301}", tld: "fr"))
        #expect(!IDN.safe("1\u{0301}é", tld: "fr"))
        // Digits from two systems.
        #expect(!IDN.safe("é1٢", tld: "com"))
    }

    @Test func addressesReadDecoded() {
        let url = URL(string: "https://xn--mnchen-3ya.de/rathaus")!
        #expect(Address.pretty(url) == "xn--mnchen-3ya.de/rathaus")   // the history key stays
        #expect(Address.shown(url) == "münchen.de/rathaus")
        // The editable address keeps www (18b80098) and still decodes,
        // and editing it goes back to the same www host.
        let www = URL(string: "https://www.xn--caf-dma.fr/menu?d=1")!
        #expect(Address.whole(www) == "www.café.fr/menu?d=1")
        #expect(Address.shown(www) == "café.fr/menu")
        #expect(Address.url(from: Address.whole(www))?.absoluteString == "https://www.xn--caf-dma.fr/menu?d=1")
        #expect(Address.shown(URL(string: "https://xn--pple-43d.com/")!) == "xn--pple-43d.com")
        #expect(IDN.shownAddress("xn--caf-dma.fr:8443/x") == "café.fr:8443/x")
        #expect(IDN.shownAddress("Menu du café") == "Menu du café")
        // What the field shows goes back to the same place.
        #expect(Address.url(from: Address.whole(url))?.absoluteString == "https://xn--mnchen-3ya.de/rathaus")
        #expect(Address.url(from: Address.whole(url))?.host() == "xn--mnchen-3ya.de")
        #expect(Address.url(from: "https://café.fr")?.host() == "xn--caf-dma.fr")
    }

    @Test func linkStatusReadsDecoded() {
        let url = URL(string: "https://xn--caf-dma.fr/menu")!
        #expect(LinkStatus.place(url) == "café.fr/menu")
        #expect(LinkStatus.place(URL(string: "https://xn--80ak6aa92e.com/")!) == "xn--80ak6aa92e.com/")
    }
}
