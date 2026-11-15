"use strict";
// Only the reduced Swift converter's regex grammar enters this matcher.
globalThis.YabShield = (() => {
  const host = value => { try { const u = new URL(value); return /^(https?|wss?):$/.test(u.protocol) ? u.hostname.toLowerCase() : null; } catch (_) { return null; } };
  const atDomain = (value, domain) => value === domain || value.endsWith("." + domain);
  function requiredLiteral(pattern) {
    let best = "", current = "", groups = 0, bracket = false;
    const flush = () => { if (current.length > best.length) best = current; current = ""; };
    for (let i = 0; i < pattern.length; i++) {
      const c = pattern[i];
      if (c === "\\") { const next = pattern[++i]; if (!groups && !bracket && next) current += next; continue; }
      if (bracket) { if (c === "]") bracket = false; continue; }
      if (c === "[") { flush(); bracket = true; continue; }
      if (c === "(") { flush(); groups++; continue; }
      if (c === ")") { groups = Math.max(0, groups - 1); continue; }
      if (groups) continue;
      if (".*+?^$|".includes(c)) flush(); else current += c;
    }
    flush(); return best.toLowerCase();
  }
  function compile(rule) {
    if (!rule || !["block", "allow", "hide"].includes(rule.action) || typeof rule.filter !== "string" || rule.filter.length > 1024) throw Error("Invalid reduced rule");
    const regex = new RegExp(rule.filter, rule.caseSensitive ? "" : "i");
    const literal = requiredLiteral(rule.filter);
    return {...rule, regex, literal};
  }
  class Index {
    constructor(rules) {
      this.common = []; this.buckets = new Map();
      const compiled = rules.map(compile), frequency = new Map();
      const grams = text => { const keys = new Set(); for (let i = 0; i <= text.length - 4; i++) keys.add(text.slice(i, i + 4)); return keys; };
      for (const rule of compiled) for (const key of grams(rule.literal)) frequency.set(key, (frequency.get(key) || 0) + 1);
      for (const rule of compiled) {
        const keys = [...grams(rule.literal)];
        const key = keys.sort((a,b) => frequency.get(a) - frequency.get(b))[0];
        delete rule.literal;
        if (!key) this.common.push(rule);
        else { const bucket = this.buckets.get(key) || []; bucket.push(rule); this.buckets.set(key, bucket); }
      }
    }
    candidates(url) {
      const found = [...this.common], keys = new Set(), lower = url.toLowerCase();
      for (let i = 0; i <= lower.length - 4; i++) {
        const key = lower.slice(i, i + 4); if (keys.has(key)) continue; keys.add(key);
        const bucket = this.buckets.get(key); if (bucket) found.push(...bucket);
      }
      return found;
    }
  }
  const types = {main_frame:"document", sub_frame:"document", popup:"popup", stylesheet:"style-sheet", script:"script", image:"image", imageset:"image",
    font:"font", media:"media", xmlhttprequest:"fetch", websocket:"websocket", ping:"ping", beacon:"ping", object:"other", object_subrequest:"other", other:"other"};
  function matches(rule, request) {
    const pageHost = host(request.page);
    if (rule.ifDomain?.length && (!pageHost || !rule.ifDomain.some(domain => atDomain(pageHost, domain)))) return false;
    if (rule.unlessDomain?.length && pageHost && rule.unlessDomain.some(domain => atDomain(pageHost, domain))) return false;
    if (rule.types?.length && !rule.types.includes(types[request.type])) return false;
    if (rule.context && rule.context !== (request.type === "main_frame" ? "top-frame" : "child-frame")) return false;
    if (rule.party && (typeof request.thirdParty !== "boolean" || request.thirdParty !== (rule.party === "third-party"))) return false;
    return rule.regex.test(request.url);
  }
  function make(buckets) {
    const blocks = new Index(buckets.blocks.filter(rule => rule.action === "block"));
    const exceptions = new Index(buckets.exceptions); const important = new Index(buckets.important);
    const own = new Index(buckets.blocks.filter(rule => rule.action === "hide")); const generic = new Index(buckets.generic); const unhide = new Index(buckets.unhide);
    return {
      cancel(request) {
        if (important.candidates(request.url).some(rule => matches(rule, request))) return true;
        if (!blocks.candidates(request.url).some(rule => matches(rule, request))) return false;
        return !exceptions.candidates(request.url).some(rule => matches(rule, request));
      },
      selectors(page, top) {
        const request = {url:page, page:top, type:"main_frame", thirdParty:false};
        if (exceptions.candidates(page).some(rule => !rule.types?.length && matches(rule, request))) return [];
        const selectors = own.candidates(page).filter(rule => matches(rule, request)).map(rule => rule.selector);
        if (!unhide.candidates(page).some(rule => matches(rule, request))) selectors.push(...generic.candidates(page).filter(rule => matches(rule, request)).map(rule => rule.selector));
        return [...new Set(selectors.filter(value => typeof value === "string"))];
      }
    };
  }
  function enabled(policy, page, privately) {
    if (!(policy.localGlobal ?? policy.importedGlobal ?? true)) return false;
    const key = host(page)?.replace(/^www\./, ""); if (!key) return false;
    const sites = privately ? policy.privateSites : policy.publicSites;
    return sites?.[key] ?? !(policy.importedPaused || []).includes(key);
  }
  function topPage(details) {
    if (details.type === "main_frame") return details.url;
    const ancestors = details.frameAncestors;
    if (Array.isArray(ancestors) && ancestors.length) return ancestors[ancestors.length - 1].url;
    return details.frameId === 0 ? details.documentUrl : null;
  }
  function popupParty(target, page, suffix) {
    if (target === "about:blank" || target === "about:srcdoc") return false;
    const targetHost = host(target), pageHost = host(page);
    if (!targetHost || !pageHost) return undefined;
    // Native eTLD+1, including Mozilla's IP/intranet handling and private suffixes.
    const options = {allowIPAddress:true, allowPlainSuffix:true, allowUnknownSuffix:true, encoding:"punycode"};
    const left = suffix.getDomain(targetHost, options), right = suffix.getDomain(pageHost, options);
    return left && right ? left !== right : undefined;
  }
  return {make, matches, enabled, host, topPage, requiredLiteral, popupParty};
})();
