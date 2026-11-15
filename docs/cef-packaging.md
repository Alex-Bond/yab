# Opt-in CEF packaging

`YAB_CEF=1` adds CEF to the normal dev app. Without that switch, the existing
build and signing path is unchanged. CEF is embedded after the ordinary app
cache has been saved, so cached apps remain free of CEF. The default helper remains a packaging stub. The optional real YabCore
adapter and `YAB_ENGINE=chromium` switch are described in
[`chromium-tabs.md`](chromium-tabs.md).

## Inputs

Run builds through the farm:

```sh
./farm exec --low --name "CEF packaging" -- env YAB_CEF=1 bash build.sh
```

`scripts/cef/fetch.sh` obtains the pinned official macOS arm64 minimal
`156.0.14+g4fa4ab5+chromium-156.0.8078.48` distribution from
[the publisher's index](https://cef-builds.spotifycdn.com/index.json).
It verifies the published archive SHA-1 before extraction and again on cache
reuse: `7359a9d293dd5c480bec3f18b762731b483b0e13`. A file lock serializes
fetches. Archives and verified extractions live in
`~/.local/state/yab-spike-cef`, overridden by `YAB_CEF_CACHE`.

- `YAB_CEF_DIR`: an already fetched distribution, bypassing the download.
  Explicit paths are trusted inputs; embedding checks CEF major and architecture.
- `YAB_CEF_HELPER`: the executable arm64 YabCore host. Otherwise the build
  compiles `helper-stub.c`, which loads bundled CEF and prints its major version.
- `YAB_SIGN_IDENTITY` and `YAB_SIGN_KEYCHAIN`: existing build settings.
  The embedder uses the identity selected and unlocked by `build.sh`, including
  its ad-hoc fallback when Developer ID is unavailable.
- The CEF payload and YabCore remain arm64-only. The parent may also carry
  an Intel WebKit slice. See [the private R1 candidate](chromium-release-r1.md)
  for universal release-mode assembly and the hidden opt-in.

For a built app, inside a farm job:

```sh
bash scripts/cef/embed.sh "/path/Yab.app" "/path/cef-distribution" \
  "/path/YabCore" "$YAB_SIGN_IDENTITY" yab.entitlements
```

The optional last argument is the parent's entitlement plist; pass the build's
profile-derived plist when applicable. Standalone embedding requires an unlocked
signing keychain. Explicit `-` selects ad-hoc signing. It does not manage credentials.

## Bundle and signing

`Contents/Frameworks/` receives `Chromium Embedded Framework.framework` and
five apps: `YabCore Helper`, `(GPU)`, `(Renderer)`, `(Plugin)` and `(Alerts)`.
Executable names match their apps. Bundle ids derive from the parent:
`.helper`, `.helper.gpu`, `.helper.renderer`, `.helper.plugin`, `.helper.alerts`.
Versions and minimum macOS version come from the parent. The real YabCore host
configures these subprocess paths explicitly; the main executable remains `yab`.
All helpers are LSUIElement apps. Alerts also carries `NSUserNotificationAlertStyle=alert`,
following Chromium's [alert plist](https://chromium.googlesource.com/chromium/src/+/156.0.8078.48/chrome/app/helper-alerts-Info.plist).

Signing proceeds inside out: framework Mach-O leaves, framework, helpers,
existing Dock tile plug-in, updater, parent. Every signature enables hardened
runtime; Developer ID signatures request a timestamp. GPU and Renderer receive
only `com.apple.security.cs.allow-jit`, matching the pinned Chromium
[GPU](https://chromium.googlesource.com/chromium/src/+/156.0.8078.48/chrome/app/helper-gpu-entitlements.plist)
and [renderer](https://chromium.googlesource.com/chromium/src/+/156.0.8078.48/chrome/app/helper-renderer-entitlements.plist)
entitlements. Other helpers have empty entitlements. No helper inherits the
parent's restricted entitlements or receives `disable-library-validation`.
`--deep` is used only for verification, never signing. Embedding replaces only
its named payload and preserves framework resources, locales and version symlinks.
The distribution's top-level `LICENSE.txt` is copied to `Contents/Resources/CEF-LICENSE.txt`
and sealed by the parent signature.

## Verification

```sh
./farm exec --low --display --name "CEF packaging" --estimate 600 --timeout 4800 -- \
  python3 -u scripts/cef/verify.py
```

The check records ordinary and CEF app sizes, initial dev build time, warm
plain/CEF build times from the same app cache, and fetch/extraction time.
It verifies `codesign --verify --deep --strict`, runtime flags and role-specific
entitlements, starts all five helpers and requires each to load CEF 156, then
launches the exact signed app through LaunchServices in a fresh synthetic
`YAB_PROBE` world. A bench response is required; the app is closed afterward.
No probe re-signing, real profile or credentials are used. Timings are wall-clock
observations; the initial build can be cold and exceed the warm estimate.

On a busy display queue, use a job without `--display` running
`verify.py --package-only`, then a short display job on the same worker running
`verify.py --launch-app "/exact/previous/out/CEF packaging.app"`. Use the same
task name. The second job reads the first summary and copies the sealed app
without rebuilding or re-signing it. The named app, `summary.json` and browser
log go to `$YAB_FARM_OUT`.

`spctl` and `codesign --check-notarization` results are recorded separately.
Unnotarized Developer ID code is expected to fail Gatekeeper assessment.
This track performs no notarization or release and changes no release scripts.
The default helper is a packaging stub, without `CefExecuteProcess`, Chromium
sandboxing, IPC or browsing; helper framework loading does not validate those.
