import LocalAuthentication
import SwiftUI

/// Private's New Tab with nothing typed. The eyes open it at once, with no
/// Face ID: searching privately needs none. The private tabs already open sit
/// under a lock in the middle of the room over the field; Unlock asks for
/// Face ID, the lock's shackle springs open, and the tabs rise in its place.
/// The lock is always there, with no private tabs open too.
struct PrivateNewTab: View {
    @Environment(AppModel.self) private var app
    @State private var opened = false
    @State private var listed = false
    @State private var openedAt: Date?
    /// Unlock was asked for: the words and the button are gone, the lock waits in the middle.
    @State private var trying = false

    #if DEBUG
    /// A named state (newtab.private.empty) shows the unlocked page in a
    /// fixture world, where Face ID cannot be given.
    static var listedForStates = false
    /// A named state (newtab.private.trying) shows the lock waiting alone.
    static var tryingForStates = false
    #endif

    private var privateSpace: Space? { app.browser.spaces.first(where: \.isPrivate) }
    private var tabs: [Tab] { privateSpace?.today ?? [] }
    /// The lock stands alone in the middle: asked, being asked (its own sheet
    /// may have come up by itself), or open.
    private var gone: Bool { opened || trying || app.privateLock.phase == .authenticating }

    var body: some View {
        Group {
            if listed {
                // Nothing open: the page grows in as the lock fades and shrinks. Tabs rise.
                list
                    .transition(tabs.isEmpty ? .opacity.combined(with: .scale(scale: Metrics.PrivatePage.swapIn))
                                             : .opacity.combined(with: .offset(y: 14)))
            } else {
                lock
                    .transition(.opacity.combined(with: .scale(scale: Metrics.PrivatePage.swapOut)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            #if DEBUG
            if Self.listedForStates { opened = true; listed = true; return }
            if Self.tryingForStates { trying = true; return }
            #endif
            // Already open in this foreground (Face ID given), or no lock at
            // all: the list, never "Private is Locked".
            if app.privateLock.mayReveal { opened = true; listed = true }
        }
        // The moment Face ID is sure, which under its own sheet is before the
        // scene is active again to show the tabs.
        .onChange(of: app.privateLock.isVerified) { _, verified in
            if verified { open() }
        }
        .onChange(of: app.privateLock.phase) { _, phase in
            switch phase {
            case .unlocked: if !listed { reveal() }
            case .locked, .failed:
                if app.privateLock.requiresAuthentication { close() }
                // A try that did not open it: the words and the button come back, the lock goes up.
                if trying { withAnimation(Motion.disabled ? nil : Motion.privateGlide.animation) { trying = false } }
            case .authenticating: break
            }
        }
    }

    /// The shackle springs open.
    private func open() {
        guard !opened else { return }
        Haptics.play(.soft, reason: Haptics.Reason.privateUnlocked)
        openedAt = Date()
        withAnimation(Motion.disabled ? nil : Motion.privateShackle.animation) { opened = true }
    }

    /// The tabs rise where the lock was, as soon as its shackle is open.
    private func reveal() {
        open()
        // The open lock is seen for a beat before the page takes its place.
        let rest = Motion.disabled ? 0
            : max(0, Motion.privateShackle.duration + Metrics.PrivatePage.openHold - Date().timeIntervalSince(openedAt ?? Date()))
        DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
            guard opened else { return }
            let swap = tabs.isEmpty ? Motion.privateSwap : Motion.typedRows
            withAnimation(Motion.disabled ? nil : swap.animation) { listed = true }
        }
    }

    /// Locked again (the app left the foreground): the lock closes and the
    /// tabs go, with no motion to see.
    private func close() {
        guard opened || listed else { return }
        openedAt = nil
        withTransaction(Transaction(animation: nil)) { opened = false; listed = false; trying = false }
    }

    /// Face ID through the lock when the setting asks for it; when it
    /// doesn't, Private's tabs still open only after Face ID, here.
    private func unlock() {
        withAnimation(Motion.disabled ? nil : Motion.privateGlide.animation) { trying = true }
        if app.privateLock.requiresAuthentication {
            app.privateLock.unlockInPlace {}
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { reveal(); return }
        Task { @MainActor in
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your private tabs")) ?? false
            if ok { reveal() } else { withAnimation(Motion.disabled ? nil : Motion.privateGlide.animation) { trying = false } }
        }
    }

    /// Private, locked: a gray lock with no plate, "Private is
    /// Locked" and an Unlock button. Nothing here says whether Private holds
    /// tabs (no count), so the page is the same with none and with some. A
    /// failed try says why under the button, in a line kept free for it so
    /// nothing moves. Unlock asked, the words and the button go and the lock
    /// glides to the middle of the page, where it waits for Face ID alone.
    private var lock: some View {
        typealias M = Metrics.PrivatePage
        let failed: String? = if case let .failed(words) = app.privateLock.phase, !opened { words } else { nil }
        return VStack(spacing: M.lockGap) {
            PrivateMark(mark: .lock(open: opened))
            if !gone {
                Text("Private is Locked")
                    .font(.system(size: M.lockTitle))
                    .foregroundStyle(Color.white.opacity(M.lockInk))
                    .accessibilityAddTraits(.isHeader)
                    .transition(.opacity.animation(Motion.privateWords.animation))
                Button {
                    Haptics.play(.soft, reason: Haptics.Reason.privateUnlocked)
                    unlock()
                } label: {
                    Text("Unlock")
                        .font(.system(size: M.unlock))
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .accessibilityIdentifier("private.unlock")
                .transition(.opacity.animation(Motion.privateWords.animation))
                Text(failed ?? " ")
                    .font(.system(size: M.note))
                    .foregroundStyle(Color.white.opacity(M.noteInk))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, M.noteInset)
                    .accessibilityHidden(failed == nil)
                    .transition(.opacity.animation(Motion.privateWords.animation))
            }
        }
        .animation(Motion.disabled ? nil : Motion.privateGlide.animation, value: gone)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("private.lock")
    }

    @ViewBuilder
    private var list: some View {
        if tabs.isEmpty {
            PrivateEmptyPage()
        } else {
            tabsList
        }
    }

    private var tabsList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Private")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, SpacePagesCard.edge)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                ForEach(tabs) { tab in
                    Button {
                        if let id = privateSpace?.id { app.chooseFromSpacePage(tab.id, in: id) }
                    } label: {
                        WordRowView(row: WordRow(action: .tab(id: tab.id), icon: .favicon(key: tab.icon, host: tab.host),
                                                 title: tab.short, subtitle: tab.addressHost, key: .go, group: .tabs),
                                    best: false, dark: true, isPrivate: true)
                            .padding(.horizontal, SpacePagesCard.side)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("private.tab.\(tab.id)")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("private.tabs")
    }
}
