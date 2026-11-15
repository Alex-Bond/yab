The app ships an offline CodeMirror 6 editor and axe-core engine. No CDN is
contacted when opening DevTools or running an accessibility audit.

Rebuild after editing `editor.js`:

```sh
cd scripts/devtools
npm ci
npm run build
```

The pinned versions are in `package-lock.json`. Third-party licenses are shipped
beside the compiled resources and listed in `THIRD_PARTY_NOTICES.md`.

The vendored WebKit heap analyzer includes three fixes: the final incoming-edge
sentinel includes the last node; outgoing-edge iteration advances by four fields.
GC root paths also recognize node index zero.
Run `node heap-test.cjs` to verify chain and shared-retainer graphs.
