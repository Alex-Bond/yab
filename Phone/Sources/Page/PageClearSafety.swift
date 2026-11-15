import WebKit

/// Read-only, bounded proof for an already live document. No cold page is loaded.
@MainActor
enum PageClearSafety {
    static func inspect(_ view: WKWebView) async -> Bool {
        guard !view.isLoading, view.cameraCaptureState == .none, view.microphoneCaptureState == .none else { return false }
        return await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(750))
                reply.finish(false)
            }
            // The public callback also catches WebAudio/native playback. Paused
            // media remains protected: a person may intend to continue it.
            view.requestMediaPlaybackState { state in
                guard !reply.finished else { return }
                guard state == .none else { timeout.cancel(); reply.finish(false); return }
                // Read the real DOM through client-world native wrappers. A
                // website cannot hide dirty inputs by replacing its page globals.
                view.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                    timeout.cancel()
                    switch result {
                    case let .success(value): reply.finish((value as? Bool) == true)
                    case .failure: reply.finish(false)
                    }
                }
            }
        }
    }
    private final class Reply {
        private var continuation: CheckedContinuation<Bool, Never>?
        var finished: Bool { continuation == nil }
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) { let reply = continuation; continuation = nil; reply?.resume(returning: value) }
    }
    static let script = """
    (() => {
      if (document.readyState !== 'complete') return false;
      // Frames, canvas, custom elements and rich editors cannot be proven clean
      // by inspecting ordinary HTML form defaults, so preserve them all.
      if (document.querySelector('iframe,frame,audio,video,canvas,[contenteditable]')) return false;
      if ([...document.querySelectorAll('*')].some(e => e.localName.includes('-') || e.shadowRoot)) return false;
      for (const e of document.querySelectorAll('input,textarea,select')) {
        if (e.tagName === 'SELECT') {
          if ([...e.options].some(o => o.selected !== o.defaultSelected)) return false;
        } else if (e.type === 'checkbox' || e.type === 'radio') {
          if (e.checked !== e.defaultChecked) return false;
        } else if (e.type === 'file' || e.type === 'password' || e.value !== e.defaultValue) return false;
      }
      return true;
    })()
    """
}
