# WebKit bug: restoring a page from the back-forward cache asks the UI process for every history entry, synchronously

A write-up to file at bugs.webkit.org (component: WebKit2 / History),
from Yab's measurements of 2026-10-13 (docs/evidence/clean-gap-2026-10-13.md,
round 4).

## Summary

When a page comes back from the back-forward cache, the WebContent process
restores the Navigation API's entries with one synchronous IPC per history
entry to the UI process. Each waits for the UI process's main thread. A
Back that WebKit could finish in a few milliseconds takes as long as the
UI process's main thread takes to answer all of them, and grows with the
length of the tab's history.

## Where

Sampled in the WebContent process during Back and Forward between two
pages in the back-forward cache (macOS 26.4, Apple Silicon):

```
FrameLoader::loadProvisionalItemFromCachedPage()
  FrameLoader::commitProvisionalLoad()
    CachedPage::restore(Page&)
      CachedPage::restoreNavigationAPIHistoryItems(LocalFrame&, BackForwardController*)
        WebBackForwardListProxy::itemAtIndex(int, FrameIdentifier)   <- sendSyncMessage, per entry
        WebBackForwardListProxy::allItems(FrameIdentifier)           <- sendSyncMessage
          IPC::Connection::waitForSyncReply
```

In 16 restores, 213 of the samples (13 ms a restore) were the WebContent
process parked in `waitForSyncReply` for these. The tab had about 30
history entries. A bare WKWebView with 2 entries restored in 7 to 10 ms
(page shown, two requestAnimationFrame later); the same page in a browser
whose UI-process main thread has its own work (AppKit layout, SwiftUI) at
that moment took 60 to 85 ms.

Turning the Navigation API off (`_WKFeature` "NavigationAPIEnabled") took
15 to 18 ms off Back and Forward in a profile with a few extensions and
long histories, in three of three rounds.

## Expected

The restore shouldn't need a synchronous round trip per entry. Either the
entries the Navigation API needs are sent with the restore (they are known
to the UI process when it decides on the back-forward navigation), or
fetched in one message, or lazily when the page first reads
`navigation.entries()`.

## How to reproduce

1. A WKWebView app; load page A, then follow links through 30 pages.
2. Go back one page (history.back() or goBack) so it comes from the
   back-forward cache.
3. Sample the WebContent process: the restore waits in
   `WebBackForwardListProxy::itemAtIndex`. Keep the UI process's main
   thread busy (a 20 ms block on each run-loop turn) and the restore takes
   that much longer.

Yab's harness: `evals/stand/stand.py --scenarios bf --sample-open`
samples the WebContent process of the page in front through Back and
Forward (`sample-bf-web-PROFILE.txt`).
