import WebKit

extension PageColor {
    init?(_ color: NSColor?) {
        guard let color = color?.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(color.redComponent), green: Double(color.greenComponent),
                  blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
    }
}

extension PageView {
    var stateEvents: (any PageStateEvents)? {
        get { stateObservation.listener }
        set { stateObservation.listen(newValue, on: self) }
    }
}

/// KVO belongs to this engine alone. The tab receives copied values and
/// keeps its state listener when the page moves between browser windows.
@MainActor
final class WebKitPageState {
    weak var listener: (any PageStateEvents)?
    private var watch: [NSKeyValueObservation] = []
    private var screenWatch: KeyWatch?

    func listen(_ listener: (any PageStateEvents)?, on page: PageView) {
        watch = []
        screenWatch = nil
        self.listener = listener
        guard listener != nil else { return }
        watch = [
            page.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .fullscreen(page.fullscreenState != .notInFullscreen)) }
            },
            page.observe(\.title, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .title(page.title)) }
            },
            page.observe(\.url, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .url(page.url)) }
            },
            page.observe(\.isLoading, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .loading(page.isLoading)) }
            },
            page.observe(\.canGoBack, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .back(page.canGoBack)) }
            },
            page.observe(\.canGoForward, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .forward(page.canGoForward)) }
            },
            page.observe(\.themeColor, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .theme(PageColor(page.themeColor))) }
            },
            page.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .underPage(PageColor(page.underPageBackgroundColor))) }
            },
            page.observe(\.cameraCaptureState, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .camera(PageMediaState(page.cameraCaptureState))) }
            },
            page.observe(\.microphoneCaptureState, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.emit(page, .microphone(PageMediaState(page.microphoneCaptureState))) }
            },
        ]
        screenWatch = KeyWatch(page, Tab.screenKey) { [weak self, weak page] in
            MainActor.assumeIsolated {
                if let page { self?.emit(page, .screen(PageMediaState(Tab.screenState(of: page)))) }
            }
        }
    }

    private func emit(_ page: PageView, _ state: PageStateChange) {
        listener?.page(page, changed: state)
    }
}
