# Floating notices

The page foot and the page corner speak with one visual system. A notice is a short-lived surface over a page; it uses `HUD.plate` for Liquid Glass on macOS 26 and a solid fallback when transparency is reduced or unavailable. The surface has one message and only the controls needed for that message.

## Surface and controls

| State | Place | Surface | Controls | Leave |
| --- | --- | --- | --- | --- |
| Suggested page action | Bottom center | Page glass, 36 pt high | Quiet **Skip**, primary action with ⌘J | Skip, drag down, page interaction, tab change |
| Agent working | Bottom center | Dark glass, 36 pt high | Secondary **Take Over** | Agent finishes or asks for help |
| Person driving | Bottom center | Light glass, 36 pt high | Secondary **Hand Back** | Hand back or agent finishes |
| Agent needs an answer | Bottom center | Page glass card | The card's existing secondary and primary answers | Explicit answer only |
| Agent answer or draft | Bottom center | Page glass card | The card's existing Copy, Rewrite, Send or close | Explicit close or next action |
| Confirmation toast | Top right | Dark glass, 28 pt high | None, unless **Undo** or **Show** applies | Timer or drag up |
| Page copy offer | Top right | Dark glass, 28 pt high | Copy, Markdown, File; **Show** after file copy | Pick, timer or drag up |

The page offer and agent dock use `ButtonSize`, `ButtonKind`, `Radius.control` and `Press` from `Buttons.swift`. `ToastButton` is the 22 pt corner variant: its smaller radius and inset fit the 28 pt notice, while its quiet color, hover, press and reduced-motion behavior match the shared buttons. The glass supplies the surface color; the button supplies its hover and pressed wash. A primary button names the proposed action, a quiet button declines an optional offer, and a secondary button changes who controls an active task. Shortcuts live inside their buttons on the same key plates as elsewhere in Yab. Once an offer has Skip, its entire background is no longer a hidden button.

Primary actions inside bottom glass surfaces opt into the shared `YabButtonStyle` glass treatment: an 86% ink tint and a fine inner light edge over the card's existing `HUD.plate`. The card does the backdrop blur once; the button lets that result show through. Its shape, type, key plates and press scale stay identical to other primary buttons. Hover and press only change tint opacity and scale, without changing layout. In dark appearance the ink and text invert together. With Reduce Transparency or before macOS 26, the primary button uses its usual opaque fill. Page and Settings primary buttons keep their existing style.

## Dismissal contract

**Skip** on a page action clears only `Hints.offered` for that tab. The new-tab row, site skill and ⌘J remain available. Dragging the offer down does exactly the same thing. It never starts an agent and never records the underlying task as done or permanently unwanted.

Transient notices follow the edge they came from: bottom notices follow a downward pull; top notices follow an upward pull. A clear vertical drag or quick flick commits; a short pull returns to rest. Buttons still take normal clicks. The drag fades the surface as it moves, and Reduce Motion replaces travel with a short fade. A toast's swipe discards its presentation and any pending Undo button, without taking the Undo action. A call for help may be hidden without resolving the agent's request; another request can still appear.

An agent request and a draft with a Send button do not use a swipe to dismiss: a stray drag must not silently answer, abandon or send a task. They keep their explicit controls. A plain answer keeps its close button so a reader can select or scroll its text without a competing drag.

## Tactile feedback

An offer gets one light alignment tap when its action becomes available: the bottom page action, the page-copy choice, or the first site-action shortcut tip. A completed action gets one generic tap after it succeeds: copying, bookmarking, importing, moving, tidying, sending, or an agent finishing. Errors, empty results, and information-only notices do not tap. Feedback only plays while Yab is active, and repeated signals within a quarter second are coalesced. macOS silently skips it on hardware without haptics.

## Code boundaries

- `Toast.swift`: shared glass, toast state and corner controls.
- `NoticeMotion.swift`: edge-aware drag and dismissal motion.
- `Buttons.swift`: one button geometry and color treatment across page, light glass and dark glass.
- `AgentHints.swift`: optional page offer and its Skip semantics.
- `AgentDock.swift`, `AgentAsk.swift`, `AgentAnswer.swift`: status, request and result at the page foot.
- `PageCopy.swift`: corner copy offer.
- `NoticeFeedback.swift`: native tactile patterns, active-app gate and duplicate suppression.

## Visual and interaction checks

Review the running Yab Dev bundle over light, dark and mixed-color pages. Check the suggested action at narrow width; press each button; drag down slowly, flick down, then try a short drag that returns. Check ⌘J after Skip. For top notices, check a plain copy, Undo and Show, including their timers, hover hold and upward dismissal. Check a long agent answer and a request with choices to confirm that text selection, scrolling and buttons remain reliable. Repeat the drag checks with Reduce Motion and Reduce Transparency enabled.

Captured from the running test bundle on adhd:

The [same-build performance comparison](evidence/glass-primary-2026-09-26/README.md) measures the offer's entrance and exit in both appearances, including main-thread CPU, frame gaps and run-loop pauses.
