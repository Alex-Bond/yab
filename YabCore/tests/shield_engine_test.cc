// The matcher on its own: `shield_engine_test RULES` reads tab-separated
// checks from stdin, "<url>\t<page host>\t<kind>\t<top>", and answers each
// with B, A (spared by an exception) or - on stdout; with no stdin, the
// built-in cases below run.
#include "../src/shield_engine.h"

#include <chrono>
#include <cstdio>
#include <iostream>

using namespace shield;

static int failures = 0;
static void Expect(bool got, bool wanted, const char* what) {
  if (got == wanted) return;
  failures++;
  fprintf(stderr, "FAIL %s: got %d\n", what, got);
}

static void Fixed() {
  Engine e;
  std::string rules = "YABSHIELD1\n";
  auto n = [&](const char* group, int kinds, int flags, const char* domains, const char* pattern) {
    rules += std::string("N\t") + group + "\t" + std::to_string(kinds) + "\t" + std::to_string(flags) + "\t" + domains + "\t" + pattern + "\n";
  };
  n("block", 0, kHost, "", "ads.example.com\x01");
  n("block", kScript, kHost | kThirdParty, "", "tracker.net\x01");
  n("block", kImage, 0, "", "/banners/*.gif");
  n("block", 0, 0, "", "/adv^");
  n("block", 0, kStart, "", "https://exact.test/x");
  n("block", 0, kEnd, "", ".swf");
  n("block", kScript, 0, "only.com", "/widget.js");
  n("block", kScript, 0, "~spared.com", "/everywhere.js");
  n("block", 0, kCase, "", "/CaseOnly/");
  n("allow", kScript, kHost, "", "tracker.net/ok.js");
  n("allow", 0, 0, "friend.com", "");
  n("important", kImage, 0, "", "/never.png");
  n("allow", kImage, 0, "", "/never.png");
  n("block", 0, kHost, "", "gone.test\x02");
  n("block", kPopup, kHost, "", "popunder.test\x01");
  rules += "H\texample.org\t.banner\nG\t.ad-slot\nG\tdiv[id^=\"ad-\"]\nS\tspare.com\t.sometimes\nU\t1\t\tnohide.test\x02\n";
  if (!e.Read(rules)) { failures++; return; }
  auto check = [&](const char* url, const char* page, int kind, bool wanted) {
    Request r{url, page, static_cast<uint16_t>(kind), false};
    Expect(e.Blocks(r), wanted, url);
  };
  check("https://ads.example.com/a.js", "site.com", kScript, true);
  check("https://x.ads.example.com/a.js", "site.com", kScript, true);
  check("https://badads.example.com/a.js", "site.com", kScript, false);
  check("https://ads.example.com.evil.net/a.js", "site.com", kScript, false);
  check("https://cdn.tracker.net/t.js", "site.com", kScript, true);
  check("https://cdn.tracker.net/t.js", "www.tracker.net", kScript, false);
  check("https://cdn.tracker.net/t.gif", "site.com", kImage, false);
  check("https://cdn.tracker.net/ok.js", "site.com", kScript, false);
  check("https://a.com/banners/one/two.gif", "a.com", kImage, true);
  check("https://a.com/banners/one/two.gif", "a.com", kScript, false);
  check("https://a.com/adv/x", "a.com", kImage, true);
  check("https://a.com/adv", "a.com", kImage, false);
  check("https://a.com/adventure", "a.com", kImage, false);
  check("https://exact.test/x/y", "a.com", kImage, true);
  check("http://b.com/https://exact.test/x", "a.com", kImage, false);
  check("https://a.com/movie.swf", "a.com", kOther, true);
  check("https://a.com/movie.swf?x", "a.com", kOther, false);
  check("https://a.com/widget.js", "only.com", kScript, true);
  check("https://a.com/widget.js", "www.only.com", kScript, true);
  check("https://a.com/widget.js", "other.com", kScript, false);
  check("https://a.com/everywhere.js", "other.com", kScript, true);
  check("https://a.com/everywhere.js", "spared.com", kScript, false);
  check("https://a.com/CaseOnly/x", "a.com", kImage, true);
  check("https://a.com/caseonly/x", "a.com", kImage, false);
  check("https://ads.example.com/a.js", "friend.com", kScript, false);
  check("https://a.com/never.png", "a.com", kImage, true);
  check("https://gone.test", "a.com", kImage, true);
  check("https://gone.testing/", "a.com", kImage, false);
  {
    Request page{"https://popunder.test/x", "popunder.test", kDocument, true};
    Expect(e.Blocks(page), false, "a popup rule leaves a page opened by hand");
    page.kind = kDocument | kPopup;
    Expect(e.Blocks(page), true, "a popup rule stops a popup");
  }
  Expect(e.generic_names() == ".ad-slot", true, "a plain class stands apart");
  Expect(e.generic().find("div[id^=\"ad-\"]{display:none!important}") != std::string::npos, true, "generic complex");
  Expect(e.Own("www.example.org").find(".banner") != std::string::npos, true, "own by parent domain");
  Expect(e.Own("example.org").find(".sometimes") != std::string::npos, true, "spared rule elsewhere");
  Expect(e.Own("shop.spare.com").find(".sometimes") != std::string::npos, false, "spared rule on the site");
  Expect(e.GenericOff("https://nohide.test/page", "nohide.test"), true, "generic off");
  Expect(e.GenericOff("https://other.test/page", "other.test"), false, "generic on");
  Expect(Site("a.b.example.co.uk") == "example.co.uk", true, "site under a public suffix");
  Expect(Site("www.example.com") == "example.com", true, "site");
  Expect(Site("127.0.0.1") == "127.0.0.1", true, "site of an address");
}

int main(int argc, char** argv) {
  Fixed();
  if (failures) { fprintf(stderr, "%d failed\n", failures); return 1; }
  if (argc < 2) { puts("ok"); return 0; }
  Engine engine;
  auto t0 = std::chrono::steady_clock::now();
  if (!engine.Load(argv[1])) { fprintf(stderr, "no rules\n"); return 1; }
  auto t1 = std::chrono::steady_clock::now();
  fprintf(stderr, "load_ms %.1f rules %zu tokenless %zu own_sites %zu generic_bytes %zu\n",
          std::chrono::duration<double, std::milli>(t1 - t0).count(), engine.rules(), engine.tokenless(), engine.own_sites(), engine.generic().size());
  std::string line;
  double spent = 0; size_t looks = 0, longest = 0;
  while (std::getline(std::cin, line)) {
    std::vector<std::string> parts;
    size_t at = 0;
    for (;;) { size_t end = line.find('\t', at); parts.push_back(line.substr(at, end == line.npos ? end : end - at)); if (end == line.npos) break; at = end + 1; }
    if (parts.size() != 4) continue;
    Request r{parts[0], parts[1], static_cast<uint16_t>(std::stoi(parts[2])), parts[3] == "1"};
    bool spared = false;
    auto a = std::chrono::steady_clock::now();
    bool blocked = engine.Blocks(r, &spared);
    auto b = std::chrono::steady_clock::now();
    double us = std::chrono::duration<double, std::micro>(b - a).count();
    spent += us; looks++; longest = std::max(longest, static_cast<size_t>(us));
    puts(blocked ? "B" : spared ? "A" : "-");
  }
  if (looks) fprintf(stderr, "look_us_mean %.2f worst %zu over %zu\n", spent / looks, longest, looks);
  return 0;
}
