# Navigation and engine-switch authority

Live engine changes currently fail before capture, cookie synchronization, preference writes or source retirement because no verified production group-switch authority exists. This includes automatic routes; retaining the original document is intentional. This is an active release blocker, not complete DRM fallback or full WebKit parity.

| Trigger | Available intent | What it does not prove |
| --- | --- | --- |
| Explicit site/global engine choice | Requested destination plus exact original row, profile and page handle | Native Leave approval, a document/input seal, or retain-all final commit |
| WK main-frame navigation through `routeSiteEngine` | App navigation policy allowed the original request; generated WK UA/Accept are removed, original permitted request/referrer retained | WebKit has not yet received its `.allow` decision, so this is not a native beforeunload answer or an approved replacement document |
| Chromium pre-navigation service routing | Requested URL and exact current `ChromiumPage`, profile and DRM turn | Old document may still own beforeunload handlers and unsaved input |
| Chromium native `page.state` routing | Current native reported main-document URL and exact remote endpoint | Native page state is not an unload approval or source capture seal |
| Native Widevine-unavailable event | Exact current main URL, `com.widevine.alpha` and current native endpoint | An EME failure is not consent to discard the original document |

Both automatic directions now use `EngineSwitchTransaction`. Reverse routing revalidates its original DRM turn, profile, exact page handle, target and current fallback policy at every transaction boundary. The callback is a veto only; it never acts as native consent. The transaction also rechecks original row owner/placement, navigation revision, page URL/identity and input barriers.

A future already-approved native navigation must supply an authenticated original document tree, owner/profile, navigation request and request/approval identity. Only the native authority may consume that receipt instead of showing a second prompt. No such receipt is currently exposed to these routes. Do not infer it from app policy `.allow`, a matching URL, a destination page, a script event or a prior dialog answer for another document.

The required native sequence is whole-group reserve, non-destructive approvals, seal and drain original input/navigation, native capture under the acknowledged all-frame seal, profile synchronization, exact validation and one retain-all/release-all irreversible commit. Per-tab native close final ACKs arrive after unload side effects and cannot provide this guarantee. Mixed WK/CEF ownership and crash/transport outcomes require their own proven authority.

The current JS-based `EngineSwitchProfileTransfer` is unreachable for production live changes. It cannot capture a renderer paused by the proposed native seal. A future production adapter must provide the native fixed capture lane and bind each result to the exact group, seal and original document tree; ordinary JS evaluation after pause is not a substitute. Current portable data is bounded main-document local/session storage, permitted controls and scroll. IDB, CacheStorage, service workers, push, native history and cross-frame migration remain separate active gaps.

The strict prepared-app engine-switch golden and reporter/profile acceptance remain required. `TabEngineTests` explicit controller adapters verify scheduling, retention barriers, geometry and lazy settings only. They do not prove native approval, paused capture, irreversible atomicity or seamless migration.
