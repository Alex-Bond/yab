import AppKit

extension Bench {
    /// A test-only check of the detached host path, through the same agent
    /// primitives. This creates no alternate browser or transport.
    func handleChromiumAgentProbe(_ c: AgentCall) {
        guard Store.testing, c.session == nil,
              let tab = find(c.request, in: c.browser), tab.bench,
              let page = tab.page as? ChromiumPage else {
            c.answer(["error": "The detached input probe requires a Chromium test tab and no agent session"])
            return
        }
        if c.request["probe"] as? String == "capture-race" {
            Task { @MainActor in
                var checks = 0
                var blocked = false
                do {
                    _ = try await AgentImageGate.capture(page, shot: PageShot(width: 64)) {
                        checks += 1
                        let allowed = await AgentSecrets.check(page)
                        if checks == 1 {
                            _ = try? await page.call("document.body.innerHTML='<h1>Recovery phrase</h1><p>SYNTHETIC_WORDS_ONLY</p>'; return true;", in: .agent)
                        }
                        return allowed
                    }
                } catch { blocked = error is AgentSecrets.Refused }
                // The harness restores an ordinary document before the
                // bench's independent reply guard runs. No pixels are sent.
                _ = try? await page.call("document.body.innerHTML='<h1>Ordinary account</h1>'; return true;", in: .agent)
                c.answer(["blocked": blocked, "checks": checks])
            }
            return
        }
        let parent = page.superview
        let rect = page.frame
        page.removeFromSuperview()
        Task { @MainActor in
            defer {
                parent?.addSubview(page)
                page.frame = rect
            }
            do {
                guard page.window == nil else { c.answer(["error": "Probe page was not detached"]); return }
                // Use only synthetic fields, and never submit a form.
                _ = try await page.call("""
                document.body.innerHTML = '<input id=agentProbeField aria-label="Detached input" style="position:absolute;left:20px;top:20px;width:240px;height:40px"><button id=agentProbeButton style="position:absolute;left:20px;top:100px;width:240px;height:40px">Probe button</button>';
                globalThis.__agentProbe = {keys:[], clicks:[], moves:[]};
                addEventListener('keyup', event => __agentProbe.keys.push(event.isTrusted));
                const button = document.getElementById('agentProbeButton');
                const field = document.getElementById('agentProbeField');
                button.addEventListener('click', event => __agentProbe.clicks.push(event.isTrusted));
                button.addEventListener('mousemove', event => __agentProbe.moves.push(event.isTrusted));
                field.focus();
                return true;
                """, in: .agent)
                AgentPage.insert(page, "Ada 日本語")
                _ = AgentPage.press(page, "Backspace")
                let value = try await page.call("return document.getElementById('agentProbeField').value", in: .agent)
                let clicked = AgentPage.click(page, x: 80, y: 120)
                let hovered = AgentPage.hover(page, x: 90, y: 120)
                let dragged = await withCheckedContinuation { continuation in
                    AgentPage.drag(page, from: CGPoint(x: 100, y: 120), to: CGPoint(x: 180, y: 120)) {
                        continuation.resume(returning: $0)
                    }
                }
                let events = try await page.call("return __agentProbe", in: .agent)
                c.answer(["detached": page.window == nil, "value": value ?? NSNull(),
                          "clicked": clicked, "hovered": hovered, "dragged": dragged,
                          "events": events ?? NSNull()])
            } catch { c.answer(["error": error.localizedDescription]) }
        }
    }
}
