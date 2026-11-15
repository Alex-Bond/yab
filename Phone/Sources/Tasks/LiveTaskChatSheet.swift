import SwiftUI

/// A real retained request and checked result use conversation bubbles,
/// intrinsic Markdown and a measured full-page header with their own authority.
struct LiveTaskChatSheet: View {
    @Environment(AppModel.self) private var app
    let id: String
    let size: CGSize
    @State private var headerHeight = Metrics.Chats.trayFullHeaderTop + Metrics.Chats.conversationHeader
    @ScaledMetric(relativeTo: .headline) private var titleSize = Metrics.Chats.nameFont
    @ScaledMetric(relativeTo: .subheadline) private var progressSize = Metrics.Chats.nameLineFont
    #if DEBUG
    /// Nil in ordinary production composition. Tests observe laid-out native
    /// geometry rather than assigning frames or changing routes.
    var onLayout: ((String, CGRect) -> Void)? = nil
    #endif

    var body: some View {
        if let snapshot = app.sync.visibleLiveTask(id) {
            let authority = LiveTaskChatAuthority(app: app, snapshot: snapshot)
            ZStack(alignment: .top) {
                ChatInk.list
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Spacer(minLength: 0)
                            QuestionBubble(text: snapshot.request.words)
                                .accessibilityIdentifier("task.live.request")
                                .taskLayout("request", report: report)
                        }
                        if let result = snapshot.result, !result.isEmpty {
                            ChatMarkdownContent(text: result)
                                .accessibilityIdentifier("task.live.result")
                                .taskLayout("result", report: report)
                        }
                        if let address = snapshot.resultURL, let url = URL(string: address) {
                            Link(address, destination: url)
                                .font(.footnote).lineLimit(3)
                                .frame(minHeight: Metrics.Chats.headerButton, alignment: .leading)
                                .accessibilityIdentifier("task.live.result-url")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.TaskChat.bodySide)
                    .padding(.top, headerHeight + 12)
                    .padding(.bottom, Metrics.TaskChat.bodyBottom + Metrics.Chats.scrollFootFade)
                }
                .scrollIndicators(.hidden)
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { authority.open($0) })
                .accessibilityIdentifier("task.live.body")
                .taskLayout("body", report: report)
                // Keep actual result ink out of the measured title/progress/Mac
                // header. The shared veil only fades the following 20pt tail.
                VStack(spacing: 0) {
                    ChatInk.list.frame(height: headerHeight)
                    ChatScrollVeil().frame(height: 20)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                head(snapshot, authority: authority)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(headerHeight - height) > 0.5 { headerHeight = height }
                    }
                VStack {
                    Spacer(minLength: 0)
                    ChatScrollVeil(from: .bottom, to: .top).frame(height: Metrics.Chats.scrollFootFade)
                }
                .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("task.live.chat")
            .taskLayout("page", report: report)
        }
    }

    private func head(_ snapshot: LiveTaskSnapshot, authority: LiveTaskChatAuthority) -> some View {
        HStack(alignment: .top, spacing: Metrics.Chats.headerGap) {
            Glyph(.macbook, size: Metrics.Chats.faceInk)
                .frame(width: Metrics.Chats.face, height: Metrics.Chats.face)
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task.live.title")
                    .taskLayout("title", report: report)
                Text(snapshot.progress)
                    .font(.system(size: progressSize))
                    .foregroundStyle(Ink.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task.live.progress")
                    .taskLayout("progress", report: report)
                if let mac = app.sync.macs.first(where: { $0.id == snapshot.request.mac }) {
                    Text(mac.name).font(.caption2).foregroundStyle(Ink.tertiary).lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("task.live.mac")
                        .taskLayout("mac", report: report)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RoundSheetButton(glyph: .crossSmall, id: "task.live.close", label: "Close task") {
                authority.close()
            }
            .taskLayout("close", report: report)
        }
        .padding(.horizontal, Metrics.Chats.trayHeaderInset)
        .padding(.top, Metrics.Chats.trayFullHeaderTop + Metrics.Chats.trayButtonInset)
        .padding(.bottom, 12)
        .frame(minHeight: Metrics.Chats.trayFullHeaderTop + Metrics.Chats.conversationHeader, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.live.header")
        .taskLayout("header", report: report)
    }

    private func report(_ role: String, _ frame: CGRect) {
        #if DEBUG
        onLayout?(role, frame)
        #endif
    }
}

private extension View {
    func taskLayout(_ role: String, report: @escaping (String, CGRect) -> Void) -> some View {
        #if DEBUG
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report(role, $0) }
        #else
        self
        #endif
    }
}
