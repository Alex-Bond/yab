import SwiftUI
#if canImport(SyncKit)
import SyncKit
#endif

/// The tray's body for the step it is on, with the one it left fading out
/// under it (the new one rising 8 points as it comes). Each body is laid out
/// at its own height, which the tray's height spring follows; taller than
/// the tray may be, it scrolls inside.
struct ApprovalBodies: View {
    let tray: ApprovalTray
    let content: ApprovalContent
    let cap: CGFloat
    var geometry: ApprovalGeometry? = nil
    private typealias M = ApprovalMetrics

    var body: some View {
        let height = max(0, min(tray.height - (tray.step == .cards || tray.step == .places ? 0 : tray.footer), cap - tray.footer))
        ZStack(alignment: .top) {
            if let leaving = tray.leaving, leaving != tray.step {
                page(leaving)
                    .opacity(1 - (tray.leaving == nil ? 1 : Double(min(1, max(0, tray.swap)))))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            page(tray.step)
                .opacity(tray.leaving == nil ? 1 : Double(min(1, max(0, tray.swap))))
                .offset(y: tray.leaving == nil ? 0 : M.rise * (1 - min(1, max(0, tray.swap))))
        }
        .frame(height: height, alignment: .top)
        .clipped()
    }

    private func page(_ step: ApprovalTray.Step) -> some View {
        ScrollView {
            ApprovalBody(tray: tray, content: content, step: step)
                .padding(.horizontal, M.pad)
                .padding(.top, 2)
                .padding(.bottom, step == .cards || step == .places ? M.pad : 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tray.measured(step, height: $0) }
        }
        .scrollDisabled((tray.bodyHeight(step) ?? 0) <= cap - tray.footer)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }
}

/// One body: what the step shows.
struct ApprovalBody: View {
    @Environment(AppModel.self) private var app
    let tray: ApprovalTray
    let content: ApprovalContent
    let step: ApprovalTray.Step
    private typealias M = ApprovalMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step {
            case .root: root
            case .all: rows(content.items, all: true)
            case .cards: ApprovalCardList(tray: tray, content: content)
            case .places: ApprovalPlaceList(tray: tray, content: content)
            case .newCard: ApprovalCardForm(tray: tray)
            case .newPlace: ApprovalPlaceForm(tray: tray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var root: some View {
        if let question = content.question {
            Text(question)
                .font(.system(size: M.question, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("approval.question")
        }
        switch content.kind {
        case .pay: ApprovalPayRoot(tray: tray, content: content)
        case .mails: rows(content.items, all: false)
        case .mail: paper
        case .files: files
        case .message: bubble
        case .search: search
        case .accounts: accounts
        case .lines: lines
        }
    }

    // MARK: a mail search for the chat

    @ViewBuilder
    private var search: some View {
        if let first = content.search {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: first.opens ? "envelope" : "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatInk.gray(0.55))
                    Text(first.words)
                        .font(.system(size: 16))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(ChatInk.fill(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(first.opens ? "And any mail after it, until this chat ends." : "And any search after it, until this chat ends.")
                    .font(.system(size: 14))
                    .foregroundStyle(ChatInk.gray(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .padding(10)
            .background(ChatInk.fill(0.06), in: RoundedRectangle(cornerRadius: M.group, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("approval.search")
        }
        // An older Mac says nothing of the search: the scope, still.
        if let line = content.terms ?? (content.search == nil ? "Every search in this chat, until it ends." : nil) {
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(ChatInk.gray(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    // MARK: rows that open

    private func rows(_ items: [ApprovalContent.Item], all: Bool) -> some View {
        let shown = all ? items : Array(items.prefix(content.shown))
        let more = all ? 0 : items.count - shown.count
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 62) }
                ApprovalRow(item: item)
                    .opacity(tray.windowItem.map { content.items[safe: $0]?.id == item.id } == true ? 0 : 1)
                    .trayFrame(tray, "tray:row.\(item.id)")
                    .contentShape(Rectangle())
                    .onTapGesture { tray.openWindow(content.items.firstIndex(of: item) ?? index, key: "tray:row.\(item.id)") }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("approval.row.\(index)")
            }
            if more > 0 {
                Divider().padding(.leading, 62)
                HStack(spacing: 12) {
                    Text("+\(more)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatInk.gray(0.6))
                        .frame(width: M.avatar, height: M.avatar)
                        .background(ChatInk.fill(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(more) more").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.accentColor)
                        Text(items.dropFirst(shown.count).prefix(4).map(\.title).joined(separator: ", "))
                            .font(.system(size: 13)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(ChatInk.gray(0.3))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: M.row)
                .trayFrame(tray, "tray:more")
                .contentShape(Rectangle())
                .onTapGesture { tray.go(.all) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("approval.more")
            }
        }
        .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: M.group, style: .continuous))
    }

    // MARK: one mail

    private var paper: some View {
        ApprovalPaper(mail: content.items.first?.mail)
        .opacity(tray.windowItem == 0 ? 0 : 1)
        .trayFrame(tray, "tray:paper")
        .contentShape(Rectangle())
        .onTapGesture { tray.openWindow(0, key: "tray:paper") }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("approval.paper")
    }


    // MARK: files

    private var files: some View {
        let request = tray.request
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: min(3, max(1, content.files.count))), spacing: 12) {
            ForEach(content.files) { file in
                VStack(spacing: 8) {
                    ApprovalPage(file: file, image: request.flatMap { app.sync.assistantPreview($0, file: file.id, page: 0) })
                        .frame(width: 84, height: 108)
                        .opacity(tray.pictureFile?.id == file.id ? 0 : 1)
                        .trayFrame(tray, "tray:file.\(file.id)")
                    Text(file.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.middle)
                    Text(ApprovalWords.size(file)).font(.system(size: 12)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: M.group, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { tray.openPicture(file, key: "tray:file.\(file.id)") }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("approval.file.\(file.id)")
            }
        }
    }

    // MARK: a message

    private var bubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(content.text ?? "")
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(red: 0, green: 0.48, blue: 1), in: UnevenRoundedRectangle(topLeadingRadius: 19, bottomLeadingRadius: 19,
                                                                                        bottomTrailingRadius: 6, topTrailingRadius: 19, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: a sign-in

    private var accounts: some View {
        VStack(spacing: 0) {
            ForEach(Array(content.accounts.enumerated()), id: \.element) { index, user in
                if index > 0 { Divider().padding(.leading, 62) }
                Button { tray.yes(account: user) } label: {
                    HStack(spacing: 12) {
                        Text(ApprovalContent.initials(user))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: M.avatar, height: M.avatar)
                            .background(ApprovalContent.tint(user), in: Circle())
                        Text(user).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        ApprovalProofGlyph(size: 20).foregroundStyle(ChatInk.gray(0.45))
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: M.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ApprovalPress())
                .disabled(!tray.canChange)
                .accessibilityLabel("Sign in as \(user)")
                .accessibilityIdentifier("approval.account.\(index)")
            }
        }
        .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: M.group, style: .continuous))
    }

    // MARK: anything else

    @ViewBuilder
    private var lines: some View {
        if !content.lines.isEmpty || content.text != nil {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 15)).foregroundStyle(Ink.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let text = content.text {
                    Text(text).font(.system(size: 16)).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: M.group, style: .continuous))
        }
    }
}

/// One mail going, as paper: To, Subject, its first lines, Show All.
struct ApprovalPaper: View {
    let mail: AssistantApprovalRecords.Detail.Mail?
    private typealias M = ApprovalMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mail {
                VStack(alignment: .leading, spacing: 3) {
                    header("To", mail.to.map(ApprovalContent.named).joined(separator: ", "))
                    if !mail.cc.isEmpty { header("Cc", mail.cc.map(ApprovalContent.named).joined(separator: ", ")) }
                    if let bcc = mail.bcc, !bcc.isEmpty { header("Bcc", bcc.map(ApprovalContent.named).joined(separator: ", ")) }
                    header("Subject", mail.subject)
                }
                Divider()
                Text(mail.body)
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(M.paperLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !mail.files.isEmpty {
                    Text(mail.files.map(\.name).joined(separator: ", "))
                        .font(.system(size: 13)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(1)
                }
                HStack {
                    Spacer()
                    Text("Show All")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(ChatInk.fill(0.12), in: Capsule())
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: M.group, style: .continuous))
    }

    private func header(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(.system(size: 14)).foregroundStyle(ChatInk.gray(0.6)).frame(width: 58, alignment: .leading)
            Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
        }
    }
}

/// A row that opens: who, what, the first words, an amount.
struct ApprovalRow: View {
    let item: ApprovalContent.Item
    private typealias M = ApprovalMetrics

    var body: some View {
        HStack(spacing: 12) {
            Text(item.initials)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: M.avatar, height: M.avatar)
                .background(item.tint, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.primary).lineLimit(1)
                    if item.mail?.files.isEmpty == false {
                        Image(systemName: "paperclip").font(.system(size: 12, weight: .semibold)).foregroundStyle(ChatInk.gray(0.5))
                    }
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 15)).foregroundStyle(Ink.primary).lineLimit(1)
                }
                if !item.snippet.isEmpty {
                    Text(item.snippet).font(.system(size: 13)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let amount = item.amount {
                Text(amount).font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.primary)
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(ChatInk.gray(0.3))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: M.row)
    }
}

/// A file's page: its picture once it came, else a drawn page.
struct ApprovalPage: View {
    let file: AssistantApprovalRecords.Detail.File
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: file.kind == "image" ? .fill : .fit)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.32)).frame(width: 36, height: 5)
                    ForEach(0..<7, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.12)).frame(height: 3)
                            .frame(maxWidth: i % 3 == 2 ? 40 : .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
    }
}

enum ApprovalWords {
    static func size(_ file: AssistantApprovalRecords.Detail.File) -> String {
        var parts: [String] = []
        if let pages = file.pages, pages > 0 { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        if let w = file.width, let h = file.height { parts.append("\(w) \u{00D7} \(h)") }
        if let bytes = file.bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A row pressed: a quiet wash, never a change of size.
struct ApprovalPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(ChatInk.fill(configuration.isPressed ? 0.1 : 0))
    }
}

extension View {
    /// Where this is, for the window and the page full screen to grow out
    /// of: "tray:" in the tray's own space, "win:" on screen.
    func trayFrame(_ tray: ApprovalTray, _ key: String) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(key.hasPrefix("win:") ? ApprovalGeometry.screenSpace : ApprovalGeometry.traySpace))
        } action: { tray.frames[key] = $0 }
    }
}
