import Foundation

// Reading mode: the article, and nothing that was arranged around it.
//
// The hard part is deciding what the article is: the smallest element that
// still holds most of the page's prose, prose being paragraphs less their
// links (see best()). Counting links against a whole element, as this once
// did, lost Wikipedia, whose prose is full of them, to whichever one section
// had the fewest.
//
// The page itself is never taken apart. The reader is laid over it, a sibling
// of <body> under <html>, and once it has arrived the body is only hidden, so
// leaving is the page exactly as it was: its listeners, its video, its forms,
// and the place you had reached, with no reload.
//
// Coming and going is one move played both ways. The article lifts off the
// page and settles into the reading column (FLIP: the column is laid out
// where it ends up, set back by a transform to where the article stood, and
// the transform is let go), and on the way out the column goes back into the
// article. Only transform and opacity move, so WebKit hands the animations to
// Core Animation as they are and no frame is drawn by the page or by yab's
// main thread; the one layout is taken before anything moves. While the
// reader is up it is a plain part of the document, and the window scrolls it,
// so the keys, find, the tab's reading gray and everything else that follows
// a page's scroll follow it too.
//
// It runs in yab's own world (Web.world): the page can see the elements, but
// not the controller, and can't call it.

enum Reader {
    /// Shows the article, answering "read", or "none" for a page without one.
    static let enter = script + "window.__yabReader.enter();"
    /// Puts the page back, answering "left", or nothing when this document
    /// has no reader of ours (then the only way back is to load it again).
    static let leave = "window.__yabReader ? window.__yabReader.leave() : 'gone';"
    /// Whether the page has something to read, for the door that offers it.
    static let readable = script + "window.__yabReader.readable();"
    /// X mounts its article after navigation has finished. These are async
    /// function bodies for WebKit, with a bounded wait for that document.
    static let readableWhenReady = script + "return await window.__yabReader.ready() && window.__yabReader.readable();"
    static let enterWhenReady = script + "return await window.__yabReader.ready() ? window.__yabReader.enter() : 'none';"
    /// Whether this document is showing the reader: a page brought back from
    /// the back-forward cache can still be.
    static let showing = "!!(window.__yabReader && window.__yabReader.on());"

    /// The theme and its edits, resolved (ReaderPrefs.payload): colors for
    /// day and night, the face, size and spacing. Only numbers, booleans,
    /// checked colors and the fonts' own fixed names cross into the page.
    static func configure(_ prefs: ReaderPrefs) -> String {
        let data = try! JSONEncoder().encode(prefs.payload)
        return script + "window.__yabReader.theme(" + String(decoding: data, as: UTF8.self) + ");"
    }

    private static let script = """
    (function () {
      if (window.__yabReader) return;

      var SETTLE = 'cubic-bezier(.16,1,.3,1)';
      var BACK = 'cubic-bezier(.3,0,.2,1)';
      var IN = 460, OUT = 300;

      // X Articles use Draft.js blocks, not paragraphs. Read only the full
      // article view, never a timeline card, the replies, or the composer.
      function xArticle() {
        var el = document.querySelector('[data-testid="twitterArticleReadView"]');
        if (!el) return null;
        var title = el.querySelector('[data-testid="twitter-article-title"]');
        var body = el.querySelector('[data-testid="longformRichTextComponent"], [data-testid="twitterArticleRichTextView"]');
        if (!title || !title.textContent.trim() || !body || body.textContent.trim().length < 80) return null;
        var cover = el.querySelector('[data-testid="article-cover-image"]');
        if (!cover) {
          var media = el.querySelectorAll('a[href*="/article/"][href*="/media/"] img');
          for (var i = 0; i < media.length; i++) {
            if (!body.contains(media[i])) { cover = media[i]; break; }
          }
        }
        return { el: el, title: title, body: body, cover: cover, prose: body.textContent.trim().length };
      }

      function ready() {
        var route = /(^|\\.)(?:x|twitter)\\.com$/.test(location.hostname) &&
          /^\\/[^/]+\\/(?:article|status)\\/\\d+(?:\\/|$)/.test(location.pathname);
        if (xArticle() || (!route && !document.querySelector('[data-testid="twitterArticleReadView"]'))) return Promise.resolve(true);
        return new Promise(function (resolve) {
          var url = location.href, finished = false, queued = null;
          function finish(value) {
            if (finished) return;
            finished = true;
            observer.disconnect();
            clearTimeout(deadline); clearTimeout(queued); clearInterval(navigation);
            resolve(value);
          }
          function check() {
            if (location.href !== url) finish(false);
            else if (xArticle()) finish(true);
          }
          var observer = new MutationObserver(function () {
            clearTimeout(queued);
            queued = setTimeout(check, 100);
          });
          observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
          var deadline = setTimeout(function () { finish(false); }, 8000);
          var navigation = setInterval(check, 200);
          check();
        });
      }

      // What is prose here: paragraphs, less the words that are links, and
      // none inside what is plainly around an article rather than in it: a
      // rail, a menu, comments, a cookie dialog, a teaser that is one link.
      var AROUND = /(^|\\s)(comments?|reply|replies|sidebar|related|recommend\\w*|footer|promo|newsletter|share|social|advert\\w*|sponsor\\w*)([\\s_-]|$)/i;
      function around(el) {
        for (var up = el; up && up !== document.body && up !== document.documentElement; up = up.parentElement) {
          var tag = up.tagName;
          if (tag === 'ASIDE' || tag === 'NAV' || tag === 'FOOTER' || tag === 'A' || tag === 'DIALOG') return true;
          var role = up.getAttribute('role');
          if (role === 'complementary' || role === 'navigation' || role === 'dialog' || role === 'alertdialog') return true;
          var name = (typeof up.className === 'string' ? up.className : '') + ' ' + (up.id || '');
          if (name.length > 1 && AROUND.test(name)) return true;
        }
        return false;
      }

      // One pass over the paragraphs: each counts its prose toward every
      // element it sits in. textContent never asks for a layout, so this
      // is a couple of milliseconds on a long Wikipedia article.
      function measure() {
        var paragraphs = document.getElementsByTagName('p');
        var prose = new Map(), counts = new Map(), kept = [];
        for (var i = 0; i < paragraphs.length; i++) {
          var p = paragraphs[i];
          var letters = p.textContent.trim().length;
          if (letters < 25 || around(p)) continue;
          var linked = 0, links = p.getElementsByTagName('a');
          for (var k = 0; k < links.length; k++) linked += links[k].textContent.length;
          var own = letters - linked;
          // Mostly links is a list of them, set as a paragraph.
          if (own <= letters / 3) continue;
          kept.push({ p: p, letters: letters, own: own });
          for (var up = p.parentElement; up && up !== document.documentElement; up = up.parentElement) {
            prose.set(up, (prose.get(up) || 0) + own);
            counts.set(up, (counts.get(up) || 0) + 1);
          }
        }
        return { prose: prose, counts: counts, kept: kept };
      }

      // The article: the smallest element that still holds most of the
      // page's prose. From the body down, into whichever child holds four
      // fifths of what its parent does, until none does. A long article
      // split into sections stops at the sections' parent; a page whose
      // prose is spread over a feed stops high, and shows the lot.
      function best() {
        var m = measure(), top = document.body;
        if (!top || !m.prose.get(top)) return null;
        for (;;) {
          var whole = m.prose.get(top), next = null;
          for (var c = top.firstElementChild; c; c = c.nextElementSibling) {
            if ((m.prose.get(c) || 0) >= whole * 0.8) { next = c; break; }
          }
          if (!next || (m.counts.get(next) || 0) < 2) break;
          top = next;
        }
        return { el: top, prose: m.prose.get(top), paragraphs: m.counts.get(top) };
      }

      // Worth offering: at least three paragraphs side by side, each on its
      // own (a paragraph, or a box holding only it), carrying 1200 letters
      // of prose between them, and on screen. A feed's teasers sit in cards
      // with their headlines and don't count; an article's paragraphs do.
      function readable() {
        if (now) return true;
        if (xArticle()) return true;
        var m = measure(), runs = new Map(), found = false;
        for (var i = 0; i < m.kept.length; i++) {
          var block = m.kept[i].p;
          while (block.parentElement && m.counts.get(block.parentElement) === 1) block = block.parentElement;
          if (block.textContent.length > m.kept[i].letters * 1.3 + 20) continue;
          var run = runs.get(block.parentElement) || { n: 0, prose: 0 };
          run.n++;
          run.prose += m.kept[i].own;
          runs.set(block.parentElement, run);
        }
        runs.forEach(function (run, parent) {
          if (found || run.n < 3 || run.prose < 1200) return;
          // A cookie notice's text is often there all along, hidden.
          if (parent.checkVisibility && !parent.checkVisibility()) return;
          found = true;
        });
        return found;
      }

      function still() {
        return window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
      }

      function jump(y) {
        window.scrollTo({ top: Math.max(0, y), behavior: 'instant' });
      }

      // The first of these that is on screen: where you are reading.
      function seen(list) {
        for (var i = 0; i < list.length; i++) {
          var r = list[i].getBoundingClientRect();
          if (r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < innerHeight) {
            return { el: list[i], rect: r };
          }
        }
        return null;
      }

      // The transform that puts `target` (inside the column, which is laid
      // out where it ends up) over the rectangle `over`. The column scales
      // about its own top left, so a point p from there lands on s·p + t.
      // Where an element sits in the document, not the window.
      function box(el) {
        var r = el.getBoundingClientRect();
        return { left: r.left, top: r.top + window.scrollY, width: r.width, height: r.height };
      }

      // A flight from or to somewhere off screen would cross the whole
      // window: the column only rises into place, or sinks away, instead.
      function unseen(over) {
        return !over || over.width === 0 || over.top + (over.height || 1) <= 0 || over.top >= innerHeight;
      }

      function flip(column, target, over) {
        var o = column.getBoundingClientRect(), t = target.getBoundingClientRect();
        var s = t.width > 0 && over.width > 0 ? over.width / t.width : 1;
        var x = over.left - o.left - (t.left - o.left) * s;
        var y = over.top - o.top - (t.top - o.top) * s;
        return 'translate(' + x + 'px,' + y + 'px) scale(' + s + ')';
      }

      var sheet = [
        'html.yab-reading{background:var(--yab-reader-bg,#fff) !important;color-scheme:var(--yab-reader-scheme,light) !important;margin:0 !important;padding:0 !important;',
        'overflow:visible !important;height:auto !important;min-height:0 !important;',
        'max-height:none !important;scroll-behavior:auto !important;scroll-snap-type:none !important;',
        'transform:none !important;filter:none !important}',
        'html.yab-reading > body{display:none !important}',
        '#yab-reader{position:fixed;inset:0;z-index:2147483647;overflow:hidden;visibility:hidden;',
        'margin:0;padding:0;text-align:left;color-scheme:var(--yab-reader-scheme,light)}',
        // Selection uses the same tested pair with foreground and ground
        // exchanged, so it remains legible in a custom scheme too.
        '#yab-reader ::selection{background:var(--yab-reader-ink,#171717) !important;color:var(--yab-reader-bg,#fff) !important}',
        '#yab-reader.yab-flow{position:relative;inset:auto;overflow:visible;visibility:visible;z-index:auto}',
        '#yab-reader .yab-paper{position:absolute;inset:0;background:var(--yab-reader-bg,#fff)}',
        '#yab-reader.yab-flow .yab-paper{display:none}',
        '#yab-reader .yab-later{display:none !important}',
        // The theme's face, size and spacing (themeSheet), on the column
        // and on every block of prose in it, over what the site's own
        // classes, still matching the copied elements, would give them.
        '#yab-reader .yab-column{max-width:var(--yab-w,38em);margin:0 auto;padding:72px 24px 160px;',
        'transform-origin:0 0;box-sizing:content-box;color:var(--yab-reader-ink,#171717);',
        'font-family:var(--yab-f,ui-serif,Georgia,serif);font-size:var(--yab-s,18px);line-height:var(--yab-lh,1.72);',
        'font-weight:var(--yab-wt,400);letter-spacing:var(--yab-ls,0);word-spacing:var(--yab-ws,0);text-align:var(--yab-al,left)}',
        '#yab-reader .yab-column :is(p,li,blockquote,dd,dt,div,section,article,span,a,em,i,u,small,sup,sub,cite,q,mark):not(.yab-from){',
        'font-family:inherit !important;letter-spacing:inherit !important;word-spacing:inherit !important}',
        '#yab-reader .yab-column :is(p,li,blockquote,dd,dt,div,section,article):not(.yab-from){font-size:inherit !important;',
        'line-height:inherit !important;font-weight:inherit !important;text-align:inherit !important}',
        '#yab-reader .yab-just :is(p,li,blockquote){hyphens:auto;-webkit-hyphens:auto}',
        '#yab-reader h1{font:700 calc(var(--yab-s,18px) * 1.6)/1.18 var(--yab-f,ui-serif,Georgia,serif);',
        'margin:0 0 24px;letter-spacing:-0.015em;color:inherit;text-align:left}',
        '#yab-reader .yab-from{font:500 13px/1.4 -apple-system,sans-serif;color:inherit;opacity:.6;',
        'margin:0 0 8px;letter-spacing:0;text-align:left}',
        '#yab-reader p{margin:0 0 1.35em}',
        '#yab-reader img,#yab-reader video,#yab-reader iframe{max-width:100%;',
        'height:auto;border-radius:6px;margin:1.6em 0;display:block}',
        '#yab-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}',
        '#yab-reader figure{margin:1.8em 0}',
        '#yab-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;',
        'color:inherit;margin-top:.6em}',
        '#yab-reader .yab-column *{color:inherit !important;background-color:transparent !important;-webkit-text-fill-color:currentColor !important}',
        '#yab-reader a{color:inherit !important;text-decoration:underline !important;text-underline-offset:3px}',
        '#yab-reader a:focus-visible{outline:2px solid currentColor;outline-offset:3px}',
        '#yab-reader h2,#yab-reader h3{font:700 1.2em/1.3 var(--yab-f,ui-serif,Georgia,serif);',
        'letter-spacing:-0.01em;margin:2em 0 .6em;text-align:left}',
        '#yab-reader pre,#yab-reader code{font-family:ui-monospace,monospace;font-size:14px}',
        '#yab-reader pre{border:1px solid currentColor;padding:14px;border-radius:8px;overflow:auto}',
        '#yab-reader blockquote{margin:1.6em 0;padding-left:1.2em;',
        'border-left:2px solid currentColor;color:inherit}'
      ].join('');

      // The article's blocks, each numbered on the page for the moment it is
      // copied, so a block in the reader can find the one it came from.
      var BLOCKS = 'p,h1,h2,h3,h4,h5,h6,figure,img,picture,video,blockquote,pre,ul,ol,table';

      function build(article, special) {
        var originals = Array.prototype.slice.call(article.querySelectorAll(BLOCKS + (special ? ',[data-block="true"]' : '')));
        for (var i = 0; i < originals.length; i++) originals[i].setAttribute('data-yab-n', i);
        var copy;
        if (special) {
          copy = document.createElement('div');
          if (special.cover && !special.body.contains(special.cover)) copy.appendChild(special.cover.cloneNode(true));
          copy.appendChild(special.body.cloneNode(true));
          var blocks = copy.querySelectorAll('div[data-block="true"]');
          for (var b = 0; b < blocks.length; b++) {
            if (blocks[b].querySelector('img,video,iframe,ul,ol,blockquote,pre')) continue;
            var paragraph = document.createElement('p');
            paragraph.setAttribute('data-yab-n', blocks[b].getAttribute('data-yab-n'));
            while (blocks[b].firstChild) paragraph.appendChild(blocks[b].firstChild);
            blocks[b].replaceWith(paragraph);
          }
          // React's layout and colors belong to X. Keep semantic markup,
          // links, media and inline emphasis, without its flex boxes.
          var nodes = copy.querySelectorAll('*');
          for (var n = 0; n < nodes.length; n++) {
            var node = nodes[n], weight = node.style.fontWeight, italic = node.style.fontStyle;
            node.removeAttribute('class'); node.removeAttribute('id'); node.removeAttribute('style');
            node.removeAttribute('contenteditable');
            if (weight) node.style.fontWeight = weight;
            if (italic) node.style.fontStyle = italic;
          }
        } else copy = article.cloneNode(true);
        for (var j = 0; j < originals.length; j++) originals[j].removeAttribute('data-yab-n');

        // Every picture as the page resolved it. currentSrc is what the
        // browser actually chose and loaded, after srcset, sizes and
        // <picture> have had their say; copying the markup alone gets you a
        // lazy placeholder, or nothing at all.
        var late = ['data-src', 'data-original', 'data-lazy-src', 'data-lazy',
                    'data-full-src', 'data-hi-res-src', 'data-image', 'data-echo'];
        var pictures = copy.querySelectorAll('img');
        for (var p = 0; p < pictures.length; p++) {
          var picture = pictures[p];
          var source = originals[+picture.getAttribute('data-yab-n')] || picture;
          picture.setAttribute('loading', 'eager');
          var real = source.currentSrc || source.getAttribute('src') || '';
          // A one-pixel placeholder counts as nothing.
          if (!real || real.indexOf('data:image') === 0 || source.naturalWidth <= 2) {
            for (var k = 0; k < late.length; k++) {
              var kept = source.getAttribute(late[k]);
              if (kept) { real = kept; break; }
            }
          }
          if (real) picture.setAttribute('src', real);
          var lateSet = source.getAttribute('data-srcset');
          if (lateSet && !picture.getAttribute('srcset')) picture.setAttribute('srcset', lateSet);
        }

        // What was arranged around the words rather than being part of them.
        // Not header: an article's opening image lives there as often as not.
        var clutter = copy.querySelectorAll(
          'script,style,link,noscript,form,nav,aside,footer,button,input,select,textarea,' +
          '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"]'
        );
        for (var c = 0; c < clutter.length; c++) clutter[c].remove();

        // Embedded video is part of the article; every other frame is not.
        var players = /youtube|youtu\\.be|vimeo|dailymotion|loom\\.com|streamable|wistia|ted\\.com/i;
        var frames = copy.querySelectorAll('iframe');
        for (var f = 0; f < frames.length; f++) {
          var where = frames[f].getAttribute('src') || frames[f].getAttribute('data-src') || '';
          if (players.test(where)) {
            frames[f].setAttribute('src', where);
            frames[f].removeAttribute('height');
            frames[f].removeAttribute('width');
          } else {
            frames[f].remove();
          }
        }

        // A picture with nothing behind it is a broken icon, which is worse
        // than no picture at all.
        var left = copy.querySelectorAll('img');
        for (var g = 0; g < left.length; g++) {
          var src = left[g].getAttribute('src') || '';
          if (!src || src.indexOf('data:image') === 0) left[g].remove();
        }

        // Inline colors, including !important, belong to the source site's
        // ground. Media keeps its real pixels; the article uses our ink.
        var styled = copy.querySelectorAll('[style]');
        for (var s = 0; s < styled.length; s++) {
          styled[s].style.removeProperty('color');
          styled[s].style.removeProperty('background');
          styled[s].style.removeProperty('background-color');
          styled[s].style.removeProperty('-webkit-text-fill-color');
        }

        var heading = document.querySelector('h1');
        var title = document.createElement('h1');
        title.textContent = special ? special.title.textContent.trim() : (heading && heading.innerText.trim()) || document.title;
        // The article's own heading, when it is the title over it, once.
        var twice = copy.querySelector('h1');
        if (twice && twice.textContent.trim() === title.textContent) twice.remove();
        var site = document.createElement('p');
        site.className = 'yab-from';
        site.textContent = location.host.replace(/^www\\./, '');

        var column = document.createElement('div');
        column.className = 'yab-column';
        column.appendChild(site);
        column.appendChild(title);
        while (copy.firstChild) column.appendChild(copy.firstChild);

        var paper = document.createElement('div');
        paper.className = 'yab-paper';
        var holder = document.createElement('div');
        holder.className = 'yab-sheet';
        holder.appendChild(column);
        var host = document.createElement('div');
        host.id = 'yab-reader';
        host.appendChild(paper);
        host.appendChild(holder);

        var style = document.createElement('style');
        style.textContent = sheet + themeSheet();
        return { host: host, style: style, paper: paper, holder: holder, column: column, originals: originals };
      }

      // A reader, and what it is doing: 'entering', 'reading' or 'leaving'.
      var now = null;
      // The look Swift last sent (Reader.configure); the site's own face
      // stands in where it names none (Original).
      var look = null;
      var dark = matchMedia('(prefers-color-scheme: dark)');
      function themeSheet() {
        if (!look) return '';
        var night = look.mode === 'dark' || (look.mode === 'auto' && dark.matches);
        var g = night ? look.night : look.day;
        return 'html.yab-reading,#yab-reader{--yab-reader-bg:' + g.bg + ';--yab-reader-ink:' + g.ink +
          ';--yab-reader-scheme:' + (g.dark ? 'dark' : 'light') +
          ';--yab-f:' + (look.font || 'ui-serif,Georgia,serif') + ';--yab-s:' + look.size + 'px;--yab-lh:' + look.line +
          ';--yab-ls:' + look.letter + 'em;--yab-ws:' + look.word + 'em;--yab-wt:' + look.weight +
          ';--yab-w:' + look.width + 'em;--yab-al:' + (look.justify ? 'justify' : 'left') + '}';
      }
      // The face the article's prose was set in on the page.
      function siteFace(article) {
        var p = article.querySelector('p') || article;
        return getComputedStyle(p).fontFamily || '';
      }
      function dress() {
        if (!now) return;
        now.style.textContent = sheet + themeSheet();
        // Set inline, so the site's own name for its face is a value and
        // never part of the sheet's text.
        if (look && !look.font && now.face) now.host.style.setProperty('--yab-f', now.face);
        else now.host.style.removeProperty('--yab-f');
        now.column.classList.toggle('yab-just', !!(look && look.justify));
      }
      function theme(value) {
        look = value;
        dress();
      }
      dark.addEventListener('change', function () { if (now && look && look.mode === 'auto') dress(); });

      function animate(el, frames, duration, easing, delay) {
        var a = el.animate(frames, { duration: duration, easing: easing, delay: delay || 0, fill: 'both' });
        now.flights.push(a);
        return a;
      }

      // Ends whatever is moving at its end state, at once: ⌥⌘R pressed again
      // mid-flight goes on from where the last one lands.
      function land() {
        if (!now || !now.finish) return;
        var finish = now.finish;
        now.finish = null;
        finish();
      }

      function after(finish) {
        now.finish = finish;
        var flights = now.flights.slice();
        Promise.all(flights.map(function (a) { return a.finished; })).then(function () {
          if (now && now.finish === finish) { now.finish = null; finish(); }
        }, function () {});
      }

      function stop() {
        var flights = now.flights;
        now.flights = [];
        for (var i = 0; i < flights.length; i++) flights[i].cancel();
      }

      // Only the stretch of the article around where you are is laid out
      // before the move: the whole of a long one (Wikipedia's United States,
      // twenty thousand nodes) takes a tenth of a second, which would all be
      // spent before anything moved. The rest comes in once the reader has
      // arrived and stands still (settle), the scroll made up for it.
      function defer(column, twin) {
        var kids = column.children, at = 0;
        if (twin) while (at < kids.length && !kids[at].contains(twin)) at++;
        if (at >= kids.length) at = 0;
        var start = Math.max(0, at - 2), end = at, letters = 0;
        while (end < kids.length && (letters < 12000 || end < at + 2)) {
          letters += kids[end].textContent.length;
          end++;
        }
        var later = [];
        for (var i = 0; i < kids.length; i++) {
          if (i < start || i >= end) { kids[i].classList.add('yab-later'); later.push(kids[i]); }
        }
        return later;
      }

      function enter() {
        if (now && now.phase === 'leaving') land();
        if (now) return 'read';
        var special = xArticle(), found = special || best();
        if (!found || (!special && found.prose < 400)) return 'none';
        var article = found.el;

        var parts = build(article, special);

        // Open where you are, read off the page as it stands, before anything
        // is added to it. With the article's start on screen the whole column
        // rises from it; scrolled into the middle, the reader opens at the
        // paragraph you were at, set at the same height, so it only moves
        // across into the column.
        var whole = article.getBoundingClientRect();
        var here = whole.top < 0 ? seen(parts.originals) : null;
        var twin = here && parts.column.querySelector('[data-yab-n="' + parts.originals.indexOf(here.el) + '"]');
        now = {
          phase: 'entering', flights: [], finish: null, article: article,
          host: parts.host, style: parts.style, paper: parts.paper, holder: parts.holder,
          column: parts.column, originals: parts.originals, pageY: window.scrollY,
          // The page as it is laid out now, which is how it will be laid out
          // again as long as the window keeps its width: leaving can then
          // start moving before the page has been laid out again, which on
          // a long page takes most of a tenth of a second.
          width: innerWidth, boxes: parts.originals.map(box), box: box(article),
          most: Math.max(0, document.documentElement.scrollHeight - innerHeight),
          later: defer(parts.column, twin), ref: twin || parts.column
        };
        now.face = siteFace(article);
        dress();
        var root = document.documentElement;
        root.appendChild(parts.style);
        root.appendChild(parts.host);
        if (document.activeElement && document.activeElement.blur) document.activeElement.blur();

        var target = parts.column, over = whole, y = 0;
        if (twin) {
          var most = Math.max(0, parts.holder.offsetHeight - innerHeight);
          y = Math.min(most, Math.max(0, twin.getBoundingClientRect().top - here.rect.top));
          target = twin;
          over = here.rect;
        }
        now.y = y;
        parts.holder.style.transform = 'translateY(' + (-y) + 'px)';
        var from = unseen(over) ? 'translateY(28px)' : flip(parts.column, target, over);

        // Pictures on the first screen are decoded before anything moves, so
        // none of them arrives halfway through; a slow one isn't waited for.
        var first = Array.prototype.filter.call(parts.column.querySelectorAll('img'), function (img) {
          var r = img.getBoundingClientRect();
          return r.top < innerHeight && r.bottom > 0 && img.decode;
        });
        var ready = Promise.race([
          Promise.all(first.map(function (img) { return img.decode().catch(function () {}); })),
          new Promise(function (done) { setTimeout(done, 120); })
        ]);
        var mine = now;
        now.finish = function () { settle(); };
        ready.then(function () {
          if (now !== mine || now.phase !== 'entering' || !now.finish) return;
          fly(from);
        });
        return 'read';
      }

      function fly(from) {
        var r = now;
        r.host.style.visibility = 'visible';
        if (still()) {
          animate(r.host, [{ opacity: 0 }, { opacity: 1 }], 150, 'linear');
        } else {
          animate(r.column, [{ transform: from }, { transform: 'none' }], IN, SETTLE);
          animate(r.column, [{ opacity: 0 }, { opacity: 1 }], 180, 'linear');
          animate(r.paper, [{ opacity: 0 }, { opacity: 1 }], 260, 'ease-out');
          animate(r.article, [{ opacity: 1 }, { opacity: 0 }], 140, 'linear');
        }
        after(settle);
      }

      // Arrived: the reader becomes the document and the window scrolls it.
      function settle() {
        stop();
        now.phase = 'reading';
        now.host.style.visibility = '';
        document.documentElement.classList.add('yab-reading');
        now.host.classList.add('yab-flow');
        now.holder.style.transform = '';
        jump(now.y);
        if (now.later.length) {
          var was = now.ref.getBoundingClientRect().top;
          for (var i = 0; i < now.later.length; i++) now.later[i].classList.remove('yab-later');
          now.later = [];
          jump(window.scrollY + now.ref.getBoundingClientRect().top - was);
        }
      }

      function leave() {
        if (!now || !now.host.isConnected) { now = null; return 'gone'; }
        if (now.phase === 'entering') land();
        if (now.phase === 'leaving') return 'left';
        var r = now;
        r.phase = 'leaving';

        // Where you are in the reader now, and the same block on the page,
        // put at the same height, so the page comes back at what you were
        // reading rather than where you left it.
        var here = seen(r.column.querySelectorAll('[data-yab-n]'));
        var n = here ? +here.el.getAttribute('data-yab-n') : -1;
        r.holder.style.transform = 'translateY(' + (-window.scrollY) + 'px)';
        r.host.classList.remove('yab-flow');
        r.host.style.visibility = 'visible';

        var target = r.column, over = null, y = r.pageY;
        if (innerWidth === r.width) {
          // The page stays hidden for this frame: the move is under way
          // before the page is laid out again, in the next task.
          var at = r.boxes[n];
          if (at && at.width > 0 && at.height > 0) {
            y = Math.min(r.most, Math.max(0, at.top - here.rect.top));
            target = here.el;
            over = at;
          } else {
            over = r.box;
          }
          over = { left: over.left, top: over.top - y, width: over.width, height: over.height };
          r.show = function () {
            r.show = null;
            document.documentElement.classList.remove('yab-reading');
            jump(y);
          };
          requestAnimationFrame(function () { setTimeout(function () { if (r.show) r.show(); }, 0); });
          setTimeout(function () { if (r.show) r.show(); }, 100);
        } else {
          // The window is another width than when the page was hidden, so
          // nothing about it is known until it is laid out again.
          document.documentElement.classList.remove('yab-reading');
          jump(r.pageY);
          var twin = r.originals[n];
          var live = twin && twin.isConnected && twin.getBoundingClientRect();
          if (live && live.width > 0 && live.height > 0) {
            jump(window.scrollY + live.top - here.rect.top);
            target = here.el;
            over = twin.getBoundingClientRect();
          } else if (r.article.isConnected) {
            over = r.article.getBoundingClientRect();
          }
        }

        if (still()) {
          animate(r.host, [{ opacity: 1 }, { opacity: 0 }], 150, 'linear');
        } else {
          var to = unseen(over) ? 'translateY(16px)' : flip(r.column, target, over);
          animate(r.column, [{ transform: 'none' }, { transform: to }], OUT, BACK);
          animate(r.column, [{ opacity: 1 }, { opacity: 0 }], 140, 'linear', OUT - 140);
          animate(r.paper, [{ opacity: 1 }, { opacity: 0 }], 220, 'ease-in', 60);
          if (r.article.isConnected) {
            animate(r.article, [{ opacity: 0 }, { opacity: 1 }], 160, 'linear', OUT - 160);
          }
        }
        after(gone);
        return 'left';
      }

      function gone() {
        if (now.show) now.show();
        stop();
        now.host.remove();
        now.style.remove();
        now = null;
      }

      window.__yabReader = {
        theme: theme,
        ready: ready,
        readable: readable,
        enter: enter,
        leave: leave,
        on: function () { return !!now && now.phase !== 'leaving' && now.host.isConnected; }
      };
    })();
    """
}
