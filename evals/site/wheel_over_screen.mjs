// Does the mouse wheel over the home page's demo screens scroll the page?
// Loads the live site in WebKit and Chromium, wheels over each screen and
// beside it, and tries two fixes in place: a shield over a locked screen,
// and the pages inside without overscroll-behavior:none.
import { createRequire } from "module";
const require = createRequire(process.env.PW_DIR + "/");
const { webkit, chromium } = require("playwright");
const FIX = {
  as_is: async () => {},
  shield: async (p) => p.addStyleTag({ content: ".scr.locked::after{content:'';position:absolute;inset:0;z-index:1000;pointer-events:auto}" }),
  no_overscroll: async (p) => p.evaluate(() => document.querySelectorAll("iframe").forEach((f) => { try { const d = f.contentDocument; const s = d.createElement("style"); s.textContent = "html,body{overscroll-behavior:auto!important}"; d.head.appendChild(s); } catch {} })),
};
for (const [name, bt] of [["webkit", webkit], ["chromium", chromium]]) {
  for (const [fix, apply] of Object.entries(FIX)) {
    const b = await bt.launch();
    const p = await b.newPage({ viewport: { width: 1440, height: 900 } });
    await p.goto(process.env.URL || "https://yetanotherbrowser.com/", { waitUntil: "load" });
    await p.waitForTimeout(2500);
    for (const id of ["g1", "g2", "g3"]) {
      await p.evaluate((id) => document.getElementById(id).scrollIntoView({ block: "center" }), id);
      await p.waitForTimeout(1500);
      await apply(p);
      const r = await p.evaluate((id) => { const b = document.getElementById(id).getBoundingClientRect(); return { x: b.x + b.width * 0.6, y: b.y + b.height / 2, y0: scrollY }; }, id);
      await p.mouse.move(r.x, r.y);
      for (let i = 0; i < 6; i++) { await p.mouse.wheel(0, 100); await p.waitForTimeout(60); }
      await p.waitForTimeout(700);
      const y1 = await p.evaluate(() => scrollY);
      await p.mouse.move(30, 450);
      for (let i = 0; i < 6; i++) { await p.mouse.wheel(0, 100); await p.waitForTimeout(60); }
      await p.waitForTimeout(700);
      const y2 = await p.evaluate(() => scrollY);
      console.log(name.padEnd(9), fix.padEnd(14), id, "over screen", Math.round(y1 - r.y0), "beside", Math.round(y2 - y1));
    }
    await b.close();
  }
}
