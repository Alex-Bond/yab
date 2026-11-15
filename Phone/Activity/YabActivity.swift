import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Yab's widgets. The Live Activity: the task the Now line speaks for, on the
/// Lock Screen and in the Dynamic Island. The app starts, updates and ends it
/// (TaskActivityController); this draws it with the views the app's own
/// pictures use (TaskActivityViews). Search and Ask: ways into Yab from the
/// Home Screen and the Lock Screen (SearchWidgets, SearchWidgetViews).
@main
struct YabActivityBundle: WidgetBundle {
    // Dates in English, as in the app (EnglishDates).
    init() { EnglishDates.apply() }

    var body: some Widget {
        TaskActivityWidget()
        SearchWidget()
        AskWidget()
        NowWidget()
    }
}

struct TaskActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            LockCard(state: context.state, stale: context.isStale)
                .activityBackgroundTint(ActivityLook.card)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(ActivityButton(action: "open", label: "Open", style: .primary).url(task: context.state.task))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    TaskIslandExpanded(state: context.state) { button in
                        ActivityButtonView(task: context.state.task, button: button, expanded: true)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                TaskIslandLeading(state: context.state)
            } compactTrailing: {
                TaskIslandTrailing(state: context.state)
            } minimal: {
                TaskIslandMinimal()
            }
            // Tapping the Island: Yab, the task's chat growing out of it.
            .widgetURL(ActivityButton(action: "open", label: "Open", style: .primary).url(task: context.state.task))
            .keylineTint(context.state.warn ? ActivityLook.warn : .white)
        }
    }
}

/// The Lock Screen's card; its buttons sleep while the iPhone is locked.
/// The buttons are marked private, so the system draws the card twice, for
/// a locked iPhone and an unlocked one; the locked drawing dims them (.42)
/// instead of blanking them, and their intents ask for Face ID before they
/// do anything (TaskActivityIntent.authenticationPolicy).
private struct LockCard: View {
    let state: TaskActivityAttributes.ContentState
    var stale = false

    var body: some View {
        TaskLockCard(state: state, stale: stale) { button in
            LockAware { locked in
                ActivityButtonView(task: state.task, button: button)
                    .opacity(locked ? ActivityLook.lockedOpacity : 1)
            }
            .privacySensitive()
        }
    }
}

/// Reads whether the system draws the locked card, then shows its content
/// as it is rather than as a redacted placeholder.
private struct LockAware<Content: View>: View {
    @Environment(\.redactionReasons) private var redaction
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(redaction.contains(.privacy))
            .compositingGroup()
            .unredacted()
    }
}

/// Enter Code, Review, Retry and Open open Yab at the task (its sheet grows
/// out of the button); Stop and Not Now act from here.
private struct ActivityButtonView: View {
    let task: String
    let button: ActivityButton
    var expanded = false

    var body: some View {
        if button.opensApp {
            Link(destination: button.url(task: task)) {
                ActivityButtonLabel(button: button, expanded: expanded)
            }
        } else {
            Button(intent: TaskActivityIntent(task: task, action: button.action)) {
                ActivityButtonLabel(button: button, expanded: expanded)
            }
            .buttonStyle(.plain)
        }
    }
}
