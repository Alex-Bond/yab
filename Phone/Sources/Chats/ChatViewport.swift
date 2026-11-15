import SwiftUI
import UIKit

/// The existing sheet rect is the chat's local viewport. Its contents must not
/// inherit an expanded safe-area region from the full-screen ChatsLayer.
struct ChatViewport<Content: View>: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var app
    let owner: Chat.ID
    let content: Content

    init(owner: Chat.ID, @ViewBuilder content: () -> Content) {
        self.owner = owner
        self.content = content()
    }

    func makeUIViewController(context: Context) -> ChatViewportController<Content> {
        ChatViewportController(owner: owner, content: content, environment: context.environment,
                               eligible: eligibility)
    }

    func updateUIViewController(_ controller: ChatViewportController<Content>, context: Context) {
        controller.update(owner: owner, content: content, environment: context.environment,
                          eligible: eligibility)
    }

    static func dismantleUIViewController(_ controller: ChatViewportController<Content>, coordinator: ()) {
        controller.retire()
    }

    private var eligibility: @MainActor (Chat.ID) -> Bool {
        { [weak app] id in
            guard let app else { return false }
            let sheet = app.chatSheet
            return sheet.shown && sheet.chatID == id && !sheet.info
                && !sheet.fresh.contains(id) && sheet.pose.e < 0.001
        }
    }
}

/// One concrete root type remains mounted while the pose, keyboard, appearance
/// or text changes. Every inherited environment value crosses the UIKit boundary.
private struct ChatViewportContent<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    let scrollAccess: ChatScrollAccess

    var body: some View {
        // The explicit inherited environment is outside the local override.
        // Otherwise its whole-value replacement erases the native reader key.
        content.environment(\.chatScrollAccess, scrollAccess).environment(\.self, environment)
    }
}

@MainActor
final class ChatViewportController<Content: View>: UIViewController {
    private var host: UIHostingController<ChatViewportContent<Content>>?
    private let endReader: ChatViewportEndReader

    init(owner: Chat.ID, content: Content, environment: EnvironmentValues,
         eligible: @escaping @MainActor (Chat.ID) -> Bool) {
        let reader = ChatViewportEndReader(owner: owner, eligible: eligible)
        endReader = reader
        host = UIHostingController(rootView: ChatViewportContent(content: content, environment: environment,
                                                               scrollAccess: reader.access))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        let viewport = UIView()
        viewport.backgroundColor = .clear
        viewport.clipsToBounds = true
        view = viewport
        endReader.mount(viewport)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let host else { return }
        // The parent already positions this viewport from SheetGeometry and
        // accounts for the keyboard. A second safe-area expansion is incorrect.
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    func update(owner: Chat.ID, content: Content, environment: EnvironmentValues,
                eligible: @escaping @MainActor (Chat.ID) -> Bool) {
        guard let host else { return }
        endReader.update(owner: owner, eligible: eligible)
        host.rootView = ChatViewportContent(content: content, environment: environment,
                                            scrollAccess: endReader.access)
        if isViewLoaded { view.setNeedsLayout() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        host?.view.frame = view.bounds
        host?.view.layoutIfNeeded()
        endReader.refreshFieldFrames()
    }

    func retire() {
        endReader.retire()
        guard let host else { return }
        host.willMove(toParent: nil)
        host.viewIfLoaded?.removeFromSuperview()
        host.removeFromParent()
        self.host = nil
    }
}

/// An owner-scoped native reading, without a scroll delegate, KVO or offset
/// mutation. Only a marker in the transcript can register its enclosing scroll.
struct ChatScrollAccess: Sendable {
    var atEnd: @MainActor @Sendable (Chat.ID) -> Bool? = { _ in nil }
    var register: @MainActor @Sendable (UUID, Chat.ID, UIScrollView) -> Void = { _, _, _ in }
    var unregister: @MainActor @Sendable (UUID) -> Void = { _ in }
    var registerField: @MainActor @Sendable (UUID, Chat.ID, ChatFieldWindowMarker) -> Void = { _, _, _ in }
    var unregisterField: @MainActor @Sendable (UUID) -> Void = { _ in }
    var fieldFrame: @MainActor @Sendable (UUID) -> CGRect? = { _ in nil }
}

private struct ChatScrollAccessKey: EnvironmentKey {
    static let defaultValue = ChatScrollAccess()
}

extension EnvironmentValues {
    var chatScrollAccess: ChatScrollAccess {
        get { self[ChatScrollAccessKey.self] }
        set { self[ChatScrollAccessKey.self] = newValue }
    }
}

@MainActor
final class ChatViewportEndReader {
    private struct Binding {
        let owner: Chat.ID
        weak var scroll: UIScrollView?
    }
    private struct FieldBinding {
        let owner: Chat.ID
        weak var marker: ChatFieldWindowMarker?
    }

    private weak var viewport: UIView?
    private var owner: Chat.ID
    private var eligible: @MainActor (Chat.ID) -> Bool
    private var bindings: [UUID: Binding] = [:]
    private var fields: [UUID: FieldBinding] = [:]
    private var retired = false

    init(owner: Chat.ID, eligible: @escaping @MainActor (Chat.ID) -> Bool) {
        self.owner = owner
        self.eligible = eligible
    }

    var access: ChatScrollAccess {
        ChatScrollAccess(atEnd: { [weak self] in self?.atEnd($0) },
                         register: { [weak self] in self?.register($0, owner: $1, scroll: $2) },
                         unregister: { [weak self] in self?.bindings[$0] = nil },
                         registerField: { [weak self] token, id, marker in
                             guard let self, !self.retired, self.owner == id else { return }
                             self.fields[token] = FieldBinding(owner: id, marker: marker)
                         },
                         unregisterField: { [weak self] in self?.fields[$0] = nil },
                         fieldFrame: { [weak self] in self?.fieldFrame($0) })
    }

    func mount(_ viewport: UIView) {
        guard !retired else { return }
        self.viewport = viewport
    }

    func update(owner: Chat.ID, eligible: @escaping @MainActor (Chat.ID) -> Bool) {
        guard !retired else { return }
        if self.owner != owner { bindings.removeAll(); fields.removeAll() }
        self.owner = owner
        self.eligible = eligible
    }

    private func register(_ token: UUID, owner: Chat.ID, scroll: UIScrollView) {
        guard !retired, owner == self.owner else { return }
        bindings[token] = Binding(owner: owner, scroll: scroll)
    }

    func atEnd(_ id: Chat.ID) -> Bool? {
        guard !retired, owner == id, eligible(id), let viewport, let window = viewport.window,
              !viewport.isHidden else { return nil }
        bindings = bindings.filter { $0.value.scroll != nil }
        var mounted: [ObjectIdentifier: UIScrollView] = [:]
        for binding in bindings.values {
            guard binding.owner == id, let scroll = binding.scroll,
                  scroll.window === window, scroll.isDescendant(of: viewport), !scroll.isHidden,
                  scroll.bounds.width > 0, scroll.bounds.height > 0 else { continue }
            mounted[ObjectIdentifier(scroll)] = scroll
        }
        guard mounted.count == 1, let scroll = mounted.values.first else { return nil }
        let bottom = scroll.contentSize.height + scroll.adjustedContentInset.bottom
        let visibleBottom = scroll.contentOffset.y + scroll.bounds.height
        guard bottom.isFinite, visibleBottom.isFinite else { return nil }
        return max(0, bottom - visibleBottom) <= 8
    }

    func retire() {
        guard !retired else { return }
        retired = true
        bindings.removeAll()
        fields.removeAll()
        viewport = nil
    }

    func refreshFieldFrames() {
        guard !retired, let viewport, let window = viewport.window else { return }
        fields = fields.filter { $0.value.marker != nil }
        for field in fields.values where field.owner == owner {
            guard let marker = field.marker, marker.window === window, marker.isDescendant(of: viewport) else { continue }
            marker.reportWindowFrame()
        }
    }

    private func fieldFrame(_ token: UUID) -> CGRect? {
        guard !retired, let viewport, let window = viewport.window,
              let requested = fields[token], requested.owner == owner, let marker = requested.marker else { return nil }
        let mounted = fields.values.compactMap { field -> ChatFieldWindowMarker? in
            guard field.owner == owner, let view = field.marker, view.window === window,
                  view.isDescendant(of: viewport), !view.isHidden, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            return view
        }
        guard mounted.count == 1, mounted.first === marker else { return nil }
        let actual = marker.convert(marker.bounds, to: window)
        guard actual.minX.isFinite, actual.minY.isFinite, actual.width.isFinite, actual.height.isFinite else { return nil }
        return actual
    }
}

struct ChatScrollBinding: UIViewRepresentable {
    @Environment(\.chatScrollAccess) private var access
    let owner: Chat.ID

    func makeUIView(context: Context) -> ChatScrollMarker {
        let marker = ChatScrollMarker(frame: .zero)
        marker.configure(owner: owner, access: access)
        return marker
    }

    func updateUIView(_ marker: ChatScrollMarker, context: Context) {
        marker.configure(owner: owner, access: access)
    }

    static func dismantleUIView(_ marker: ChatScrollMarker, coordinator: ()) { marker.retire() }
}

@MainActor
final class ChatScrollMarker: UIView {
    private let token = UUID()
    private var owner: Chat.ID?
    private var access = ChatScrollAccess()
    private var retired = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { return nil }

    func configure(owner: Chat.ID, access: ChatScrollAccess) {
        guard !retired else { return }
        self.access.unregister(token)
        self.owner = owner
        self.access = access
        bind()
    }

    override func didMoveToSuperview() { super.didMoveToSuperview(); bind() }
    override func didMoveToWindow() { super.didMoveToWindow(); bind() }
    override func layoutSubviews() { super.layoutSubviews(); bind() }

    private func bind() {
        guard !retired, let owner, window != nil else { access.unregister(token); return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                access.register(token, owner, scroll)
                return
            }
            ancestor = view.superview
        }
        access.unregister(token)
    }

    func retire() {
        guard !retired else { return }
        access.unregister(token)
        retired = true
        owner = nil
        access = ChatScrollAccess()
    }
}

/// SwiftUI's global coordinates are local to a separate hosting root. FlightWords
/// is in the outer screen tree, so measure this field's real UIKit window rect.
struct ChatFieldWindowFrame: UIViewRepresentable {
    @Environment(AppModel.self) private var app
    @Environment(\.chatScrollAccess) private var access
    let owner: Chat.ID

    func makeUIView(context: Context) -> ChatFieldWindowMarker {
        let marker = ChatFieldWindowMarker(frame: .zero)
        configure(marker)
        return marker
    }

    func updateUIView(_ marker: ChatFieldWindowMarker, context: Context) { configure(marker) }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatFieldWindowMarker, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    private func configure(_ marker: ChatFieldWindowMarker) {
        marker.configure(owner: owner, access: access) { [weak app] id, frame in
            guard let app else { return }
            let sheet = app.chatSheet
            guard sheet.shown, sheet.chatID == id, !sheet.info, sheet.pose.e < 0.001 else { return }
            // ObservationIgnored metadata only. No state publication or layout.
            sheet.fieldFrame = frame
        }
    }

    static func dismantleUIView(_ marker: ChatFieldWindowMarker, coordinator: ()) { marker.retire() }
}

@MainActor
final class ChatFieldWindowMarker: UIView {
    private let token = UUID()
    private var owner: Chat.ID?
    private var access = ChatScrollAccess()
    private var onFrame: (@MainActor (Chat.ID, CGRect) -> Void)?
    private var retired = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { return nil }

    func configure(owner: Chat.ID, access: ChatScrollAccess,
                   onFrame: @escaping @MainActor (Chat.ID, CGRect) -> Void) {
        guard !retired else { return }
        self.access.unregisterField(token)
        self.owner = owner
        self.access = access
        self.onFrame = onFrame
        bind()
    }

    override func didMoveToSuperview() { super.didMoveToSuperview(); bind() }
    override func didMoveToWindow() { super.didMoveToWindow(); bind() }
    override func layoutSubviews() { super.layoutSubviews(); reportWindowFrame() }

    private func bind() {
        guard !retired, let owner, window != nil else { access.unregisterField(token); return }
        access.registerField(token, owner, self)
    }

    func reportWindowFrame() {
        guard !retired, let owner, let actual = access.fieldFrame(token) else { return }
        onFrame?(owner, actual)
    }

    func retire() {
        guard !retired else { return }
        access.unregisterField(token)
        retired = true
        owner = nil
        onFrame = nil
        access = ChatScrollAccess()
    }
}
