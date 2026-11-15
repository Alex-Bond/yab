import Foundation
import Testing
import WebKit
@testable import Fast

// The call window on Zoom's web client: CallStage read over pages saved
// from a live call on 2026-10-13 (evals/calls/zoom/snapshots, names made
// up: Ann Host is you, Test Guest the other). A changed Zoom client shows
// here first, by which state lost which control.
@MainActor
struct CallStageZoomTests {
    static let snapshots = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("evals/calls/zoom/snapshots")

    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// A saved state, at Zoom's own address so the script knows the client.
    static func page(_ state: String) async throws -> WKWebView {
        let html = try String(contentsOf: snapshots.appendingPathComponent(state + ".html"), encoding: .utf8)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { go in
            loaded.done = go
            web.loadHTMLString(html, baseURL: URL(string: "https://app.zoom.us/wc/81234567890/start"))
        }
        _ = loaded
        return web
    }

    static func ask(_ web: WKWebView, _ verb: String) async throws -> Any? {
        try await web.callAsyncJavaScript(CallStage.source + "\nreturn await window.__yabCall[verb]();",
                                          arguments: ["verb": verb], in: nil, contentWorld: CallStage.world)
    }

    static func people(_ state: String) async throws -> [[String: Any]] {
        let web = try await page(state)
        return try #require(try await ask(web, "who") as? [[String: Any]])
    }

    static func person(_ all: [[String: Any]], _ name: String) -> [String: Any]? {
        all.first { $0["name"] as? String == name }
    }

    /// The participants list says who you are, who is muted and whose hand is up.
    @Test func participantsList() async throws {
        let all = try await Self.people("participants-panel")
        let me = try #require(Self.person(all, "Ann Host"))
        let guest = try #require(Self.person(all, "Test Guest"))
        #expect(me["self"] as? Bool == true && guest["self"] as? Bool == false)
        #expect(guest["muted"] as? Bool == true)
        #expect(guest["hand"] as? Bool == true)
        #expect(me["hand"] as? Bool == false)
    }

    /// Without the list, a tile still shows a muted mark and a hand.
    @Test func tilesAlone() async throws {
        let all = try await Self.people("guest-hand-muted-chat-tip")
        let guest = try #require(Self.person(all, "Test Guest"))
        #expect(guest["muted"] as? Bool == true)
        #expect(guest["hand"] as? Bool == true)
    }

    /// The chat as Zoom lists it: the guest's line, not yours.
    @Test func chat() async throws {
        let web = try await Self.page("chat-open")
        let heard = try #require(try await Self.ask(web, "heard") as? [String: Any])
        let messages = try #require(heard["messages"] as? [[String: Any]])
        let line = try #require(messages.first { $0["text"] as? String == "Hello from the test guest" })
        #expect(line["from"] as? String == "Test Guest")
        #expect(line["own"] as? Bool == false)
    }

    /// Every control the window presses is found in the call's own bar.
    @Test func controls() async throws {
        let web = try await Self.page("me-muted")
        let heard = try #require(try await Self.ask(web, "heard") as? [String: Any])
        #expect(heard["leave"] as? Bool == true)
        #expect(heard["share"] as? Bool == true)
        #expect(heard["canChat"] as? Bool == true)
        #expect(heard["canReact"] as? Bool == true)
        #expect(heard["canHand"] as? Bool == true)
    }

    /// Zoom hides its bar while nobody moves over the page, as in the call
    /// window: its buttons are still found and pressed.
    @Test func hiddenBar() async throws {
        let web = try await Self.page("me-muted")
        _ = try await web.callAsyncJavaScript("""
            document.querySelectorAll('.footer-button-base__button').forEach(function (b) { b.style.visibility = 'hidden'; });
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        let heard = try #require(try await Self.ask(web, "heard") as? [String: Any])
        #expect(heard["leave"] as? Bool == true)
        #expect(heard["canHand"] as? Bool == true)
        #expect(heard["canChat"] as? Bool == true)
    }

    /// A guest's Leave: Zoom's button says "Leave" and asks again in a
    /// popover, whose "Leave Meeting" is what's pressed next, not the
    /// button itself a second time (that only closed the popover).
    @Test func guestLeaves() async throws {
        let web = try await Self.page("me-muted")
        _ = try await web.callAsyncJavaScript("""
            const end = [...document.querySelectorAll('button[aria-label]')].find(b => /^(leave|end)$/i.test(b.getAttribute('aria-label')));
            end.setAttribute('aria-label', 'Leave'); end.textContent = 'Leave';
            end.addEventListener('click', () => {
              const old = document.querySelector('#popover');
              if (old) { old.remove(); return; }
              const pop = document.createElement('div'); pop.id = 'popover';
              const b = document.createElement('button'); b.textContent = 'Leave Meeting';
              b.addEventListener('click', () => { window.left = true; pop.remove(); });
              pop.appendChild(b); document.body.appendChild(pop);
            });
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        _ = try await Self.ask(web, "leave")
        let left = try await web.callAsyncJavaScript("return window.left === true;", arguments: [:], in: nil, contentWorld: .page)
        #expect(left as? Bool == true)
    }

    /// Someone in Zoom's waiting room, as its notice says it to a host or
    /// co-host (live 2026-10-14): read by name, let in by its Admit.
    @Test func waitingRoom() async throws {
        let web = try await Self.page("me-muted")
        _ = try await web.callAsyncJavaScript("""
            const box = document.createElement('div'); box.setAttribute('role', 'alert');
            box.innerHTML = '<span>Judge entered the waiting room</span><button>View waiting room list</button><button>Admit</button>';
            box.querySelectorAll('button')[1].addEventListener('click', () => { window.admitted = true; box.remove(); });
            document.body.appendChild(box);
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        let news = try #require(try await web.callAsyncJavaScript(CallStage.source + "\nreturn window.__yabCall.news();",
                                                                  arguments: [:], in: nil, contentWorld: CallStage.world) as? [String: Any])
        let waiting = try #require(news["waiting"] as? [[String: Any]])
        #expect(waiting.first?["name"] as? String == "Judge")
        _ = try await web.callAsyncJavaScript(CallStage.source + "\nreturn window.__yabCall.admit('Judge');",
                                              arguments: [:], in: nil, contentWorld: CallStage.world)
        let admitted = try await web.callAsyncJavaScript("return window.admitted === true;", arguments: [:], in: nil, contentWorld: .page)
        #expect(admitted as? Bool == true)
    }
}
