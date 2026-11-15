import SwiftUI
import UIKit

/// The tasks' surfaces over everything but settings and the toast: a
/// task's chat (Surfaces.chat == .task), the code and the yes with Face ID,
/// and, in pictures only, the Island and the Lock Screen. RootView places it
/// right over ChatsLayer. Chats opened in the tray keep their own task turns;
/// a task opened from Now or the Island uses its origin here.
struct TasksLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let desk = app.taskDesk
        ZStack {
            if case let .task(id)? = app.surfaces.chat, !app.chatSheet.shown,
               app.isFixture || app.sync.visibleLiveTask(id) != nil {
                TaskChatLayer(id: id)
            }
            if let sheet = desk.sheet {
                PersonSheetLayer(sheet: sheet)
            }
            if let face = desk.faceID {
                FaceIDPanel(state: face)
                    .transition(.opacity.combined(with: .scale(scale: Metrics.FaceIDPanel.fromScale)))
            }
        }
        .ignoresSafeArea()
        .onChange(of: desk.outside) { _, scene in OutsideWindow.show(scene, app: app) }
        .onAppear { OutsideWindow.show(desk.outside, app: app) }
    }
}

// MARK: - a task's chat

/// A task's chat at full height: grown out of the Now line (0.38 s) or the
/// Island (0.36 s), folded back into the line by a swipe down (0.3 s). The
/// page steps back behind it.
struct TaskChatLayer: View {
    @Environment(AppModel.self) private var app
    let id: TaskRun.ID
    @State private var keyboard = KeyboardWatch.shared

    var body: some View {
        GeometryReader { geo in
            let desk = app.taskDesk
            let screen = geo.size
            let fold = desk.chatFold
            let pull = max(0, desk.chatPull)
            let top = app.isFixture ? Metrics.TaskChat.top : 0
            let full = CGRect(x: 0, y: top, width: screen.width,
                              height: max(0, screen.height - top - keyboard.height))
            let origin = desk.chatOrigin.rect ?? full
            ZStack(alignment: .topLeading) {
                // The page behind: darker as the sheet stands up.
                Color.black
                    .opacity(scrim(fold: fold, pull: pull, height: full.height))
                    .contentShape(Rectangle())
                    .onTapGesture { desk.foldChat() }
                    .accessibilityHidden(true)
                Group {
                    if app.isFixture { TaskChatSheet(id: id, size: full.size) }
                    else { LiveTaskChatSheet(id: id, size: full.size) }
                }
                    .modifier(SheetMorph(fold: fold, pull: pull, origin: origin, originRadius: desk.chatOrigin.radius,
                                         target: full, radius: app.isFixture ? Metrics.Sheet.radius : Metrics.Chats.trayFullRadius,
                                         screen: screen, page: !app.isFixture))
                    .gesture(foldGesture(desk))
                    // VoiceOver stays in the chat, and the two-finger scrub
                    // folds it into the Now line as the swipe down does.
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { desk.foldChat() }
                if case let .chat(chat)? = app.surfaces.menu {
                    // ⋯ in the task's head: the chats' menu for its chat, where a chat's stands.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { Motion.menuClose.run { app.surfaces.closeMenu() } }
                        .accessibilityHidden(true)
                    ChatMoreMenu(chat: chat)
                        .transition(.scale(scale: 0.4, anchor: UnitPoint(x: 1 - Metrics.Chat.menuAnchorRight / Metrics.Menu.Chat.width,
                                                                          y: -Metrics.Chat.menuAnchorAbove / Metrics.Chat.menuHeight))
                            .combined(with: .opacity))
                        .offset(x: screen.width - Metrics.Edge.bar - Metrics.Menu.Chat.width, y: Metrics.statusBar + Metrics.Chat.menuTop)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .onDisappear { app.taskDesk.restorePageAfterChat() }
        }
        .ignoresSafeArea()
    }

    private func scrim(fold: CGFloat, pull: CGFloat, height: CGFloat) -> Double {
        let t = Double(max(0, 1 - fold - pull / max(height, 1)))
        return (Metrics.TaskChat.scrimFrom + (Metrics.TaskChat.scrimTo - Metrics.TaskChat.scrimFrom) * t) * t
    }

    /// Down past 90 points or faster than 600 a second folds it into the
    /// Now line, as the chats' sheet hides; short of that it springs back.
    private func foldGesture(_ desk: TaskDesk) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard value.translation.height > abs(value.translation.width) || desk.chatPull > 0 else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { desk.chatPull = max(0, value.translation.height) }
            }
            .onEnded { value in
                let dy = value.translation.height
                let vy = value.velocity.height
                if dy > Metrics.TaskChat.foldDistance || vy > Metrics.TaskChat.foldVelocity {
                    desk.foldChat(velocity: vy)
                } else {
                    TaskMotion.run(.chatUnfold) { desk.chatPull = 0 }
                }
            }
    }
}

/// The sheet between its origin (fold 1: the Now line's or the Island's
/// rect) and its place (fold 0), the prototype's aiP: the words fade first
/// (1 - 2.4 p), the white thins past .6, the sheet goes from .55 while the
/// line under it shows, so no frame is empty.
struct SheetMorph: ViewModifier, Animatable {
    var fold: CGFloat
    var pull: CGFloat
    let origin: CGRect
    let originRadius: CGFloat
    let target: CGRect
    let radius: CGFloat
    let screen: CGSize
    var page = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(fold, pull) }
        set {
            fold = newValue.first
            pull = newValue.second
        }
    }

    func body(content: Content) -> some View {
        // Reduce Motion: no morph, the same meaning in a short cross-fade.
        let reduced = Motion.reduced
        let p = reduced ? 0 : min(max(fold, 0), 1)
        let place = target.offsetBy(dx: 0, dy: pull)
        let rect = CGRect(x: place.minX + (origin.minX - place.minX) * p, y: place.minY + (origin.minY - place.minY) * p,
                          width: place.width + (origin.width - place.width) * p, height: place.height + (origin.height - place.height) * p)
        let top = radius + (originRadius - radius) * p
        let bottom = originRadius * p
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                           topTrailingRadius: top, style: .continuous)
        let words = max(0, 1 - 2.4 * p)
        let white = p > 0.6 ? 0.97 - (0.97 - 0.78) * (p - 0.6) / 0.4 : 0.97
        let sheet = p > 0.55 ? max(0, 1 - (p - 0.55) / 0.45) : 1
        ZStack(alignment: .topLeading) {
            shape
                .fill((page ? ChatInk.list : Ink.surface).opacity(white))
                .background(.regularMaterial, in: shape)
                .shadow(color: Ink.shadow.opacity(0.16), radius: 20, y: -10)
                .overlay(shape.strokeBorder(Ink.outline.opacity(0.06), lineWidth: 0.5))
                .frame(width: rect.width, height: rect.height)
                // The sheet's own frame, for tests to check where it stands.
                .accessibilityElement()
                .accessibilityIdentifier("task.chat.sheet")
                .accessibilityLabel("Task")
                .position(x: rect.midX, y: rect.midY)
            content
                .frame(width: place.width, height: place.height)
                .position(x: place.midX, y: place.midY)
                .opacity(words)
                .mask {
                    shape.frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                }
        }
        .frame(width: screen.width, height: screen.height)
        .opacity(reduced ? Double(1 - min(max(fold, 0), 1)) : sheet)
    }
}

/// The chat itself: grabber, head (history, who, ⋯), the turns, the field.
struct TaskChatSheet: View {
    @Environment(AppModel.self) private var app
    let id: TaskRun.ID
    let size: CGSize
    @State private var words = ""
    @FocusState private var typing: Bool

    private typealias M = Metrics.TaskChat

    var body: some View {
        let tasks = app.tasks
        let run = tasks.run(id)
        let def = tasks.definition(id)
        VStack(spacing: 0) {
            Capsule()
                .fill(TaskInk.grabber)
                .frame(width: Metrics.Column.grabWidth, height: Metrics.Column.grabHeight)
                .padding(.top, M.grabTop)
            head(def: def, run: run)
                .padding(.top, M.headTop - M.grabTop - Metrics.Column.grabHeight)
            ScrollView {
                if let def, let run {
                    TaskTurns(run: run, def: def, failure: app.taskDesk.failures[id]?.long ?? run.failure,
                              waiting: app.taskDesk.yeses[id]?.waiting, codeSender: app.taskDesk.codes[id]?.sender,
                              asleepSince: run.asleepSince ?? app.taskDesk.macAsleepSince) {
                        app.taskDesk.retry(id)
                    }
                    .padding(.horizontal, M.bodySide)
                    .padding(.top, M.bodyTop)
                    .padding(.bottom, M.bodyBottom)
                }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .accessibilityIdentifier("task.chat.body")
            field(run: run)
                .padding(.horizontal, M.fieldSide)
                .padding(.bottom, M.fieldBottom)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.chat")
    }

    private func head(def: TaskDefinition?, run: TaskRun?) -> some View {
        ZStack(alignment: .top) {
            HStack {
                RoundSheetButton(glyph: .history, size: 21, id: "task.chat.history", label: "Your Chats") {
                    app.surfaces.closeChat()
                    app.openChats()
                }
                Spacer()
                RoundSheetButton(glyph: .dotGrid1x3Horizontal, size: 22, id: "task.chat.more", label: "More") {
                    let chat = app.chats.chats.first { $0.task == id }?.id ?? id
                    TaskMotion.run(.chatMenu) { app.surfaces.openMenu(.chat(chat)) }
                }
            }
            .padding(.horizontal, M.roundInset)
            .padding(.top, M.roundTop)
            VStack(spacing: M.whoGap) {
                AgentFace(size: M.faceGlyph)
                    .frame(width: M.face, height: M.face)
                    .background(TaskInk.box, in: Circle())
                Text(def?.name ?? "Task")
                    .font(.system(size: M.title, weight: .semibold))
                    .tracking(-0.01 * M.title)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .frame(height: M.title * 1.15)
                Text(Self.line(run?.status, provider: app.chats.chats.first { $0.task == id }?.macAgentName,
                               fixturesEnabled: app.isFixture))
                    .font(.system(size: M.line))
                    .tracking(-0.01 * M.line)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .frame(height: M.line * 1.1)
            }
            .padding(.top, M.whoTop)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("task.chat.who")
        }
        .frame(height: M.head, alignment: .top)
        .contentShape(Rectangle())
    }

    /// Under the name: working, waiting for you, or done on the Mac.
    static func line(_ status: TaskStatus?, provider: String? = nil, fixturesEnabled: Bool = true) -> String {
        switch status {
        case .running?, .sending?: return "Working · on your Mac"
        case .code?, .yes?: return "Waiting for you"
        case .waits?: return "Waits for your Mac"
        default:
            if fixturesEnabled { return "On your Mac · Claude" }
            return provider.map { "On your Mac · \($0)" } ?? "On your Mac"
        }
    }

    private func field(run: TaskRun?) -> some View {
        let live = run?.status == .running || run?.status == .sending
        let has = !words.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 8) {
            TextField("", text: $words, prompt: Text(live ? "Tell it more while it works…" : "Ask a follow-up…")
                .foregroundStyle(Ink.faint))
                .font(.system(size: M.fieldFont))
                .tracking(-0.01 * M.fieldFont)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(send)
                .accessibilityIdentifier("task.chat.field")
            Button(action: send) {
                Group {
                    if has { Glyph(.arrowUp, size: 18, color: .white) } else { Glyph(.microphone, size: M.mic, color: Ink.tertiary) }
                }
                .frame(width: M.send, height: M.send)
                .background(has ? TaskInk.ink : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(has ? "Send" : "Dictate")
        }
        .padding(.leading, M.fieldLeading)
        .padding(.trailing, M.fieldTrailing)
        .frame(height: M.field)
        .background(Ink.card.opacity(M.fieldWhite), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Ink.outline.opacity(M.fieldStroke), lineWidth: M.hairline))
        .shadow(color: Ink.shadow.opacity(M.fieldShadow), radius: M.fieldShadowRadius, y: M.fieldShadowY)
    }

    private func send() {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        words = ""
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        app.taskDesk.tell(id, text)
    }
}

// MARK: - the keyboard

/// Where the system keyboard stands: the root ignores the keyboard's safe
/// area, so the task's sheets ride on it themselves.
@MainActor
@Observable
final class KeyboardWatch {
    static let shared = KeyboardWatch()
    /// From the screen's bottom to the keyboard's top; 0 when it's down.
    private(set) var height: CGFloat = 0

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let height = max(0, TaskDesk.screen.height - frame.minY)
                guard abs(height - self.height) > 0.5 else { return }
                (height > self.height ? Motion.keyboardUp : Motion.keyboardDown).run { self.height = height }
            }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.height > 0 else { return }
                Motion.keyboardDown.run { self.height = 0 }
            }
        }
    }
}

// MARK: - text the way the prototype sets it

extension View {
    /// CSS's line-height on SwiftUI text: the extra between lines, and half
    /// of it over the first and under the last, as a browser centers lines.
    func lineHeight(_ multiple: CGFloat, size: CGFloat) -> some View {
        let natural = UIFont.systemFont(ofSize: size).lineHeight
        let extra = max(0, size * multiple - natural)
        return self.lineSpacing(extra).padding(.vertical, extra / 2)
    }
}
