# PDF presence native document ownership correction

Pure production scope tests are authored, NOT RUN. Append to an existing combined
coordinator job: bash YabCore/tests/original_pdf_presence_owner.sh. This script
requires YAB_FARM_OUT, compiles the production value-only scope header and checks
16 assertions. It does not execute CEF, the native getter, or a prepared app.

Known regression: primary OnLoadEnd admits an observer with helper context
counter G. Later Runtime.executionContextsCleared increments Tab counter G+1
without changing the actual native RFH document. Previous liveness permanently
dropped ready callbacks because it compared these mutable counters.

The frozen V2 observe ACK and event documentGeneration now retain the original
admission stamp. Swift's local epoch -> original ACK mapping is unchanged.
Callback liveness separately compares the existing synchronous native capture
state's actual primary DocumentToken and DevTools frame token, original browser
object/id, connection, tab and profile. Getter must have typed version1, matching
browser, scope browser, known true and bounded nonempty document/frame strings.
No capture controls/permission effects or new observers are created by reading
that existing native state. Presence API availability now also requires that
existing native identity API. Both enable flags remain default0.

Native metadata rootDocument/rootFrameId must match the admitted native owner.
The queued main delivery runs the same native liveness validation again.
Same-document CDP context changes therefore preserve an admitted observer;
actual document/frame/browser/helper/profile replacement rejects old metadata.
Native primary navigation still suspends/rearms through the existing native
OnBeforeBrowse/OnLoadStart/OnLoadEnd hooks. Foreign peers cannot install or rearm
an observer. No polling, URL inference, reconnect, native source/cache changes,
additional farm submission or capability promotion.

Full proof still required on the future SDK77 prepared app:
1. actual remote/blob/auth PDF DocumentLoadComplete after page.finished;
2. trace ordering with executionContextsCleared after native LoadEnd and observe
   ACK; ready metadata delivered with exact unchanged native document/root frame;
3. native document replacement between callback and queued delivery rejects it;
4. subframe loads preserve parent observer; navigation/crash/drop/close retire it;
5. V2 Swift mapping, duplicate handling and fresh State/export source equality;
6. no CEF ref surviving shutdown or library unload; literal helper syntax on
   both API modes, including source77 experimental headers and enabled test flags.

Native integration is NOT RUN. A synthetic context-clear event is not proof of
native document ownership; native getter stamps must come from the actual SDK.
Fresh bytes still use original_pdf.inc's independent native State/export checks.
That adapter's mutable context counter remains conservatively fail-closed if it
changes during a byte read; this packet does not widen byte-transfer lifetime.
