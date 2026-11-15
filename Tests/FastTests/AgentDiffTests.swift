import Testing
@testable import Fast

// What an agent is told changed after it acted (AgentPage.diff): elements
// by their refs, words by their lines, and the whole page back when most
// of it is new.
@MainActor
struct AgentDiffTests {
    static func seen(_ tree: String, _ said: [String] = []) -> AgentPage.Seen {
        AgentPage.Seen(url: "https://example.com/", tree: tree, said: said, interactive: true)
    }

    static let form = """
    heading "Where to?" level=1
    e1 combobox "Destination"
    e2 combobox "Nights" value="1"
    e3 radio "Economy" checked
    e4 radio "Business"
    e5 checkbox "Add travel insurance"
    e6 button "Continue"
    e7 link "Help" href=/help
    e8 link "Terms" href=/terms
    e9 link "Privacy" href=/privacy
    e10 link "Contact" href=/contact
    e11 link "About" href=/about
    e12 link "Careers" href=/careers
    e13 link "Press" href=/press
    """

    @Test func nothingChangedSaysSo() {
        #expect(AgentPage.diff(Self.seen(Self.form, ["Where to?"]), Self.seen(Self.form, ["Where to?"])) == "Nothing on the page changed.")
    }

    @Test func aChangedElementIsKeyedByItsRef() {
        let after = Self.form.replacingOccurrences(of: #"e2 combobox "Nights" value="1""#, with: #"e2 combobox "Nights" value="3""#)
        let said = AgentPage.diff(Self.seen(Self.form), Self.seen(after)) ?? ""
        #expect(said.contains(#"~ e2 combobox "Nights" value="3""#))
        #expect(!said.contains("e1"))
    }

    @Test func whatOpensComesAndWhatGoesIsGone() {
        let after = Self.form + "\n  e14 option \"Lisbon\"\n  e15 option \"Lima\""
        let said = AgentPage.diff(Self.seen(Self.form), Self.seen(after)) ?? ""
        #expect(said.contains(#"+ e14 option "Lisbon""#))
        #expect(said.contains(#"+ e15 option "Lima""#))
        let back = AgentPage.diff(Self.seen(after), Self.seen(Self.form)) ?? ""
        #expect(back.contains(#"- e14 option "Lisbon""#))
    }

    @Test func newWordsOnThePageAreTold() {
        let said = AgentPage.diff(Self.seen(Self.form, ["Where to?"]), Self.seen(Self.form, ["Where to?", "Saved."])) ?? ""
        #expect(said.contains("new text: “Saved.”"))
    }

    @Test func aFrameRefIsARef() {
        let before = "frame f1 (pay.example)\n  f1e1 textbox \"Card number\" value=\"\""
        let after = "frame f1 (pay.example)\n  f1e1 textbox \"Card number\" value=\"4242\""
        #expect(AgentPage.diff(Self.seen(before), Self.seen(after))?.contains("~ f1e1 textbox") == true)
    }

    @Test func aNewPageIsNotADiff() {
        let other = (1...14).map { "e\($0 + 100) link \"Item \($0)\"" }.joined(separator: "\n")
        #expect(AgentPage.diff(Self.seen(Self.form), Self.seen(other)) == nil)
    }
}
