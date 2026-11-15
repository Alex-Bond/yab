import SwiftUI
import UIKit
#if canImport(SyncKit)
import SyncKit
#endif

/// What a turn did on the Mac, drawn as the Mac's chat draws it
/// (ChatTranscript): why it couldn't finish, its thoughts folded, its
/// subagents at work and their reports. Its steps are never shown.
struct TurnWorkView: View {
    @Environment(AppModel.self) private var app
    let work: TurnWork
    let chat: Chat
    /// Out of sight, for measuring: nothing can be pressed, no clock runs.
    var still = false

    var body: some View {
        rows.padding(.leading, inset)
    }

    /// As on the Mac: rows stand on the line the bubbles' words start on,
    /// cards on the bubbles' own edge, past the tail's room.
    private var inset: CGFloat {
        switch work.kind {
        case .subagents, .report: Metrics.Chat.tailRoom
        default: Metrics.Chat.tailRoom + Metrics.Chat.bubblePadding.leading
        }
    }

    @ViewBuilder private var rows: some View {
        switch work.kind {
        case .actions:
            // An answer's: Copy and Ask Again are in its held menu (MessageHold).
            EmptyView()
        case .worked:
            // A turn's steps are never shown (an old message's kind).
            EmptyView()
        case .failure:
            WorkFailure(work: work, still: still) { ask($0) }
        case .thought:
            ThoughtFold(work: work)
        case .subagents:
            VStack(alignment: .leading, spacing: Metrics.Work.markGap) {
                ForEach(work.subagents, id: \.id) { SubagentCard(subagent: $0, still: still) }
            }
        case .report:
            ReportCard(work: work)
        }
    }

    /// Ask Again and Try Again: the turn's words sent again, as typed.
    private func ask(_ question: String) {
        guard !still, app.chatSheet.chatID == chat.id else { return }
        app.send(question)
    }
}

/// Where a turn's folds stand: closed, unless a named state opened one
/// before its chat came (keyed by TurnWork.id).
@MainActor
enum TurnWorkFolds {
    static var open: Set<String> = []
}

/// A small quiet capsule button: Show All, Show Report, Try Again.
private struct WorkPill: View {
    let title: String
    var id: String?
    let action: () -> Void

    init(_ title: String, id: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.id = id
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Metrics.Work.lineFont, weight: .medium))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(ChatInk.fill(0.12), in: Capsule())
                .frame(minHeight: Metrics.Work.actionTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier(id ?? "chat.work.pill")
    }
}

// MARK: - couldn't finish

/// A turn that couldn't finish: the fail mark, the cause, what to do, and
/// Try Again, the turn's question sent again (the Mac's ChatFailure).
private struct WorkFailure: View {
    let work: TurnWork
    let still: Bool
    let ask: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.Work.markGap) {
            StepMark(art: .fail, tint: Ink.close)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(work.title)
                    .font(.system(size: Metrics.Work.failureTitle, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(work.detail)
                    .font(.system(size: Metrics.Work.failureDetail))
                    .foregroundStyle(ChatInk.gray(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                if let question = work.question, !still {
                    WorkPill("Try Again", id: "chat.work.retry") {
                        Haptics.play(.light, reason: Haptics.Reason.confirm)
                        ask(question)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.work.failure")
    }
}

// MARK: - thoughts

/// Its thoughts, folded: "Thought for 12s", their words when opened (the
/// Mac's ChatThought).
private struct ThoughtFold: View {
    let work: TurnWork
    @State private var open: Bool

    init(work: TurnWork) {
        self.work = work
        _open = State(initialValue: TurnWorkFolds.open.contains(work.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let line = HStack(spacing: 6) {
                Text(work.words)
                if !work.text.isEmpty {
                    Glyph(.chevronRight, size: Metrics.Work.chevron, color: ChatInk.gray(0.6))
                }
            }
            .font(.system(size: Metrics.Work.thoughtFont))
            .foregroundStyle(ChatInk.gray(0.6))
            .frame(minHeight: Metrics.Work.actionRow)
            .contentShape(Rectangle())
            if work.text.isEmpty {
                line
            } else {
                Button { Motion.workFold.run { open.toggle() } } label: { line }
                    .buttonStyle(.plain)
                    .accessibilityValue(open ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows its thinking")
            }
            if open, !work.text.isEmpty {
                Text(work.text)
                    .font(.system(size: Metrics.Work.failureDetail))
                    .foregroundStyle(ChatInk.gray(0.6))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
        .accessibilityIdentifier("chat.work.thought")
    }
}

// MARK: - subagents

/// A subagent at work under its turn: its face, what it was asked to do,
/// "Working", and how long it has been at it (the Mac's ChatSubagentCard).
private struct SubagentCard: View {
    let subagent: TurnWork.Subagent
    let still: Bool

    var body: some View {
        WorkPlate {
            HStack(spacing: Metrics.Work.markGap) {
                AgentFace(size: Metrics.Work.face, color: Ink.primary.opacity(0.8), lineWidth: 1.8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subagent.name)
                        .font(.system(size: Metrics.Work.nameFont, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    Text("Working")
                        .font(.system(size: Metrics.Work.nameFont))
                        .foregroundStyle(ChatInk.gray(0.6))
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 8)
                if let since = subagent.since {
                    if still || Motion.disabled {
                        clock(Date().timeIntervalSince(since))
                    } else {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            clock(context.date.timeIntervalSince(since))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.work.subagent")
    }

    private func clock(_ seconds: TimeInterval) -> some View {
        let whole = max(0, Int(seconds))
        return Text(String(format: "%d:%02d", whole / 60, whole % 60))
            .font(.system(size: Metrics.Work.lineFont))
            .foregroundStyle(ChatInk.gray(0.6))
            .monospacedDigit()
    }
}

/// A subagent's report handed to its task: its face, its name, the first
/// line of what it found, and the rest a tap away.
private struct ReportCard: View {
    let work: TurnWork
    @State private var open = false

    var body: some View {
        WorkPlate {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: Metrics.Work.markGap) {
                    AgentFace(size: Metrics.Work.face, color: Ink.primary.opacity(0.8), lineWidth: 1.8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(work.title)
                            .font(.system(size: Metrics.Work.nameFont, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        Text(work.detail)
                            .font(.system(size: Metrics.Work.nameFont))
                            .foregroundStyle(ChatInk.gray(0.6))
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if !work.text.isEmpty {
                        WorkPill(open ? "Hide" : "Show Report", id: "chat.work.report") { Motion.workFold.run { open.toggle() } }
                    }
                }
                if open {
                    Text(work.text)
                        .font(.system(size: Metrics.Work.failureDetail))
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.leading, Metrics.Work.face + Metrics.Work.markGap)
                        .transition(.opacity)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.work.reportCard")
    }
}

/// A subagent's plate: as wide as a bubble, ink at 0.07, a bubble's curve.
private struct WorkPlate<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(Metrics.Work.plateInset)
            .frame(maxWidth: Metrics.Chat.bubbleMaxWidth, alignment: .leading)
            .background(Ink.primary.opacity(Metrics.Work.plateInk),
                        in: RoundedRectangle(cornerRadius: Metrics.Work.plateRadius, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
