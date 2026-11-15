# Architecture

A map for newcomers: where things live and how the pieces talk. Each area has its own page in [docs/](index.md) with the details.

## The repository

| Folder | What it is |
|---|---|
| `Sources/` | The Mac app and its modules (SwiftPM, `Package.swift`) |
| `Tests/` | Swift tests: `FastTests` (the app), `MailCoreTests` (the mail engine), fakes and fixtures |
| `YabCore/` | The Chromium page helper, C++ and Objective-C++ on CEF, and the patches Yab applies to CEF |
| `Resources/` | What the app bundles: page scripts, icons, localization, the Dark Reader engine, DevTools |
| `Phone/` | Yab for iPhone (XcodeGen project, SwiftUI, WKWebView) |
| `Android/` | The Android client, in progress (Kotlin, Compose, GeckoView) |
| `sync-server/` | The sync server: a Cloudflare Worker that stores sealed records it cannot read |
| `SharedContracts/` | Test vectors the Mac, iPhone, Android and server all check against |
| `Skills/` | Skills for agents: how to use a given site or app well (1Password, Asana, Amazon), bundled into the app |
| `Raycast/` | The Raycast extension |
| `evals/`, `qa/`, `bench`, `demo` | Probes, evaluation harnesses, deferred QA cards, and the shell side of the test socket |
| `docs/` | How each part works, one page per area |

Some folders hold the maintainers' own infrastructure (the build farm, release and stand scripts in `scripts/remote`, `scripts/release`, `scripts/stand`, and `./farm`, `./mini`, `./adhd`, `./runs`). You don't need them to build, test or contribute, and they may be left out of the public tree.

## The Mac app

### Modules

`Package.swift` defines these targets. Every module except `Fast` builds without a window, so its tests run fast.

| Module | Folder | What it owns |
|---|---|---|
| `Fast` | `Sources/Fast` | The app: windows, tabs, the field, settings, agents, everything drawn |
| `YabDesign` | `Sources/YabDesign` | The design system: colors as light and dark pairs, corners, spacing, type, motion, icons, the one button (`.yab(kind, size)`) and the keys drawn on it. Knows nothing of the app. |
| `YabStore` | `Sources/YabStore` | Where things are kept: the app's folder, settings, SQLite, the keychain asked without its window |
| `MailCore` | `Sources/MailCore` | The mail engine: Gmail and IMAP, the store on this Mac, sync, search, splits |
| `SyncKit` | `Sources/SyncKit` | What syncs between Macs and iPhone and how two copies become one. No AppKit or UIKit: the iPhone app uses the same module. |
| `YabUpdate`, `YabUpdater` | `Sources/YabUpdate`, `Sources/YabUpdater` | The update feed and the swap of the bundle, and the small agent launchd starts to update a Yab that isn't open |
| `YabCoreClient` | `YabCore/Client` | The Swift side of the wire to the Chromium helper |

`Fast` re-exports `YabDesign`, `YabStore` and `MailCore`, so every file in the app sees them without an import.

### Inside `Sources/Fast`

The folder is flat, one file per concern, grouped by name prefix. There is no in-house framework to learn first.

| Start here | For |
|---|---|
| `App.swift`, `Browser.swift` | The app's entry and the window's state: spaces, tabs, what is selected |
| `Tab.swift`, `Session.swift` | One page and its lifecycle; what comes back at launch |
| `Query.swift`, `Field*.swift` | The one field (`⌘L`, `⌘T`): suggestions, commands, answers |
| `Column*.swift`, `Split.swift`, `Peek.swift`, `Space*.swift`, `Folder*.swift` | The tab column, split view, Peek, spaces and folders |
| `Settings*.swift`, `SettingsIndex.swift`, `NativeActions.swift` | Settings pages, their search index, and which rows Yab's agent may change |
| `Shield*.swift`, `Curtain.swift` | The ad blocker (a compiled `WKContentRuleList`) and hidden elements (per-site selectors injected before the first frame) |
| `Vault.swift`, `Password*.swift` | Passwords in the keychain and connected password managers |
| `Extension*.swift`, `Crx.swift` | Chrome extensions on WebKit (`WKWebExtension`) and on Chromium |
| `Agent*.swift`, `Chat*.swift`, `Assistant*.swift`, `Mcp*.swift` | Agents, chats, model providers and the MCP server |
| `Mail*.swift` | Mail's windows; the engine is `MailCore` |
| `Sync*.swift` | Sync on the Mac side, over `SyncKit` |
| `Updater.swift` | Checking for and taking an update |
| `Bench*.swift` | The test socket that `./bench` drives |
| `Design.swift` | The app's side of `YabDesign` |

SwiftUI draws everything; AppKit covers what SwiftUI doesn't reach on macOS (the title bar, dragging the window, some hit testing). Swift 6 toolchain in Swift 5 language mode: the interface is main-thread by nature.

### Two page engines

Every tab holds an `any PageHandle` (`PageEngine.swift`), chosen per tab, per site, or by the default in Settings. App code talks to the handle, not to an engine.

- **WebKit** (`WebKitPage.swift`, `PageView.swift`): `WKWebView`, one content process per page. Built lazily, so a restored tab costs nothing until it is shown.
- **Chromium** (`ChromiumPage*.swift`, `Chromium*.swift`), Apple silicon only: pages live in **YabCore**, a separate helper process built on CEF. YabCore owns Chrome's views in invisible windows and hands their compositor layers to the app, which shows them with `CALayerHost`. App and helper talk JSON over a Unix socket (`YabCore/README.md`, "Wire version 1"). One helper serves every Chromium tab; each space has its own CEF request context.

Features written only for WebKit go through `Tab.webKitOnly` (`WebKitOnly.swift`) and do nothing on a Chromium tab; [chromium-webkit-only.md](chromium-webkit-only.md) lists them. Giving one a Chromium path means adding the operation to `ChromiumPage` and YabCore.

The released app bundles a CEF build with Yab's patches (`YabCore/cef-patches`). Contributors build against the official CEF distribution; see [CONTRIBUTING.md](../CONTRIBUTING.md#chromium-tabs-optional-apple-silicon).

More: [page-engine.md](page-engine.md), [chromium-tabs.md](chromium-tabs.md), [cef-packaging.md](cef-packaging.md).

### Page scripts

`Resources/PageScripts/*.js` are the scripts Yab puts into pages: forms and passkeys, dark pages, reading mode, the JSON viewer, the extension shims that add Chrome APIs WebKit lacks, the DevTools bridge. They are loaded by the Swift file of the same concern (search the source for the file name). Many run in a separate content world (`WKContentWorld`), out of the page's reach. Treat anything a page sends back as untrusted input.

## Yab for iPhone

`Phone/` is a separate Xcode project generated from `Phone/project.yml`. Pages are `WKWebView`. It shares `SyncKit` with the Mac, so tabs, spaces, bookmarks and chats sync through the same records. Folders under `Phone/Sources` follow the screens: `Field`, `Tabs`, `Chats`, `Settings`, `Sync`, `Welcome`. Rules for working there: [Phone/AGENTS.md](../Phone/AGENTS.md).

## Sync

Each device seals its records with a key only your devices hold (iCloud Keychain carries it between Macs; pairing carries it to a phone). `sync-server/` stores the sealed boxes under names it can't read and relays changes over a WebSocket. The protocol: [sync.md](sync.md).

## Where tests live

- `Tests/FastTests`: one file per area, Swift Testing. Pure logic is tested on fixed inputs. Tests that need windows ask `TestScreen` for a screen and skip without one.
- `Tests/MailCoreTests`: the mail engine alone.
- `YabCore/tests`, `YabCore/Client/Tests`: the helper and its wire.
- `Phone/Tests`, `Phone/UITests`: the iPhone app.
- `evals/`: end-to-end probes that drive a built app through `./bench`; most need a screen and run on the maintainers' Macs.

How much proof a change needs: [CONTRIBUTING.md](../CONTRIBUTING.md#making-a-change).
