import SwiftUI
import UIKit

/// The whole screen, in layers, back to front. The order is fixed here so
/// every branch knows where its surface stands; each layer draws nothing
/// until its part of Surfaces says so.
///
///  1. the page, edge to edge (PageLayer), its neighbors beside it while a
///     swipe on the plate pages through tabs (Paging/PagingLayer), under
///     it what a pull from the left edge reveals (Back/BackRevealLayer),
///     the previous tab's page growing out of the tab stack (Tabs/TabFlickLayer)
///  2. the scrim over the page while a surface is up
///  3. All Tabs (Tabs/TabGalleryLayer), under one persistent bottom toolbar
///     over the page (ChromeLayer)
///  5. the field over the keyboard (Field/FieldLayer)
///  6. answers and chats (Chats/ChatsLayer)
///  6b. a task's chat, the code, the yes and Face ID (Tasks/TasksLayer)
///  7. the first launch's welcome (Welcome/WelcomeLayer)
///  8. settings, and joining a Mac over it with a code or the Recovery Key
///     (Settings/SettingsLayer, its contents Join/JoinLayer)
///  9. the toast (ToastLayer)
/// 10. in test runs, the design sheet (Testing/DesignSheet)
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let _ = MainStalls.count("root")
        let _ = UpdateLoops.count(.root) {
            UpdateLoops.Fingerprint(fields: [
                "privateLock.isActive": app.privateLock.isActive ? 1 : 0,
                "privateLock.authenticating": app.privateLock.phase == .authenticating ? 1 : 0,
                "privateLock.presentsPrompt": app.privateLock.presentsPrompt ? 1 : 0,
                "hasPrivateForeground": app.hasPrivateForeground ? 1 : 0,
                "privateContentBlocked": app.privateContentBlocked ? 1 : 0,
            ])
        }
        Group {
            if !app.privateLock.isActive && app.privateLock.phase != .authenticating
                && (app.hasPrivateForeground || app.privateLock.presentsPrompt) {
                // Face ID itself makes the scene inactive: under its own sheet
                // the screen keeps what it shows, which is never private tabs.
                Color.black
            } else if app.privateContentBlocked || app.privateLock.presentsPrompt {
                PrivateLockView()
            } else {
                BrowserWorkspaceView { content }
            }
        }
        .modifier(TabEditAlert())
        .ignoresSafeArea()
        .environment(\.colorScheme, AppAppearance.current)
        .background {
            AppearanceProbe(appearance: SettingsStore.shared.appearance)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            // Where Translate gets languages not on this iPhone yet (Page/PageTranslation).
            TranslationHost()
        }
        .transaction { if app.privateContentBlocked || app.privateLock.presentsPrompt { $0.animation = nil } }
        .onChange(of: app.privateContentBlocked || app.privateLock.presentsPrompt) { _, blocked in
            if blocked { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
    }

    private var content: some View {
        let _ = MainStalls.count("content")
        // Observe before the deferred geometry closure so these changes relayout it.
        let _ = app.field.revision
        let expanded = app.workspace.expanded
        let unfolded = app.workspace.unfolded
        let fieldShown = app.field.shown
        let chatShown = app.chatSheet.shown
        return GeometryReader { geo in
            let sidebar = expanded && fieldShown && (!unfolded || app.field.spacesResting)
                && geo.size.width >= Metrics.Workspace.sidebar + Metrics.Workspace.minimumPane ? Metrics.Workspace.sidebar : 0
            let conversation = expanded && chatShown && !fieldShown
                && geo.size.width >= Metrics.Workspace.conversation + Metrics.Workspace.minimumPane ? Metrics.Workspace.conversation : 0
            ZStack(alignment: .topLeading) {
                pageLayers
                    .frame(width: max(1, geo.size.width - sidebar - conversation), height: geo.size.height)
                    .clipped()
                    .offset(x: sidebar)
                // Unfolded: the spaces stand in their column, search in the middle.
                if unfolded, fieldShown, !app.field.spacesResting {
                    TabletOmnibox(geometry: TabletWorkspaceGeometry(size: geo.size, statusBar: 0, sidebar: false, framed: false))
                } else {
                    WorkspaceFieldLayer()
                }
                WorkspaceChatsLayer()
                TasksLayer()
                WelcomeLayer()
                SettingsLayer()
                AboutLayer()
                ReaderCardLayer()
                ToastLayer()
                AssistantApprovalLayer()
                if app.showsDesignSheet { DesignSheet() }
            }
        }
    }

    private var pageLayers: some View {
        ZStack {
            BackRevealLayer()
            PageLayer()
            PagingLayer()
            TabFlickLayer()
            ScrimLayer()
            BrowserClearUndo()
            EmptyHomeLayer()
            TabGalleryLayer()
            ChromeLayer()
        }
    }
}

/// The page darkened while something stands over it; a tap on it closes
/// what is open. The surfaces set how dark (Surfaces.scrim).
struct ScrimLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let darkness = app.surfaces.scrim
        Color.black
            .opacity(darkness)
            .ignoresSafeArea()
            .allowsHitTesting(darkness > 0.001)
            .onTapGesture {
                let surfaces = app.surfaces
                if surfaces.menu != nil { Motion.menuClose.run { surfaces.closeMenu() } }
                else if surfaces.field != nil { Motion.fieldClose.run { surfaces.closeField() } }
            }
            .accessibilityHidden(true)
    }
}
