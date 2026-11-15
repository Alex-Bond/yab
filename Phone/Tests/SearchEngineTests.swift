import XCTest
@testable import YabPhone

@MainActor
final class SearchEngineTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    override func setUp() {
        suite = "owned-search-engine-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName:suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName:suite); defaults = nil }

    func testExistingMacEnginesPreserveLiteralPlusUnicodeAndQuerySeparators() throws {
        let expected:[SearchEngine:(String,String,String)] = [
            .google:("www.google.com","/search","q"), .duckduckgo:("duckduckgo.com","/","q"),
            .bing:("www.bing.com","/search","q"), .ecosia:("www.ecosia.org","/search","q"),
            .startpage:("www.startpage.com","/sp/search","query"), .kagi:("kagi.com","/search","q"),
            .brave:("search.brave.com","/search","q"), .qwant:("www.qwant.com","/","q")]
        for (engine, endpoint) in expected {
            let selected = SearchEngine.Selection(rawValue:engine.rawValue)
            let url = try XCTUnwrap(selected.url(for:"  café+a&b/? #two  "))
            let parts = try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false))
            XCTAssertEqual(url.scheme,"https"); XCTAssertEqual(url.host,endpoint.0); XCTAssertEqual(url.path,endpoint.1)
            XCTAssertEqual(parts.queryItems,[URLQueryItem(name:endpoint.2,value:"café+a&b/? #two")])
            XCTAssertTrue(parts.percentEncodedQuery?.contains("%2B") == true)
            XCTAssertNil(url.fragment); XCTAssertNil(selected.fallbackNote)
        }
    }

    func testCustomTemplateKeepsItsOriginAndSupportsTheMacPathAndQueryPlaceholders() throws {
        let selected = SearchEngine.Selection(rawValue:"custom",customTemplate:" https://find.owned.test:9443/path/%s?q=%s#source ")
        let url = try XCTUnwrap(selected.url(for:"one/two + café"))
        let parts = try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false))
        XCTAssertEqual(selected.engine,.custom); XCTAssertEqual(selected.name,"find.owned.test")
        XCTAssertEqual(url.host,"find.owned.test"); XCTAssertEqual(url.port,9443)
        XCTAssertEqual(parts.percentEncodedPath,"/path/one%2Ftwo%20%2B%20caf%C3%A9")
        XCTAssertEqual(parts.queryItems,[URLQueryItem(name:"q",value:"one/two + café")]); XCTAssertEqual(url.fragment,"source")
    }

    func testCustomTemplateNeverReplacesLiteralMarkersOrChangesCredentialsAndPort() throws {
        let template = "https://YABSEARCHWORDS.test/path/YABSEARCHWORDS/%s?literal=YABSEARCHWORDS&encoded=a%2Bb&q=%s#YABSEARCHWORDS"
        let selected = SearchEngine.Selection(rawValue: "custom", customTemplate: template)
        let url = try XCTUnwrap(selected.url(for: "café+tea"))
        XCTAssertEqual(url.absoluteString, "https://YABSEARCHWORDS.test/path/YABSEARCHWORDS/caf%C3%A9%2Btea?literal=YABSEARCHWORDS&encoded=a%2Bb&q=caf%C3%A9%2Btea#YABSEARCHWORDS")
        XCTAssertEqual(url.host?.lowercased(), "yabsearchwords.test")
        for invalid in ["https://%s:fixed@owned.test/?q=%s", "https://fixed:%s@owned.test/?q=%s", "https://owned.test:%s/?q=%s", "https://%s.owned.test/?q=%s", "%s://owned.test/?q=%s"] {
            XCTAssertFalse(SearchEngine.accepts(invalid), invalid)
        }
        let fixed = SearchEngine.Selection(rawValue: "custom", customTemplate: "https://fixed:unchanged@owned.test:9443/find?q=%s&literal=a%2Bb")
        let exact = try XCTUnwrap(fixed.url(for: "one+é"))
        XCTAssertEqual(exact.user, "fixed"); XCTAssertEqual(exact.password, "unchanged"); XCTAssertEqual(exact.port, 9443)
        XCTAssertEqual(URLComponents(url: exact, resolvingAgainstBaseURL: false)?.queryItems,
                       [.init(name: "q", value: "one+é"), .init(name: "literal", value: "a+b")])
    }

    func testUnknownOrUnsafeCustomSearchFallsBackHonestlyAndEmptyWordsMakeNoRequest() throws {
        let unknown = SearchEngine.Selection(rawValue:"future-provider")
        XCTAssertEqual(unknown.engine,.google); XCTAssertNotNil(unknown.fallbackNote)
        for template in ["https://%s.owned.test/?q=x","file:///tmp/%s","javascript:%s","https://owned.test/no-placeholder"] {
            let selected = SearchEngine.Selection(rawValue:"custom",customTemplate:template)
            XCTAssertFalse(SearchEngine.accepts(template)); XCTAssertEqual(selected.engine,.google)
            XCTAssertNotNil(selected.fallbackNote); XCTAssertEqual(try XCTUnwrap(selected.url(for:"actual words")).host,"www.google.com")
        }
        XCTAssertNil(unknown.url(for:" \n\t "))
    }

    func testLocalChoiceOutlivesTheStoreAndLaterMacChangesNeverOverwriteIt() {
        let store = SettingsStore(defaults:defaults)
        store.importSearchPreferences(engine:"duckduckgo",customTemplate:nil)
        XCTAssertEqual(store.searchSelection.engine,.duckduckgo)
        store.chooseSearchEngine(.bing)
        store.importSearchPreferences(engine:"qwant",customTemplate:nil)
        XCTAssertEqual(store.searchSelection.engine,.bing)
        let again = SettingsStore(defaults:defaults)
        XCTAssertEqual(again.searchSelection.engine,.bing)
        again.importSearchPreferences(engine:nil,customTemplate:nil)
        XCTAssertEqual(again.searchSelection.engine,.bing)
        XCTAssertNil(defaults.object(forKey:SearchEngine.key), "no Mac sync setting is written by the local selector")
    }

    func testReadOnlyMacDefaultTracksRemovalWithoutPersistingTheOldAccountPreference() {
        let store = SettingsStore(defaults:defaults)
        store.importSearchPreferences(engine:"brave",customTemplate:nil)
        XCTAssertEqual(store.searchSelection.engine,.brave)
        store.importSearchPreferences(engine:"ecosia",customTemplate:nil)
        XCTAssertEqual(store.searchSelection.engine,.ecosia)
        XCTAssertEqual(SettingsStore(defaults:defaults).searchSelection.engine,.google)
        store.importSearchPreferences(engine:nil,customTemplate:nil)
        XCTAssertEqual(store.searchSelection.engine,.google)
        XCTAssertNil(defaults.object(forKey:SettingsStore.Key.searchEngine))
    }

    func testTheMacsFieldSettingsLeadUntilThisIPhoneChooses() {
        let store = SettingsStore(defaults:defaults)
        XCTAssertTrue(store.guessesFromWords); XCTAssertTrue(store.offersAsk); XCTAssertTrue(store.offersTask)
        store.importFieldPreferences(firstRow:true,rows:["search","task"])
        XCTAssertFalse(store.guessesFromWords); XCTAssertFalse(store.offersAsk); XCTAssertTrue(store.offersTask)
        store.guessesFromWords = true
        store.importFieldPreferences(firstRow:true,rows:["search"])
        XCTAssertTrue(store.guessesFromWords); XCTAssertFalse(store.offersTask)
        let again = SettingsStore(defaults:defaults)
        XCTAssertTrue(again.guessesFromWords)
        again.importFieldPreferences(firstRow:nil,rows:nil)
        XCTAssertTrue(again.offersAsk); XCTAssertTrue(again.offersTask)
        XCTAssertNil(defaults.object(forKey:SettingsStore.Key.offersAsk), "the Mac's rows are never written here")
    }

    func testImportedCustomChoicePersistsOnlyAfterARealLocalSelection() throws {
        let store = SettingsStore(defaults:defaults)
        store.chooseSearchEngine(.duckduckgo)
        store.importSearchPreferences(engine:"custom",customTemplate:"http://127.0.0.1:12345/find?words=%s")
        XCTAssertTrue(store.searchEngines.contains(.custom))
        XCTAssertEqual(store.customSearchSelection.name,"127.0.0.1")
        store.chooseSearchEngine(.custom)
        store.importSearchPreferences(engine:nil,customTemplate:nil)
        let again = SettingsStore(defaults:defaults)
        XCTAssertEqual(again.searchSelection.engine,.custom)
        XCTAssertEqual(again.searchSelection.url(for:"a+b")?.absoluteString,"http://127.0.0.1:12345/find?words=a%2Bb")
    }

    func testActualSettingsChoiceAndPublicOrPrivateFactoryUseTheSameSelection() throws {
        let store = SettingsStore(defaults:defaults)
        let content = SettingsContent(store:store,context:SettingsContext())
        let row = try XCTUnwrap(content.sections(.search).flatMap(\.rows).first { $0.id == "search.engine.duckduckgo" })
        guard case let .choice(_, choose) = row.kind else { return XCTFail("Search Engine must be a real choice") }
        choose()
        let rows = content.sections(.search).flatMap(\.rows)
        XCTAssertEqual(rows.filter(\.isSelected).map(\.id),[row.id])
        for privateMode in [false,true] {
            let tab = PageFixtures.search("words+more",id:"owned",isPrivate:privateMode,fixturesEnabled:false,selection:store.searchSelection)
            XCTAssertEqual(tab.navigationURL?.absoluteString,"https://duckduckgo.com/?q=words%2Bmore")
            XCTAssertEqual(tab.id,"owned"); XCTAssertEqual(tab.isPrivate,privateMode)
            XCTAssertEqual(tab.site,"DuckDuckGo"); XCTAssertEqual(tab.title,"words+more · DuckDuckGo Search")
        }
        let fixture = PageFixtures.search("words+more",fixturesEnabled:true,selection:store.searchSelection)
        XCTAssertEqual(fixture.site,"Google"); XCTAssertEqual(fixture.addressHost,"google.com")
    }

    func testUnknownSavedProviderRemainsReadableWithoutSilentlyRewritingThePreference() {
        defaults.set("future-provider",forKey:SettingsStore.Key.searchEngine)
        let store = SettingsStore(defaults:defaults)
        XCTAssertEqual(store.searchSelection.engine,.google); XCTAssertNotNil(store.searchSelection.fallbackNote)
        XCTAssertEqual(defaults.string(forKey:SettingsStore.Key.searchEngine),"future-provider")
        store.chooseSearchEngine(.startpage)
        XCTAssertNil(store.searchSelection.fallbackNote)
    }
}
