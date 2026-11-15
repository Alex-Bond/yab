(() => {
  if (window.__yabEditor) return;
  const owned = new Map(), hidden = new Map(), animations = new Set();
  let layoutBoxes=new Map();
  let current = null, shown = null, original = false, generation = 0, observer = null, pending = 0, springFrame = 0, paintSpring = null, peekLayer = null;
  const sheet = document.createElement('style');
  (document.head || document.documentElement).append(sheet);
  const fonts = ['', '-apple-system, BlinkMacSystemFont, sans-serif', 'ui-rounded, "SF Pro Rounded", sans-serif', '"New York", Charter, Georgia, serif', 'Avenir, "Avenir Next", sans-serif', 'Futura, sans-serif', 'Baskerville, serif', 'ui-monospace, "SF Mono", Menlo, monospace'];
  const cases = ['', 'lowercase', 'uppercase'];
  const media = 'img,video,canvas,svg,picture,iframe';
  let peekOpacity=1;
  const parsedColors=new Map();let colorPixel=null;
  const ignored = e => e.closest('[data-yab-editor-overlay],script,style,noscript,svg,canvas');
  const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  function cancel() {
    generation++;
    cancelAnimationFrame(springFrame); springFrame=0;paintSpring=null;
    animations.forEach(a => a.cancel()); animations.clear();
  }
  function animate(e, frames, options) {
    if (reduced() || !e.animate) return null;
    const a = e.animate(frames, options); animations.add(a);
    a.finished.catch(() => {}).finally(() => animations.delete(a));
    return a;
  }
  // What is in the viewport, measured in one pass with nothing written in
  // between, so the page lays out once.
  function onScreen(list) {
    const w = innerWidth, h = innerHeight, out = [];
    for (const e of list) {
      const b = e.getBoundingClientRect();
      if ((b.width || b.height) && b.bottom > 0 && b.top < h && b.right > 0 && b.left < w) out.push(e);
    }
    return out;
  }
  function remember(e) {
    if (owned.has(e)) return owned.get(e);
    const s = getComputedStyle(e);
    const r = {base: {}, last: {}, input: {}, color: s.color, background: s.backgroundColor,
      border: s.borderTopColor, font: parseFloat(s.fontSize), line: parseFloat(s.lineHeight), image: s.backgroundImage, filter: s.filter};
    owned.set(e, r); return r;
  }
  function put(e, p, value) {
    const r = remember(e);
    if(p in r.last && e.style.getPropertyValue(p)!==r.last[p]) r.base[p]=[e.style.getPropertyValue(p),e.style.getPropertyPriority(p)];
    if (!(p in r.base)) r.base[p] = [e.style.getPropertyValue(p), e.style.getPropertyPriority(p)];
    if(r.input[p]===value && (value===null || e.style.getPropertyValue(p)===r.last[p]))return;
    r.input[p]=value;
    if (value === null) {
      if (e.style.getPropertyValue(p) === r.last[p]) {
        const b = r.base[p]; b[0] ? e.style.setProperty(p, b[0], b[1]) : e.style.removeProperty(p);
      }
      delete r.last[p];
    } else { e.style.setProperty(p, value, 'important'); r.last[p] = e.style.getPropertyValue(p); }
  }
  function rgb(value) {
    if(/^rgba?\(/.test(value)) {
      const v=value.match(/[\d.]+/g);return v&&v.length>=3?v.map(Number):[0,0,0,0];
    }
    if(parsedColors.has(value))return parsedColors.get(value);
    try {
      if(!colorPixel){const c=document.createElement('canvas');c.width=c.height=1;colorPixel=c.getContext('2d',{willReadFrequently:true});}
      colorPixel.clearRect(0,0,1,1);colorPixel.fillStyle=value;colorPixel.fillRect(0,0,1,1);
      const p=colorPixel.getImageData(0,0,1,1).data,result=[p[0],p[1],p[2],p[3]/255];
      parsedColors.set(value,result);return result;
    }catch(_){return [0,0,0,0];}
  }
  function paperColor() {
    const body=remember(document.body).background,root=remember(document.documentElement).background;
    return rgb(body)[3]!==0?body:rgb(root)[3]!==0?root:'rgb(255,255,255)';
  }
  function tint(value, look) {
    const [r,g,b,a=1] = rgb(value);
    if (a < .01) return value;
    const high = Math.max(r,g,b)/255, low = Math.min(r,g,b)/255;
    let l = (high+low)/2;
    const dark = look.mode === 'dark' || (!look.mode && matchMedia('(prefers-color-scheme: dark)').matches);
    if (look.mode || look.amount) {
      const pageDark = rgb(paperColor()).slice(0,3).reduce((a,b)=>a+b,0)/3 < 100;
      if (dark !== pageDark) l = 1-l;
      l = dark ? Math.max(.065,Math.min(.93,l)) : Math.max(.07,Math.min(.985,l));
    }
    const sat = Math.min(65, look.amount * 65);
    return `hsla(${look.hue},${sat}%,${l*100}%,${a})`;
  }
  function render(look, motion) {
    if(original && look.enabled) { previewOriginal(look); return; }
    if(peekLayer) {
      const layer=peekLayer;peekLayer=null;
      const a=motion==='peek'?animate(layer,[{opacity:peekOpacity},{opacity:0}],{duration:120,easing:'ease-out'}):null;
      if(a){a.finished.catch(()=>{}).finally(()=>layer.remove());setTimeout(()=>layer.remove(),125);}else layer.remove();
    }
    const active = look.enabled && !original;
    const colors = active && (look.amount > 0 || look.mode !== '');
    const nodes = [document.documentElement, ...document.querySelectorAll('body,body *')];
    // Read before writing any ancestor: otherwise a child's "original"
    // font size/color would already include its parent's new customization.
    const fresh=nodes.filter(e=>!ignored(e)&&!owned.has(e));
    if(fresh.length && owned.size) {
      // New SPA content inherits our current font/color. Measure it with
      // the owned declarations lifted, then put them back in the same turn.
      const css=sheet.textContent; sheet.textContent='';
      owned.forEach((r,e)=>Object.keys(r.last).forEach(p=>{
        if(e.style.getPropertyValue(p)!==r.last[p])return;
        const b=r.base[p];b[0]?e.style.setProperty(p,b[0],b[1]):e.style.removeProperty(p);
      }));
      fresh.forEach(remember);
      owned.forEach((r,e)=>Object.keys(r.last).forEach(p=>e.style.setProperty(p,r.last[p],'important')));
      sheet.textContent=css;
    } else fresh.forEach(remember);
    // A colour move is drawn only where it can be seen, and every colour is
    // read before any is written and after all are: a read between writes
    // makes the page work out every style again, once per element, which
    // held a page of 20 000 elements for seconds (#1908).
    const moving = motion === 'scheme' || motion === 'peek' || motion === 'toggle';
    const froms = new Map();
    if (moving) onScreen(nodes).forEach(e => {
      if (ignored(e) || e.matches(media) || e.closest('svg,picture')) return;
      const s = getComputedStyle(e);
      froms.set(e, {color: s.color, backgroundColor: s.backgroundColor, borderColor: s.borderTopColor});
    });
    sheet.textContent = active ? look.css : '';
    nodes.forEach(e => {
      if (ignored(e)) return;
      const r = remember(e), isMedia = e.matches(media) || e.closest('svg,picture');
      if (!isMedia) {
        put(e,'color',colors ? tint(r.color,look) : null);
        put(e,'background-color',colors && r.image === 'none' ? tint(r.background,look) : null);
        put(e,'border-color',colors ? tint(r.border,look) : null);
        put(e,'font-family',active && look.font ? fonts[look.font] : null);
        put(e,'text-transform',active && look.textCase ? cases[look.textCase] : null);
        put(e,'font-size',active && look.size !== 1 ? `${r.font*look.size}px` : null);
        put(e,'line-height',active && look.spacing !== 1 ? `${(Number.isFinite(r.line)?r.line:r.font*1.4)*look.spacing}px` : null);
      }
      if (e.matches('img,video,picture')) put(e,'filter',active && look.photos !== 1 ? `${r.filter==='none'?'':r.filter+' '}saturate(${look.photos})` : null);
    });
    // A plain page's transparent body still needs a paper behind it.
    put(document.documentElement,'background-color',colors ? tint(paperColor(),look) : null);
    put(document.documentElement,'color-scheme',active && look.mode ? look.mode : null);
    froms.forEach((from, e) => {
      const to = getComputedStyle(e);
      animate(e,[from,{color:to.color,backgroundColor:to.backgroundColor,borderColor:to.borderTopColor}],
        {duration:motion==='peek'?120:motion==='scheme'?300:220,easing:'cubic-bezier(.2,.8,.2,1)'});
    });
    const selectors = new Set(active ? look.hidden.map(h=>h.selector) : []);
    // A peek draws copies over the existing layout. Disabling/resetting the
    // look really restores flow; only a held Original avoids moving siblings.
    hidden.forEach((r,sel)=>{
      // SPA navigation can replace the node while keeping its selector.
      // Drop the old node's geometry so Original and Show use its replacement.
      let node=null;try{node=document.querySelector(sel)}catch(_){}
      if (selectors.has(sel) && r.node===node && r.node.isConnected) return;
      put(r.node,'display',null);hidden.delete(sel);
    });
    // What is newly hidden is measured where the page had it, with what was
    // hidden before put back for a moment, so a copy in Original sits in
    // its own place and not where the page closed up.
    const unseen=new Map();
    [...selectors].forEach(sel=>{try{const e=document.querySelector(sel);if(e&&!hidden.has(sel))unseen.set(sel,e)}catch(_){}});
    if(unseen.size) {
      const held=[...hidden.values()].filter(h=>h.display!=='none').map(h=>[h.node,h.node.style.getPropertyValue('display'),h.node.style.getPropertyPriority('display'),h.display]);
      held.forEach(([n,,,d])=>n.style.setProperty('display',d,'important'));
      unseen.forEach((e,sel)=>{
        const b=e.getBoundingClientRect();
        unseen.set(sel,{node:e,box:{x:b.x+scrollX,y:b.y+scrollY,width:b.width,height:b.height},display:getComputedStyle(e).display});
      });
      held.forEach(([n,v,pr])=>v?n.style.setProperty('display',v,pr):n.style.removeProperty('display'));
    }
    selectors.forEach(sel=>{
      try {
        const e=document.querySelector(sel); if(!e) return;
        if(!hidden.has(sel) && unseen.get(sel)) hidden.set(sel,unseen.get(sel));
        put(e,'display','none');
      } catch (_) {}
    });
    for (const [e] of owned) if(!e.isConnected) owned.delete(e);
    shown=look;
  }
  function previewOriginal(look) {
    if(peekLayer)return;
    const css=sheet.textContent, x=scrollX, y=scrollY;
    sheet.textContent='';
    owned.forEach((r,e)=>Object.keys(r.last).forEach(p=>{
      if(e.style.getPropertyValue(p)!==r.last[p])return;
      const b=r.base[p];b[0]?e.style.setProperty(p,b[0],b[1]):e.style.removeProperty(p);
    }));
    const clone=document.body.cloneNode(true), originals=[document.body,...document.body.querySelectorAll('*')], copies=[clone,...clone.querySelectorAll('*')];
    const properties=['display','position','left','right','top','bottom','width','height','min-width','max-width','min-height','max-height','box-sizing','margin','padding','background','color','font','line-height','letter-spacing','word-spacing','text-align','border','border-radius','flex','flex-direction','flex-wrap','grid-template-columns','grid-template-rows','gap','align-items','justify-content','overflow','opacity','transform','filter','object-fit','white-space','text-decoration','list-style'];
    originals.forEach((e,i)=>{const c=copies[i],s=getComputedStyle(e);if(!c?.style)return;
      properties.forEach(p=>c.style.setProperty(p,s.getPropertyValue(p),'important'));
      c.removeAttribute('id');
      if(c.matches('script,style,iframe,video,audio')) {c.removeAttribute('src');if(c.matches('script,style'))c.textContent='';}
    });
    const paper=getComputedStyle(document.body).backgroundColor;
    const rootPaper=getComputedStyle(document.documentElement).backgroundColor;
    const layer=document.createElement('div');layer.setAttribute('data-yab-editor-overlay','');layer.setAttribute('aria-hidden','true');layer.inert=true;
    layer.style.cssText=`position:fixed!important;inset:0!important;z-index:2147483644!important;overflow:hidden!important;pointer-events:none!important;background:${rgb(paper)[3]!==0?paper:rgb(rootPaper)[3]!==0?rootPaper:'white'}!important;`;
    const shadow=layer.attachShadow({mode:'closed'});
    clone.style.setProperty('position','absolute','important');clone.style.setProperty('top',`${-y}px`,'important');clone.style.setProperty('left',`${-x}px`,'important');
    shadow.append(clone);
    hidden.forEach((r,sel)=>{
      const i=originals.indexOf(r.node),c=copies[i];if(!c)return;
      const restored=c.cloneNode(true),b=r.box;
      restored.style.cssText+=`;display:${r.display==='none'?'block':r.display}!important;position:fixed!important;left:${b.x-x}px!important;top:${b.y-y}px!important;width:${b.width}px!important;height:${b.height}px!important;margin:0!important;`;
      c.style.setProperty('display','none','important');shadow.append(restored);
    });
    owned.forEach((r,e)=>Object.keys(r.last).forEach(p=>e.style.setProperty(p,r.last[p],'important')));
    sheet.textContent=css;scrollTo(x,y);
    document.documentElement.append(layer);peekLayer=layer;
    animate(layer,[{opacity:0},{opacity:1}],{duration:120,easing:'ease-out'});
  }
  function boxes() {
    return [...document.querySelectorAll('body *')].filter(e=>!ignored(e)&&e.getClientRects().length)
      .slice(0,2000).map(e=>[e,e.getBoundingClientRect()]);
  }
  function room(before) {
    layoutBoxes=new Map(boxes());
    const moves=new Map();
    before.forEach(([e,a])=>{
      if(!e.isConnected || !e.getClientRects().length) return;
      const b=e.getBoundingClientRect(), x=a.x-b.x, y=a.y-b.y;
      if(Math.abs(x)+Math.abs(y)>.5 && Math.abs(x)+Math.abs(y)<innerHeight*2)
        moves.set(e,{x,y});
    });
    moves.forEach((delta,e)=>{
      let x=delta.x,y=delta.y,parent=e.parentElement;
      while(parent) {if(moves.has(parent)){x-=moves.get(parent).x;y-=moves.get(parent).y;break;}parent=parent.parentElement;}
      if(Math.abs(x)+Math.abs(y)>.5)animate(e,[{translate:`${x}px ${y}px`},{translate:'0px 0px'}],{duration:200,easing:'cubic-bezier(.2,.8,.2,1)',composite:'add'});
    });
  }
  function apply(look,motion='direct',peek=false) {
    if(!document.body) { addEventListener('DOMContentLoaded',()=>apply(look,motion,peek),{once:true}); return; }
    // Reset's staggered restores change only the hidden list. They must not
    // restart or cancel the controls/page color spring already in flight.
    if(springFrame&&paintSpring&&!peek&&['hide','restore'].includes(motion)&&
       ['enabled','hue','amount','mode','font','textCase','size','spacing','photos','css'].every(k=>look[k]===current[k])) {
      const before=boxes();current=look;paintSpring(performance.now());room(before);return true;
    }
    const previous=shown;
    const before=motion==='hide'||motion==='restore'||motion==='reset'?boxes():null;
    if(peekLayer)peekOpacity=Number(getComputedStyle(peekLayer).opacity);
    cancel(); current=look; original=peek;
    if(motion==='font' && !reduced()) {
      const token=generation;
      // Only what is on screen: a blur on every heading and link of a long
      // page is thousands of layers nobody sees (#1908).
      const text=onScreen(document.querySelectorAll('h1,h2,h3,h4,p,a,li,label,button')).filter(e=>!ignored(e));
      text.forEach(e=>animate(e,[{opacity:1,filter:'blur(0px)'},{opacity:.45,filter:'blur(1.6px)'},{opacity:1,filter:'blur(0px)'}],{duration:180,easing:'ease-in-out'}));
      setTimeout(()=>{if(token===generation) render(look,'direct')},70);
    } else if((motion==='glide'||motion==='reset') && previous && !reduced()) {
      const token=generation, start=performance.now(), w=2*Math.PI/.34, z=.82, wd=w*Math.sqrt(1-z*z);
      const turn=look.hue-previous.hue;
      const readPalette=()=>new Map([...owned.keys()].filter(e=>e.isConnected&&!e.matches(media)).map(e=>{
        const s=getComputedStyle(e);return [e,[s.color,s.backgroundColor,s.borderTopColor]];
      }));
      const paletteFrom=motion==='reset'?readPalette():null;
      let paletteTo=null;
      if(paletteFrom){render(look,'direct');paletteTo=readPalette();}
      function paint(now) {
        const t=(now-start)/1000, p=1-Math.exp(-z*w*t)*(Math.cos(wd*t)+(z*w/wd)*Math.sin(wd*t));
        const at={...look,hidden:current.hidden,hue:previous.hue+turn*p};
        ['amount','size','spacing','photos'].forEach(k=>at[k]=previous[k]+(look[k]-previous[k])*p);
        render(at,'direct');
        if(paletteFrom)paletteFrom.forEach((from,e)=>{
          const to=paletteTo.get(e);if(!to)return;
          ['color','background-color','border-color'].forEach((prop,i)=>{
            const a=rgb(from[i]),b=rgb(to[i]),v=[0,1,2].map(k=>Math.round(Math.max(0,Math.min(255,a[k]+(b[k]-a[k])*p))));
            const alpha=Math.max(0,Math.min(1,(a[3]??1)+((b[3]??1)-(a[3]??1))*p));
            put(e,prop,`rgba(${v[0]},${v[1]},${v[2]},${alpha})`);
          });
        });
      }
      function tick(now) {
        if(token!==generation)return;
        paint(now);
        if((now-start)/1000<.55)springFrame=requestAnimationFrame(tick);
        else{springFrame=0;paintSpring=null;render({...look,hidden:current.hidden},'direct');}
      }
      paintSpring=paint;paint(start);
      springFrame=requestAnimationFrame(tick);
    } else render(look,motion);
    if(before) room(before);
    if(!observer) {
      observer=new MutationObserver(entries=>{
        if(!current || entries.every(r=>[...r.addedNodes].every(n=>n.nodeType!==1||n===sheet||n.hasAttribute('data-yab-editor-overlay')))) return;
        // A timer, not a frame: a page that isn't drawing (a hidden tab) gets
        // no frames, and its replaced nodes must still be hidden.
        if(!pending) pending=setTimeout(()=>{pending=0;render(current,'direct')},16);
      });
      observer.observe(document.body,{childList:true,subtree:true});
    }
    return true;
  }
  function similar(selector) {
    try {
      const e=document.querySelector(selector); if(!e || !e.parentElement) return [];
      return [...e.parentElement.children].filter(n=>n.tagName===e.tagName && n.className===e.className && n.getClientRects().length)
        .map(n=>{const r=n.getBoundingClientRect();return {selector:path(n),label:nameOf(n),rect:[r.x,r.y,r.width,r.height],note:where(r)}});
    } catch (_) { return []; }
  }
  // A name in words: its own label, else its first heading, else its first line.
  function nameOf(n) {
    const h=n.querySelector('h1,h2,h3,h4,[role=heading]');
    const t=(n.getAttribute('aria-label')||(h&&h.innerText)||n.innerText||n.tagName).trim().split('\n')[0];
    return t.slice(0,48);
  }
  // Where a thing sat and how big, in words, for the hidden list.
  function where(r) {
    const at=r.left+r.width/2, side=at>innerWidth*.6?'right':at<innerWidth*.25?'left':'middle';
    return `${side}, ${Math.round(r.width)}\u00d7${Math.round(r.height)}`;
  }
  // The selector of what is under a point, for an Option-click in the code.
  function selectorAt(x,y) {
    const e=document.elementsFromPoint(x,y).find(n=>!ignored(n)&&n!==document.documentElement&&n!==document.body);
    return e?path(e):null;
  }
  // The site's own line height as a multiple of its text size, before any edit.
  function base() {
    const r=remember(document.body), v=r.line/r.font;
    return Number.isFinite(v)&&v>0.8&&v<4?v:1.4;
  }
  function path(e) {
    if(e.id) return '#'+CSS.escape(e.id);
    const parts=[];
    while(e && e!==document.documentElement) {
      if(e.id){parts.unshift('#'+CSS.escape(e.id));break;}
      parts.unshift(e.tagName.toLowerCase()+`:nth-of-type(${[...e.parentElement.children].filter(c=>c.tagName===e.tagName).indexOf(e)+1})`);
      e=e.parentElement;
    }
    return parts.join(' > ');
  }
  let marks=[];
  function mark(selectors) {
    marks.forEach(a=>a.cancel());marks=[];
    selectors.forEach((s,i)=>{try{document.querySelectorAll(s).forEach(e=>{
      const a=animate(e,[{outline:'2px dashed rgba(10,122,255,0)'},{outline:'2px dashed rgba(10,122,255,.7)'}],{duration:150,delay:reduced()?0:i*25,fill:'forwards'});
      if(a)marks.push(a);
    })}catch(_){}});
  }
  function hold(selector) {
    // A subsequent member of an All-similar restore must not expose the
    // previous member before its native snapshot has finished flying.
    try {const e=document.querySelector(selector);if(e&&!reduced()){const a=e.animate([{visibility:'hidden'},{visibility:'hidden'}],{duration:550});a.finished.catch(()=>{});}}catch(_){}
  }
  function highlight(css) {
    const probe=document.createElement('style'); probe.textContent=css;(document.head||document.documentElement).append(probe);
    try { [...probe.sheet.cssRules].forEach(rule=>{
      if(!rule.selectorText) return;
      document.querySelectorAll(rule.selectorText).forEach(e=>animate(e,[{outline:'2px solid rgba(10,122,255,.7)',outlineOffset:'2px'},{outline:'2px solid rgba(10,122,255,0)',outlineOffset:'2px'}],{duration:1200,easing:'ease-out'}));
    }); } catch (_) {} finally { probe.remove(); }
  }
  const system=matchMedia('(prefers-color-scheme: dark)');
  system.addEventListener('change',()=>{if(current&&!current.mode) apply(current,'scheme',original)});
  matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change',()=>{if(current&&reduced())apply(current,'direct',original)});
  window.__yabEditor={apply,similar,selectorAt,base,mark,hold,highlight,rect:e=>{const r=layoutBoxes.get(e)||e.getBoundingClientRect();return [r.x,r.y,r.width,r.height]},order:()=>[...hidden.entries()].sort((a,b)=>a[1].box.y-b[1].box.y).map(([s])=>s),report:()=>({original,hidden:hidden.size,animations:animations.size,spring:!!springFrame,generation})};
})();
