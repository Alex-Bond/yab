// Runs the extension's readers against a Yab data folder, outside Raycast:
// history (with page text), bookmarks, downloads, spaces, snippets, and the
// parsers of `yab mcp` replies. Read-only. YAB_BUNDLE=dev.serafim.fast.dev
// reads Yab Dev's folder.
//   npm run smoke [-- words to search]
import { build } from "esbuild";
import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(mkdtempSync(join(tmpdir(), "yab-raycast-")), "smoke.cjs");
await build({
  stdin: {
    contents: `export * from "./src/data"; export * as parse from "./src/parse";`,
    resolveDir: join(here, ".."),
    loader: "ts",
  },
  bundle: true,
  platform: "node",
  format: "cjs",
  outfile: out,
  alias: { "@raycast/api": join(here, "raycast-stub.mjs") },
  logLevel: "error",
});
const m = await import(out);
const words = process.argv.slice(2).join(" ") || "the";
let failed = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
  if (!ok) failed++;
};

console.log(`data: ${m.dataDir()}`);
const spaces = m.spaceInfos();
check("spaces", spaces.length > 0, spaces.map((s) => `${s.icon} ${s.name} #${s.color ?? "-"}`).join(", "));

let t = Date.now();
const recent = await m.searchHistory("", { limit: 5 });
check("history, newest", recent.length > 0, `${recent.length} in ${Date.now() - t} ms; ${recent[0]?.title}`);
t = Date.now();
const found = await m.searchHistory(words, { limit: 50 });
const inPage = found.filter((p) => p.inPage);
check(`history "${words}"`, found.length > 0, `${found.length} (${inPage.length} in the page) in ${Date.now() - t} ms`);
if (inPage[0]) console.log(`     passage: ${inPage[0].passage?.replace(/[⟦⟧]/g, "*").slice(0, 140)}`);
const week = await m.searchHistory(words, { since: Date.now() / 1000 - 7 * 86400 });
check("history this week", week.every((p) => p.last >= Date.now() / 1000 - 7 * 86400), `${week.length}`);
const pictures = recent.filter((p) => m.pictureFile(p.key)).length;
check("page pictures", true, `${pictures} of ${recent.length} recent pages have one`);
const icons = recent.filter((p) => m.faviconFile(p.url)).length;
check("favicons from Yab", true, `${icons} of ${recent.length}`);

const marks = m.bookmarks();
check("bookmarks", true, `${marks.length}${marks[0] ? `; ${marks[0].title} in ${marks[0].path.join(" › ") || "the bar"}` : ""}`);
const got = m.downloads();
check("downloads", true, `${got.length}, ${got.filter((d) => d.exists).length} still there; newest ${got[0]?.date?.toLocaleString()}`);
check("download dates are real", got.every((d) => !d.date || d.date.getFullYear() >= 2020));
check("snippets", true, `${m.snippets().length}`);

check("addresses", m.looksLikeAddress("github.com/x") && !m.looksLikeAddress("hello world") && !m.looksLikeAddress("todo"));
check("search url", (await m.searchURL("a b")).includes("a%20b"));

const mail = m.parse.mailHits("[me@x.com|1a2b] Anna · Lunch? · are you free · today · labels: To respond, Inbox");
check("mail lines", mail[0]?.subject === "Lunch?" && mail[0].labels.length === 2 && mail[0].when === "today", JSON.stringify(mail[0]));
const files = m.parse.fileHits("1. a.pdf · Downloaded from x.com · Oct 24, 2026 · 1 MB\n   id: /tmp/a.pdf\n   path: /tmp/a.pdf");
check("file lines", files[0]?.path === "/tmp/a.pdf");
const subs = m.parse.purchases("2 subscriptions, $30 a month.\n- Slack: $26.25 a month, renews Oct 25 · slack.com · mail me@x.com|1a");
check("purchase lines", subs.items[0]?.site === "slack.com" && subs.items[0].mail === "me@x.com|1a" && subs.summary.startsWith("2"));
const rows = m.parse.sessions("6a077e  attached  dots  \n79bcca  done  Ideas  The user has this page open");
check("session lines", rows.length === 2 && rows[1].title === "Ideas");

process.exit(failed ? 1 : 0);
