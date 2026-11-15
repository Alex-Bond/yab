# Engine-switch uncertainty and recovery contract

Production live authority remains unavailable. These controller changes close uncertainty-handling holes; they do not supply a native backend, durable recovery, destination readiness or complete migration.

`EngineSwitchLease.commit()` is nonthrowing and returns one explicit outcome. Cancellation is not evidence of rollback. The adapter must consume the exact original group's native terminal receipt even when the caller is canceled. A timeout, disconnected transport, helper loss or canceled request after possibly irreversible dispatch returns unknown unless the original outcome is positively reconciled.

| Outcome | Meaning required from the adapter | Controller behavior |
| --- | --- | --- |
| released | All exact original sources irreversibly released by the group authority | Recheck exact row/page URL/handle/owner/profile/navigation/input/intent. With unchanged identities, install destinations and persist in the existing synchronous turn even if caller was canceled. With drift, quarantine without cancel or overwriting replacements. |
| retained | None of the exact sources ran destructive unload or was disposed | No destination install or preference write. Obtain native owned-cancellation/release ACK before freeing local reservations. |
| unknown | Irreversible acceptance or source final outcome is unresolved | Keep whole group, exact original handles/captures and lease in memory; keep local reservations. No cancel, resume, retire, install or preference write. Throw recoveryRequired with an ephemeral descriptor. |

Preparation may throw, but that alone does not prove a safe rollback. `cancel()` is also nonthrowing: retained means no destructive source release and no owned native seal/reservation remains, confirmed by ACK; unknown quarantines the complete group. Cancel cannot resume a replacement document or another owner's reservation. Authority.reserve may throw only if no native reservation remains; an uncertain reservation must return its owner-bound lease for reconciliation.

`EngineSwitchTransaction.recovery(for:)` is a read-only in-memory diagnostic. There is deliberately no reset, retry, unlock or replay API. An elapsed timer, new selection or reconnected helper cannot prove the original outcome. The hold preserves exact objects and captured values; it does not write a journal and cannot survive process death. Native source state is not inferred from those retained Swift objects. Tests use explicit controller adapters and do not establish WK/CEF runtime recovery.

Before enabling any production authority, implement and prove a protected transaction journal and exact native group/owner/receipt reconciliation, staged destination readiness with data restoration verification, source final state and settings reconciliation, plus native lifetime and input/document fences. Native source identities include exact original tree/version and requested destination, not just URL or local row UUID. An after-restart missing source is not proof it was committed. Private snapshots must preserve their ephemeral policy; crash recovery cannot silently persist private credentials or promise restoration of an arbitrary JS heap. Missing or contradictory receipts remain explicit recovery-required states.

The existing controller constructs/navigates destinations only after released, and does not yet obtain a destination-ready receipt. Its positive controller-order adapters prove orchestration, not a complete product migration. This and durable recovery are activation blockers alongside native atomic commit. Keep productionAuthority unavailable until those contracts exist and exact original-process fixtures pass.

## Practical WK to CEF route and current proof boundary

Fresh/asleep handles with no built source document already select the destination before creating a WK page. Their lazy engine and settings tests are a practical safe route and need no fictitious close approval. They do not prove a live WK migration.

For a live WK document the next practical bounded evidence is the current real AppKit-host fixture: trusted native typing, original WK beforeunload UI, exact native document UUID, original timeOrigin/draft, and actual Undo/Redo observations. Recording user Leave at WK's original prompt while answering its native completion false is a narrow non-destructive prompt candidate. It has no native cancellation ACK or no-prompt guarantee. Direct WK native Leave may preserve the DOM while clearing its native Undo target before the UI close callback. A successful original-document read cannot certify that lost history as safe rollback.

Forced `_suspendPage:` uses Back/Forward Cache: pagehide/focus/load-stop, render-tree destruction and frame/opener detach are observable. JS/cocoa snapshot cannot run suspended. A fresh native session-state export is not supplied by copying UI cached back/forward state: HistoryController saves permitted form/scroll state at specific native lifecycle points, and the sampled source requires a living render tree for form-state save. That is neither arbitrary portable storage nor a sealed exact current-document capture. Do not use source heap retention or a frozen compositor image as a portable-data proof.

The surveyed stock WK APIs therefore cannot yet implement the live owned all-frame seal/native fixed capture/final group contract. A source-provided WK primitive or a demonstrably equivalent native interface is required. No DOM listener census, JS mutation lock, timer, app-only input block, BFCache lifecycle transition or frame-UUID polling substitutes for it. Owncef's CEF-only seal candidate cannot grant WK or mixed-engine authority. Keep the strict live switch golden and full data/history migration requirements active.
