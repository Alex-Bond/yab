// Shield's lists for Chromium pages: the same rules Filters makes for WebKit,
// matched here because a Chromium request never passes a WKContentRuleList.
// Plain C++ with no CEF in it, so the matcher is tested on its own.
//
// Every request is looked up by the tokens of its address, a rule by its
// rarest token, the way uBlock Origin and adblock-rust do: a look costs a few
// short buckets, not 130 000 patterns.
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace shield {

enum Kind : uint16_t {
  kScript = 1, kImage = 2, kStyle = 4, kFont = 8, kMedia = 16, kFetch = 32,
  kSocket = 64, kPing = 128, kOther = 256, kDocument = 512, kPopup = 1024,
};

enum Flag : uint8_t {
  kHost = 1,          // ||host: from any label of the address's host
  kStart = 2,         // |: from the address's first byte
  kEnd = 4,           // |: to its last
  kCase = 8,          // $match-case
  kFirstParty = 16,
  kThirdParty = 32,
  kTopFrame = 64,
  kChildFrame = 128,
};

// What a pattern holds beside literal bytes (ShieldChromium.swift writes them).
constexpr char kAny = '*';            // .*
constexpr char kSeparator = '^';      // [^a-zA-Z0-9_.%-]
constexpr char kPathOrPort = '\x01';  // [/:]
constexpr char kSeparatorOrEnd = '\x02';  // ([^a-zA-Z0-9_.%-].*)?$
constexpr char kOptionalSeparator = '\x03';  // [^a-zA-Z0-9_.%-]?$

inline bool IsSeparator(char c) {
  unsigned char b = static_cast<unsigned char>(c);
  bool word = (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') ||
      b == '_' || b == '.' || b == '%' || b == '-';
  return !word;
}
inline bool IsWord(char c) {
  unsigned char b = static_cast<unsigned char>(c);
  return (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || (b >= 'A' && b <= 'Z');
}
inline char Lower(char c) { return c >= 'A' && c <= 'Z' ? static_cast<char>(c + 32) : c; }
inline uint32_t Hash(std::string_view s) {
  uint32_t h = 2166136261u;
  for (char c : s) { h ^= static_cast<unsigned char>(c); h *= 16777619u; }
  return h;
}
inline bool OnDomain(std::string_view host, std::string_view domain) {
  if (host.size() < domain.size() || host.compare(host.size() - domain.size(), domain.size(), domain) != 0) return false;
  return host.size() == domain.size() || host[host.size() - domain.size() - 1] == '.';
}

// Enough of the public suffix list for "is this the same site": WebKit's
// load-type asks the same question of the full list. A two-label suffix not
// named here counts its second label as the site, which only makes a
// third-party rule see a first party a little more often.
inline std::string_view Site(std::string_view host) {
  static const std::unordered_set<std::string_view> two = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
    "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "net.nz", "org.nz", "co.kr", "or.kr", "ne.kr",
    "co.in", "net.in", "org.in", "com.br", "net.br", "org.br", "com.cn", "net.cn", "org.cn", "gov.cn", "com.tw",
    "org.tw", "com.hk", "org.hk", "com.sg", "com.my", "co.id", "co.th", "co.il", "co.za", "com.mx", "com.ar",
    "com.tr", "com.ua", "com.ru", "com.pl", "com.sa", "com.eg", "co.ve", "github.io", "gitlab.io", "pages.dev",
    "vercel.app", "netlify.app", "herokuapp.com", "web.app", "firebaseapp.com", "blogspot.com", "cloudfront.net",
    "azurewebsites.net", "workers.dev", "s3.amazonaws.com",
  };
  if (host.empty() || (host.back() >= '0' && host.back() <= '9') || host.find(':') != host.npos) return host;
  size_t last = host.rfind('.');
  if (last == host.npos || last == 0) return host;
  size_t second = host.rfind('.', last - 1);
  if (second == host.npos) return host;
  std::string_view tail = host.substr(second + 1);
  if (two.count(tail)) {
    if (second == 0) return host;
    size_t third = host.rfind('.', second - 1);
    return third == host.npos ? host : host.substr(third + 1);
  }
  return tail;
}

struct Request {
  std::string_view url;         // as sent; scheme and host in lowercase
  std::string_view page_host;   // the top document's host
  uint16_t kind = kOther;
  bool top = false;             // this load is the top document
};

class Engine {
 public:
  struct Rule {
    uint32_t pattern = 0, length = 0;
    uint32_t domains = 0;   // an index into domains_, 0 for none
    uint16_t kinds = 0;     // 0 for every kind
    uint8_t flags = 0;
    bool unless = false;    // the domains are spared, not named
  };

  // One line a rule, written by ShieldChromium.swift:
  //   N <block|allow|important> <kinds> <flags> <if|unless:domains> <pattern>
  //   H <site> <selector>          a site's own hiding
  //   G <selector>                 hiding for every site
  //   S <domains> <selector>       hiding for every site but those
  //   U <flags> <domains> <pattern>  an address with generic hiding off
  bool Load(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return Read(text);
  }

  bool Read(std::string_view text) {
    domains_.assign(1, {});
    size_t at = 0;
    if (!text.starts_with("YABSHIELD1\n")) return false;
    at = strlen("YABSHIELD1\n");
    while (at < text.size()) {
      size_t end = text.find('\n', at);
      if (end == text.npos) end = text.size();
      Line(text.substr(at, end - at));
      at = end + 1;
    }
    Index();
    return true;
  }

  // Whether this load is stopped. `allowed` says an exception spared it.
  bool Blocks(const Request& request, bool* allowed = nullptr) const {
    if (request.url.empty() || request.url.size() > 8192) return false;
    Lowered lower(request.url);
    Address address(lower.view());
    Look look{request, lower.view(), address};
    if (Find(important_, look)) return true;
    if (!Find(blocks_, look)) return false;
    if (Find(exceptions_, look)) { if (allowed) *allowed = true; return false; }
    return true;
  }

  // The rules for every site, nothing when this address turns them off: a
  // stylesheet of what takes a selector, and the plain classes and ids apart,
  // for the page to look for among its own (uBlock Origin's low-generic
  // filters). Thirteen thousand of them in a stylesheet cost every document
  // tens of milliseconds to parse for the few it ever has.
  const std::string& generic() const { return generic_css_; }
  const std::string& generic_names() const { return generic_names_; }
  bool GenericOff(std::string_view url, std::string_view host) const {
    Lowered lower(url);
    Address address(lower.view());
    Request request{url, host, kDocument, true};
    Look look{request, lower.view(), address};
    for (const Rule& rule : unhide_) if (Applies(rule, look)) return true;
    return false;
  }

  // The hiding this site asks for of itself, and the rules for every site
  // that spare a few, which stay out of the shared stylesheet.
  std::string Own(std::string_view host) const {
    std::string css;
    for (std::string_view at = host;;) {
      auto found = own_.find(std::string(at));
      if (found != own_.end()) css += found->second;
      size_t dot = at.find('.');
      if (dot == at.npos) break;
      at = at.substr(dot + 1);
    }
    for (const auto& sparing : spared_) {
      bool spare = false;
      for (const auto& domain : domains_[sparing.first]) spare = spare || OnDomain(host, domain);
      if (!spare) css += sparing.second;
    }
    return css;
  }

  size_t rules() const { return blocks_.rules.size() + exceptions_.rules.size() + important_.rules.size(); }
  size_t tokenless() const { return blocks_.any.size() + exceptions_.any.size() + important_.any.size(); }
  size_t own_sites() const { return own_.size(); }

 private:
  struct Table {
    std::vector<Rule> rules;
    std::vector<uint32_t> starts, ids, any;
    std::unordered_map<std::string, std::vector<uint32_t>> by_domain;
  };
  static constexpr uint32_t kBuckets = 1u << 18;

  class Lowered {
   public:
    explicit Lowered(std::string_view url) {
      if (url.size() <= sizeof(small_)) { for (size_t i = 0; i < url.size(); i++) small_[i] = Lower(url[i]); view_ = {small_, url.size()}; }
      else { big_.resize(url.size()); for (size_t i = 0; i < url.size(); i++) big_[i] = Lower(url[i]); view_ = big_; }
    }
    std::string_view view() const { return view_; }
   private:
    char small_[1024];
    std::string big_;
    std::string_view view_;
  };
  struct Address {
    size_t host = 0, host_end = 0;
    explicit Address(std::string_view url) {
      size_t scheme = url.find("://");
      if (scheme == url.npos) return;
      host = scheme + 3;
      host_end = url.find_first_of("/?#", host);
      if (host_end == url.npos) host_end = url.size();
      size_t at = url.rfind('@', host_end);
      if (at != url.npos && at >= host) host = at + 1;
      size_t port = url.find(':', host);
      if (port != url.npos && port < host_end) host_end = port;
    }
  };
  struct Look {
    const Request& request;
    std::string_view lower;
    const Address& address;
  };

  static std::vector<std::string_view> Split(std::string_view line) {
    std::vector<std::string_view> parts;
    size_t at = 0;
    for (;;) {
      size_t end = line.find('\t', at);
      if (end == line.npos) { parts.push_back(line.substr(at)); return parts; }
      parts.push_back(line.substr(at, end - at));
      at = end + 1;
    }
  }
  uint32_t Domains(std::string_view list) {
    if (list.empty()) return 0;
    std::vector<std::string> names;
    size_t at = 0;
    while (at <= list.size()) {
      size_t end = list.find(',', at);
      if (end == list.npos) end = list.size();
      if (end > at) names.emplace_back(list.substr(at, end - at));
      at = end + 1;
    }
    domains_.push_back(std::move(names));
    return static_cast<uint32_t>(domains_.size() - 1);
  }
  Rule Make(std::string_view pattern, unsigned kinds, unsigned flags, std::string_view domains) {
    Rule rule;
    rule.kinds = static_cast<uint16_t>(kinds);
    rule.flags = static_cast<uint8_t>(flags);
    rule.pattern = static_cast<uint32_t>(text_.size());
    rule.length = static_cast<uint32_t>(pattern.size());
    if (flags & kCase) text_.append(pattern);
    else for (char c : pattern) text_.push_back(Lower(c));
    if (!domains.empty()) {
      rule.unless = domains.front() == '~';
      rule.domains = Domains(rule.unless ? domains.substr(1) : domains);
    }
    return rule;
  }
  void Line(std::string_view line) {
    auto parts = Split(line);
    if (parts.empty() || parts[0].size() != 1) return;
    switch (parts[0][0]) {
      case 'N': {
        if (parts.size() != 6) return;
        Rule rule = Make(parts[5], Number(parts[2]), Number(parts[3]), parts[4]);
        (parts[1] == "allow" ? exceptions_ : parts[1] == "important" ? important_ : blocks_).rules.push_back(rule);
        return;
      }
      case 'H':
        if (parts.size() == 3) Add(own_[std::string(parts[1])], parts[2]);
        return;
      case 'G':
        if (parts.size() == 2) simple_or_rule(parts[1]);
        return;
      case 'S':
        if (parts.size() == 3) { std::string css; Add(css, parts[2]); spared_.push_back({Domains(parts[1]), std::move(css)}); }
        return;
      case 'U':
        if (parts.size() == 4) unhide_.push_back(Make(parts[3], 0, Number(parts[1]), parts[2]));
        return;
      default: return;
    }
  }
  static unsigned Number(std::string_view text) {
    unsigned value = 0;
    for (char c : text) value = value * 10 + static_cast<unsigned>(c - '0');
    return value;
  }
  static void Add(std::string& css, std::string_view selector) {
    css.append(selector);
    css.append("{display:none!important}\n");
  }
  void simple_or_rule(std::string_view selector) {
    bool simple = selector.size() > 1 && (selector[0] == '.' || selector[0] == '#');
    for (size_t i = 1; simple && i < selector.size(); i++) {
      char c = selector[i];
      simple = IsWord(c) || c == '-' || c == '_';
    }
    if (simple && !(selector[1] >= '0' && selector[1] <= '9')) {
      if (!generic_names_.empty()) generic_names_.push_back(' ');
      generic_names_.append(selector);
    } else Add(generic_css_, selector);
  }

  // Each candidate token of a pattern: a run of letters and digits with a
  // real edge on both sides, so a request's own run equals it.
  template <typename Take> void Tokens(const Rule& rule, Take take) const {
    std::string_view p(text_.data() + rule.pattern, rule.length);
    size_t i = 0;
    while (i < p.size()) {
      if (!IsWord(p[i])) { i++; continue; }
      size_t start = i;
      while (i < p.size() && IsWord(p[i])) i++;
      bool left = start > 0 ? p[start - 1] != kAny : (rule.flags & (kHost | kStart)) != 0;
      bool right = i < p.size() ? p[i] != kAny : (rule.flags & kEnd) != 0;
      if (left && right && i - start >= 2) {
        std::string token(p.substr(start, i - start));
        for (char& c : token) c = Lower(c);
        take(token);
      }
    }
  }
  void IndexTable(Table& table, std::unordered_map<uint32_t, uint32_t>& counts) {
    std::vector<uint32_t> buckets(table.rules.size());
    constexpr uint32_t kNone = 0xffffffffu;
    std::vector<uint32_t> sizes(kBuckets + 1, 0);
    for (uint32_t id = 0; id < table.rules.size(); id++) {
      const Rule& rule = table.rules[id];
      uint32_t best = kNone, least = kNone;
      Tokens(rule, [&](const std::string& token) {
        uint32_t hash = Hash(token), count = counts[hash];
        if (count < least) { least = count; best = hash; }
      });
      buckets[id] = best == kNone ? kNone : best & (kBuckets - 1);
      if (best != kNone) sizes[buckets[id]]++;
      else if (rule.domains && !rule.unless) {
        for (const auto& domain : domains_[rule.domains]) table.by_domain[domain].push_back(id);
      } else table.any.push_back(id);
    }
    table.starts.assign(kBuckets + 1, 0);
    for (uint32_t i = 0; i < kBuckets; i++) table.starts[i + 1] = table.starts[i] + sizes[i];
    table.ids.resize(table.starts[kBuckets]);
    std::vector<uint32_t> next(table.starts.begin(), table.starts.end() - 1);
    for (uint32_t id = 0; id < table.rules.size(); id++) if (buckets[id] != kNone) table.ids[next[buckets[id]]++] = id;
  }
  void Index() {
    std::unordered_map<uint32_t, uint32_t> counts;
    for (const Table* table : {&blocks_, &exceptions_, &important_})
      for (const Rule& rule : table->rules) Tokens(rule, [&](const std::string& token) { counts[Hash(token)]++; });
    IndexTable(blocks_, counts);
    IndexTable(exceptions_, counts);
    IndexTable(important_, counts);
  }

  // A pattern against the bytes from `at`: the classic wildcard walk, which
  // goes back only to the last *, so a rule can't blow up on a long address.
  static bool Walk(std::string_view p, std::string_view url, size_t at, bool end_anchor) {
    size_t i = 0, u = at, star = std::string_view::npos, resume = 0;
    for (;;) {
      if (i == p.size()) {
        if (!end_anchor || u == url.size()) return true;
      } else {
        char c = p[i];
        if (c == kAny) { star = ++i; resume = u; continue; }
        bool taken = false;
        switch (c) {
          case kSeparator: taken = u < url.size() && IsSeparator(url[u]); break;
          case kPathOrPort: taken = u < url.size() && (url[u] == '/' || url[u] == ':'); break;
          case kSeparatorOrEnd: if (u == url.size() || IsSeparator(url[u])) return true; break;
          case kOptionalSeparator:
            if (u == url.size() || (u + 1 == url.size() && IsSeparator(url[u]))) return true;
            break;
          default: taken = u < url.size() && url[u] == c;
        }
        if (taken) { i++; u++; continue; }
      }
      if (star == std::string_view::npos || resume >= url.size()) return false;
      i = star;
      u = ++resume;
    }
  }
  bool Pattern(const Rule& rule, const Look& look) const {
    std::string_view p(text_.data() + rule.pattern, rule.length);
    std::string_view url = rule.flags & kCase ? look.request.url : look.lower;
    bool end = rule.flags & kEnd;
    if (rule.flags & kHost) {
      std::string_view host = look.lower.substr(look.address.host, look.address.host_end - look.address.host);
      for (size_t label = 0; label < host.size();) {
        if (Walk(p, url, look.address.host + label, end)) return true;
        size_t dot = host.find('.', label);
        if (dot == host.npos) break;
        label = dot + 1;
      }
      return false;
    }
    if (rule.flags & kStart) return Walk(p, url, 0, end);
    if (p.empty()) return true;
    // An address's first byte of a literal start, or everywhere for the rest.
    char first = p[0];
    if (first == kAny || first == kSeparator || first == kPathOrPort || first == kSeparatorOrEnd || first == kOptionalSeparator) {
      for (size_t at = 0; at <= url.size(); at++) if (Walk(p, url, at, end)) return true;
      return false;
    }
    for (size_t at = url.find(first); at != url.npos; at = url.find(first, at + 1))
      if (Walk(p, url, at, end)) return true;
    return false;
  }
  bool Conditions(const Rule& rule, const Look& look) const {
    const Request& request = look.request;
    if (rule.kinds && !(rule.kinds & request.kind)) return false;
    if (rule.flags & (kTopFrame | kChildFrame)) {
      if (!(request.kind & kDocument)) return false;
      if ((rule.flags & kTopFrame) && !request.top) return false;
      if ((rule.flags & kChildFrame) && request.top) return false;
    }
    if (rule.flags & (kFirstParty | kThirdParty)) {
      std::string_view host = look.lower.substr(look.address.host, look.address.host_end - look.address.host);
      bool same = Site(host) == Site(request.page_host);
      if ((rule.flags & kFirstParty) && !same) return false;
      if ((rule.flags & kThirdParty) && same) return false;
    }
    if (rule.domains) {
      bool on = false;
      for (const auto& domain : domains_[rule.domains]) on = on || OnDomain(request.page_host, domain);
      if (on == rule.unless) return false;
    }
    return true;
  }
  bool Applies(const Rule& rule, const Look& look) const { return Conditions(rule, look) && Pattern(rule, look); }
  bool Find(const Table& table, const Look& look) const {
    if (table.rules.empty()) return false;
    for (uint32_t id : table.any) if (Applies(table.rules[id], look)) return true;
    if (!table.by_domain.empty()) {
      for (std::string_view at = look.request.page_host; !at.empty();) {
        auto found = table.by_domain.find(std::string(at));
        if (found != table.by_domain.end())
          for (uint32_t id : found->second) if (Applies(table.rules[id], look)) return true;
        size_t dot = at.find('.');
        if (dot == at.npos) break;
        at = at.substr(dot + 1);
      }
    }
    std::string_view url = look.lower;
    uint32_t seen[32];
    size_t tried = 0;
    for (size_t i = 0; i < url.size();) {
      if (!IsWord(url[i])) { i++; continue; }
      size_t start = i;
      while (i < url.size() && IsWord(url[i])) i++;
      if (i - start < 2) continue;
      uint32_t bucket = Hash(url.substr(start, i - start)) & (kBuckets - 1);
      // The same token twice in an address is the same bucket twice.
      bool again = false;
      for (size_t k = 0; k < tried && !again; k++) again = seen[k] == bucket;
      if (again) continue;
      if (tried < 32) seen[tried++] = bucket;
      for (uint32_t k = table.starts[bucket]; k < table.starts[bucket + 1]; k++)
        if (Applies(table.rules[table.ids[k]], look)) return true;
    }
    return false;
  }

  std::string text_;
  Table blocks_, exceptions_, important_;
  std::vector<Rule> unhide_;
  std::vector<std::vector<std::string>> domains_;
  std::unordered_map<std::string, std::string> own_;
  std::vector<std::pair<uint32_t, std::string>> spared_;
  std::string generic_css_, generic_names_;
};

}  // namespace shield
