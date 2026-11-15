import Foundation

/// An agent's permission to work in a tab never includes extension vaults or
/// recovery material. Chromium keeps this boundary in isolated worlds and
/// authenticates frame origins through the helper, not page-supplied labels.
@MainActor
enum AgentSecrets {
    static let refusal = "This page contains protected recovery material or an extension context. The person must handle it; continue after they leave this page."
    struct Refused: LocalizedError {
        var errorDescription: String? { AgentSecrets.refusal }
    }

    nonisolated static func protected(_ url: URL?) -> Bool {
        guard let url else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["chrome-extension", "webkit-extension", "safari-web-extension", "moz-extension"].contains(scheme) { return true }
        if ["blob", "filesystem"].contains(scheme) {
            // Nested origins are bounded. Unknown or deeply nested wrappers
            // are refused rather than accepted as an ordinary document.
            var raw = url.absoluteString
            for _ in 0..<4 {
                guard let current = URL(string: raw), let prefix = current.scheme?.lowercased() else { return true }
                if ["blob", "filesystem"].contains(prefix) { raw = String(raw.dropFirst(prefix.count + 1)); continue }
                return protected(current)
            }
            return true
        }
        return false
    }

    /// This returns only a boolean. Secret words and field values stay in
    /// the renderer. It deliberately refuses an unreadably large document.
    static let probe = #"""
    (() => {
      const recovery = /\b(?:seed|recovery|backup|secret)\s+(?:phrase|words)|\b(?:mnemonic|private)\s+key/iu;
      // The snapshot visits open shadow roots, so the guard must visit them
      // too. body.innerText and document.querySelectorAll omit their contents.
      const roots = [{ root: document, depth: 0 }];
      let rootCount = 0, elementCount = 0, wordCount = 0;
      while (roots.length) {
        const { root, depth } = roots.pop();
        if (++rootCount > 256 || depth >= 32) return true;
        const words = root === document ? (document.body?.innerText || '')
          : Array.from(root.childNodes, node => node.nodeType === 3 ? node.textContent
              : /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(node.nodeName) ? '' : node.innerText || '').join('\n');
        wordCount += words.length;
        if (wordCount > 500000 || recovery.test(document.title + '\n' + words)) return true;
        const elements = root.querySelectorAll('*');
        elementCount += elements.length;
        if (elementCount > 50000) return true;
        for (const field of elements) {
          if (field.shadowRoot) roots.push({ root: field.shadowRoot, depth: depth + 1 });
          if (!field.matches('input,textarea,[contenteditable]')) continue;
          const hints = ['name', 'id', 'placeholder', 'aria-label', 'autocomplete'].map(key => field.getAttribute(key) || '').join(' ')
            + ' ' + Array.from(field.labels || [], label => label.textContent).join(' ');
          if (recovery.test(hints.replace(/[_-]+/g, ' '))) return true;
          const value = field.value || (field.isContentEditable ? field.textContent : '') || '';
          if (/-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----|\b(?:0x)?[a-f0-9]{64}\b/iu.test(value)) return true;
        }
      }
      return false;
    })()
    """#

    static var guardBody: String {
        "if (\(probe)) throw new Error(\(String(reflecting: refusal)));\n"
    }

    /// Why the last check refused, for the helper's log; never page words.
    private static func refuse(_ why: String) -> Bool {
        FileHandle.standardError.write(Data("yab: agent guard refused: \(why)\n".utf8))
        return false
    }

    /// A browser-native question can suspend every renderer request. This
    /// response contains no page-supplied words or tool result. It is not a
    /// successful guard: only a fresh check after the person answers may
    /// release page data, including the question's own message.
    static func nativeQuestionReply(_ tabs: [Tab]) -> [String: Any]? {
        guard tabs.contains(where: { $0.engineKind == .chromium && $0.asks.contains(where: \.fromPage) }) else { return nil }
        return ["error": "The page is waiting for the person to answer its question in Yab. Continue after they answer.",
                "needs_user": true, "code": "NATIVE_PAGE_QUESTION"]
    }

    static func check(_ page: any PageHandle) async -> Bool {
        // WebKit's existing behavior is unchanged by this opt-in migration.
        guard let page = page as? ChromiumPage else { return true }
        guard !protected(page.url) else { return refuse("protected address scheme") }
        var step = "frames"
        let started = Date()
        do {
            let frames = try await page.agentFrames()
            var tokens = Set<String>()
            for frame in frames {
                guard !protected(frame.url),
                      !protected(URL(string: frame.origin.scheme + "://" + frame.origin.host)) else { return refuse("protected frame address") }
                guard let token = try page.scripts.token(frame, tab: page.remoteID) else { return refuse("frame without a script context") }
                tokens.insert(token)
                step = "probe"
                let result = try await page.call("return " + probe, in: .agent, frame: frame, gesture: false)
                guard result as? Bool == false else { return refuse("probe in frame gave \(String(describing: result))") }
            }
            // A navigation or renderer/frame replacement during the probe is
            // not the same authorization. Never cache a successful check.
            step = "recheck"
            let current = try await page.agentFrames()
            let currentTokens = try Set(current.compactMap { try page.scripts.token($0, tab: page.remoteID) })
            guard currentTokens == tokens && current.count == tokens.count && !protected(page.url) else { return refuse("frames changed during the check") }
            return true
        } catch { return refuse("\(step) failed after \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(error)") }
    }
}
