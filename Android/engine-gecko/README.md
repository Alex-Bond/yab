# Gecko scoped site data qualification

This is a maintained, **unapplied and unbuilt** source kit for the current Gecko engine. It is independent of the next-release Chromium/extensions work. It changes no app dependency, MainActivity, engine adapter, permission, signature policy, cookie preference or user profile.

The current app's **Clear Data for This Site remains unavailable**. Neither a whole-profile deletion nor cookies-only deletion is presented as that action. The qualification API exposes its supported classes explicitly; a full-type request is rejected before enumeration or mutation.

## Exact inputs

`source-pins.json` binds the official GeckoView `158.0.20261021001945` Maven AAR and its POM SCM revision `e4ce606692cd81e6898547e2edd7c552fefcbb04`. AAR SHA256 is `45c5c4e452ad7b52778c27bc5e7583f3cb182df4c6615e42849afe2b8a2d71ba`, read from Mozilla's official SHA256 sidecar. Fifteen small public upstream files are preserved byte for byte in `upstream/`, with MPL notices, URLs and hashes. This is not a Firefox checkout or a downloaded binary.

The exact preserved v5 debug APK independently identifies the same revision in `AppConstants.sys.mjs`; that evidence does not establish this patch's execution.

## What the patch actually does

`patches/0001-scoped-storage-qualification.patch` adds one native-only GeckoView Java entry point, its dispatcher event, and two privileged system modules. No WebExtension message, guest script, webpage or HTTP endpoint gets this operation. It retains the existing `createSafeSessionContextId` encoder, and requires an explicit context, exact Boolean Private mode, and a literal canonical ASCII host.

The implemented qualification mask is **7**:

| Bit | Data | Scope and completion |
| --- | --- | --- |
| 1 | Cookies | Captured native cookie origin attributes, exact host, exact GV context, private bit and default user-context ID. No global compression-dictionary cleaner. |
| 2 | Quota storage | Native QMS origin enumeration and exact principal deletion after service-worker cleanup. LSNG is required; the legacy host-only purge observer is never called. This includes QMS-backed localStorage, IndexedDB, CacheStorage and file-system data, and matching service-worker registrations. |
| 4 | HTTP cache | Real native cache descriptors from `nsICacheStorageVisitor`; exact host/context/Private match; each `asyncDoomURI` completion is awaited and checked. No second GET, copied cookies, default jar, global base-domain eviction, or URL-based capability. |

Unknown bits, invalid provenance, default context, unsupported legacy storage, failed enumeration, overlarge datasets and incomplete callbacks fail. Some supported-data operations can fail after deleting some **owned** data; failure must not be described as “nothing changed.” Active pages can create new data after a clear, as the upstream API also documents. This kit does not claim atomic deletion against concurrent writers.

**The full mask is 255 and is deliberately unsupported.** SessionStorage, resource memory cache, MediaKeys, device salt and recent-search state do not silently disappear from the requested mask. The exact-host API also refuses Unicode/IPv6 inputs pending a reviewed canonical-host contract; it never expands to a registrable domain or clears parent/subdomain rows.

## Why full parity needs another native patch

Phone `Page/WebPool+Site.swift:96–109` uses the live tab's actual WKWebsiteDataStore and all public data types, then reloads. Its display-record matching can include a parent domain; the exact-host qualification API does not claim this grouping parity. Public iOS17+ types include MediaKeys and device-ID HashSalt. The local iPhone SDK header and [WebKit's actual allWebsiteDataTypes implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.mm) establish that these are real requirements.

The pinned `ClearDataService.sys.mjs` cannot safely be reused wholesale:

- NetworkCacheCleaner `482–485` ignores the origin-attribute pattern and calls global `clearBaseDomain`.
- QuotaCleaner `797–806` sends a legacy localStorage purge without a context.
- MediaDevicesCleaner `679–697` has no scoped primitive and can call `deleteAll`.
- HSTS `1704–1712`, EME `1737–1742`, reporting `1764–1766` and other cleaners ignore the requested pattern.
- CookieCleaner `305–306` clears a compression dictionary by URI without an origin-attribute argument.

`MediaParent.cpp:478–530` currently clears the whole origin-key table asynchronously. The table's actual key is the principal origin plus origin-attribute suffix (`111–133`). A complete patch must add exact host/context/private table filtering, preserve unselected keys on write failure, and acknowledge the durable operation. Android MediaDRM unprovisioning (`MediaDrmRemoteCDMParent.cpp:910–944`) is synchronous but currently ignores errors. A scoped checked result and native tests are required before claiming MediaKeys completion. Default production behavior must remain unchanged.

SessionStorage and resource-cache APIs also need exact-host filtering rather than a schemeless-site expansion or enumeration that misses cache-only principals. No unsafe fallback is included here. These native changes are **not implemented by this qualification patch**, and the current action must remain disabled until they are.

## Bounded farm preparation and build plan

Nothing in this kit starts a job or downloads a toolchain implicitly. Parent owns the shared-queue submission. The first preparation must run on the already authorized `aws-2` worker; `scripts/prepare-source.py` enforces the real executor/hostname guard and refuses main and any source outside that fresh `$YAB_FARM_OUT` slot.

1. Use a fresh owned checkout of the exact Mozilla release revision inside the current result slot. Never change this Fast checkout or reuse another task's modified source. Record the checkout/archive hash, revision, installed SDK/JDK/toolchain identities and available space. A new source checkout and Mozilla bootstrap dependencies are not present in the current app SDK merely because Gradle passed.
2. Verify the exact AAR hash before reuse; do not choose a nearby nightly or latest binary. For an artifact build, set `MOZ_ARTIFACT_REVISION=e4ce606692cd81e6898547e2edd7c552fefcbb04` and bind every resolved native artifact hash in the receipt. Fail if exact revision artifacts cannot be resolved.
3. Apply only the reviewed patch:

   ```sh
   python3 Android/engine-gecko/scripts/prepare-source.py --source "$YAB_FARM_OUT/gecko-source"
   ```

4. Mozilla's [artifact build documentation](https://firefox-source-docs.mozilla.org/contributing/build/artifact_builds.html) supports Android Java and JS changes while reusing compiled C++. The documented packaging path is `mach build`, `mach package`, `mach android archive-geckoview`; [custom AAR instructions](https://firefox-source-docs.mozilla.org/mobile/android/focus-android/Development-Custom-GeckoView.html) describe the result. Run the API-lint/update step for this additive custom API and preserve its generated API diff/hash. Do not force a preexisting API hash to pass.
5. Validate the resulting AAR's Java entry point, dispatcher/modules, complete ABI inventory, unchanged native-library hashes, source revision and output SHA256. Publish it under an explicit custom coordinate, never overwrite Mozilla's cache entry. Current app dependency substitution requires a separately reviewed integration snapshot.
6. Copy `tests/ScopedSiteDataTest.kt` into the same owned Gecko source's test tree, compile it, then run exactly its four real-engine methods through GeckoView's existing JUnit harness and the owned HVF AVD. The tests use two random public context IDs, a Private session deliberately sharing the first raw context ID, and a neighboring loopback hostname. Actual HttpOnly cookie echo, native localStorage, cache reuse/doom, and full-type refusal are asserted. This is a scoped-data qualification, not full Clear Data parity.

The eight Node policy cases are authored but **unrun**:

```sh
node --test Android/engine-gecko/tests/site-policy.test.mjs
```

Full C++/IDL changes cannot use artifact-only mode. Their build must compile the matching Gecko native libraries for ARM64 and x86_64, then rerun the strict package/layout/JNI tests and native context matrix. [Mozilla documents](https://firefox-source-docs.mozilla.org/contributing/build/artifact_builds.html#things-that-are-not-supported) that artifact mode cannot incorporate C/C++/Rust changes. No build duration or full feature acceptance is inferred from source preparation.

## Evidence boundary

Only public-source reads, pin generation and source editing have occurred. No patch was applied to a running engine, no build/test/emulator/provider/job was started, and no clearing was executed. The root's existing app proof snapshots do not cover this separate kit.
