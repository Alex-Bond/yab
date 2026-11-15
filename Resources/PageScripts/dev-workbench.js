(function () {
  const W = window.__yabWire;
  if (!W || W.workbench) return;
  const B = W.workbench = {nodes:new Map(), root:0, scripts:new Map(), frames:[], events:[], memory:[], recording:false, selected:0};
  const call = (m,p={}) => W.call(m,p);
  const json = x => JSON.stringify(x);
  async function page(expression){
    const r=await call('Runtime.evaluate',{expression:expression+'\n//# sourceURL=__yab_workbench',returnByValue:false,objectGroup:'yab-workbench'});
    let v=r.result;
    if(v.className==='Promise'||v.subtype==='promise'){const a=await call('Runtime.awaitPromise',{promiseObjectId:v.objectId,returnByValue:true});v=a.result;if(a.wasThrown)throw new Error(v.description||'Page promise rejected');}
    if(r.wasThrown)throw new Error(v.description||'Page evaluation failed');
    return v.value;
  }
  // Yab's drawing of the node pointed at (dev-highlight.js) lives in the
  // page's DOM: it isn't shown, and its redraws aren't the page changing.
  function isOverlay(n){const name=n?.nodeName?.();return name==='YAB-HIGHLIGHT'||name==='YAB-PICKER';}
  // DOM changes come in bursts (a page's script, X's timeline): one word a
  // beat, not one a change, each of which had Yab fetch the tree again.
  function changed(){const q=W.q.workbench;if(q&&q.length&&q[q.length-1].kind==='domChanged')return;W.post('workbench',{kind:'domChanged'});}
  function inOverlay(id){for(let n=WI.domManager?.nodeForId?.(id);n;n=n.parentNode)if(isOverlay(n))return true;return false;}
  function node(n) {
    if (!n) return;
    const old=B.nodes.get(n.nodeId);
    B.nodes.set(n.nodeId, Object.assign(old||{},n));
    for(const c of n.children||[]) node(c);
    for(const c of n.shadowRoots||[]) node(c);
    for(const c of n.pseudoElements||[]) node(c);
    if(n.contentDocument) node(n.contentDocument);
  }
  function tree(id,depth=0) {
    const n=B.nodes.get(id); if(!n||depth>100) return null;
    const a=n.attributes||[]; let label=n.nodeType===1?'<'+n.nodeName.toLowerCase():n.nodeName;
    for(let i=0;i<a.length;i+=2) label+=' '+a[i]+'="'+a[i+1]+'"';
    if(n.nodeType===1) label+='>'; else if(n.nodeValue) label+=' '+n.nodeValue;
    const children=[...(n.children||[]),...(n.shadowRoots||[]),...(n.pseudoElements||[])]; if(n.contentDocument) children.push(n.contentDocument);
    return {id:n.nodeId,type:n.nodeType,label,count:n.childNodeCount||children.length,children:children.map(c=>tree(c.nodeId,depth+1)).filter(Boolean)};
  }
  W.events.push((m,target)=>{
    const p=m.params||{};
    switch(m.method){
      // Nodes handed over because they were asked for (a node opened, Expand
      // Recursively, a search's or the picker's path): not the page
      // changing, and whoever asked fetches the tree itself. Taken as a
      // change, each hover of the picker and each node of a deep expand
      // reloaded the whole tree (thousands of times on X).
      case 'DOM.setChildNodes': {if(inOverlay(p.parentId))break;
        const parent=B.nodes.get(p.parentId); if(parent){parent.children=p.nodes;parent.childNodeCount=p.nodes.length;}
        (p.nodes||[]).forEach(node); break;
      }
      case 'DOM.childNodeInserted': {if(p.node?.nodeName==='YAB-HIGHLIGHT'||p.node?.nodeName==='YAB-PICKER'||inOverlay(p.parentNodeId))break;
        const parent=B.nodes.get(p.parentNodeId); if(parent){let c=parent.children||[];let i=c.findIndex(n=>n.nodeId===p.previousNodeId);c.splice(i+1,0,p.node);parent.children=c;parent.childNodeCount=c.length;}
        node(p.node); changed(); break;
      }
      case 'DOM.childNodeRemoved': {if(inOverlay(p.parentNodeId)||inOverlay(p.nodeId)||/^YAB-(HIGHLIGHT|PICKER)$/.test(B.nodes.get(p.nodeId)?.nodeName||''))break;
        const parent=B.nodes.get(p.parentNodeId);if(parent){parent.children=(parent.children||[]).filter(n=>n.nodeId!==p.nodeId);parent.childNodeCount=parent.children.length;}
        B.nodes.delete(p.nodeId);changed();break;
      }
      case 'DOM.attributeModified': case 'DOM.attributeRemoved': {if(inOverlay(p.nodeId))break;
        const n=B.nodes.get(p.nodeId);if(n){let a=n.attributes||[];const i=a.indexOf(p.name);if(i>=0)a.splice(i,2);if(m.method==='DOM.attributeModified')a.push(p.name,p.value);n.attributes=a;}
        changed();break;
      }
      case 'DOM.characterDataModified': {if(inOverlay(p.nodeId))break;const n=B.nodes.get(p.nodeId);if(n)n.nodeValue=p.characterData;changed();break;}
      case 'DOM.childNodeCountUpdated': {if(inOverlay(p.nodeId))break;const n=B.nodes.get(p.nodeId);if(n)n.childNodeCount=p.childNodeCount;changed();break;}
      case 'DOM.shadowRootPushed': {if(inOverlay(p.hostId))break;const n=B.nodes.get(p.hostId);if(n){n.shadowRoots=n.shadowRoots||[];n.shadowRoots.push(p.root);}node(p.root);changed();break;}
      case 'DOM.shadowRootPopped': {if(inOverlay(p.hostId))break;const n=B.nodes.get(p.hostId);if(n)n.shadowRoots=(n.shadowRoots||[]).filter(c=>c.nodeId!==p.rootId);B.nodes.delete(p.rootId);changed();break;}
      case 'DOM.pseudoElementAdded': {const n=B.nodes.get(p.parentId);if(n){n.pseudoElements=n.pseudoElements||[];n.pseudoElements.push(p.pseudoElement);}node(p.pseudoElement);changed();break;}
      case 'DOM.pseudoElementRemoved': {const n=B.nodes.get(p.parentId);if(n)n.pseudoElements=(n.pseudoElements||[]).filter(c=>c.nodeId!==p.pseudoElementId);B.nodes.delete(p.pseudoElementId);changed();break;}
      case 'DOM.documentUpdated': B.picking=false;W.post('workbench',{kind:'picking',on:false});B.nodes.clear();B.scripts.clear();B.root=0;W.post('workbench',{kind:'navigation'});break;
      case 'DOM.inspect': case 'DOM.inspectNode': W.post('workbench',{kind:'picked',id:p.nodeId});break;
      case 'Debugger.scriptParsed': B.scripts.set((target?.identifier||'')+':'+p.scriptId,{id:p.scriptId,url:p.url||'',line:p.startLine||0,target:target?.identifier||'',injected:p.isContentScript,sourceURL:p.sourceURL});break;
      case 'Debugger.paused': B.frames=(p.callFrames||[]).map(f=>Object.assign({},f,{target:target?.identifier||'',mapped:mappedAt(f.location,target)}));W.post('workbench',{kind:'paused',frames:B.frames,reason:p.reason||''});break;
      case 'Debugger.resumed': B.frames=[];W.post('workbench',{kind:'resumed'});break;
      case 'LayerTree.layerTreeDidChange': W.post('workbench',{kind:'layers'});break;
      case 'Memory.trackingUpdate':
        if(B.recording){B.memory.push(p.event);W.post('workbench',{kind:'memory',sample:p.event});}break;
      case 'Timeline.eventRecorded':
        if(B.recording){ B.events.push(p.record); if(B.events.length>100000) B.events.splice(0,1000); W.post('workbench',{kind:'trace',records:[p.record]}); }break;
    }
  });
  function listenForPickedNodes(){
    if(B.pickerListener||!WI.domManager||!WI.DOMManager?.Event.DOMNodeWasInspected)return;
    WI.domManager.addEventListener(WI.DOMManager.Event.DOMNodeWasInspected,event=>{
      const id=event.data?.node?.id;
      if(typeof id==='number')W.post('workbench',{kind:'picked',id});
    });
    B.pickerListener=true;
  }
  listenForPickedNodes();W.beats.push(listenForPickedNodes);
  async function documentRoot(){const root=await new Promise(resolve=>WI.domManager.requestDocument(resolve));if(!root)throw Error('WebKit has no document');return root;}
  function domChildren(n){const all=[...(n.children||[]),...(n.shadowRoots?.()||[]),...(n.pseudoElements?.().values?.()||[])];if(n._contentDocument)all.push(n._contentDocument);const template=n.templateContent?.();if(template)all.push(template);return [...new Map(all.filter(c=>!isOverlay(c)).map(n=>[n.id,n])).values()];}
  function domTree(n,depth=0){if(!n||depth>100)return null;const type=n.nodeType(),name=n.nodeName(),attributes=n.attributes()||[];let label=type===1?'<'+name.toLowerCase():name;for(const a of attributes)label+=' '+a.name+'="'+a.value+'"';if(type===1)label+='>';else if(n.nodeValue())label+=' '+n.nodeValue();const children=domChildren(n);return {id:n.id,type,label,count:n.childNodeCount||children.length,children:children.map(c=>domTree(c,depth+1)).filter(Boolean)};}
  // Elements' find, as Chromium's: WebKit's own node finder (tag names,
  // attributes, text, CSS selectors and XPath, through the page's frames),
  // its document asked for first so its node ids are the frontend's; the
  // results kept on WebKit's side and fetched one at a time, as a step
  // reaches each, its path pushed to the tree.
  W.fn['elements.search']=async p=>{
    await documentRoot();
    const agent=WI.mainTarget.DOMAgent;
    if(B.searchId){const old=B.searchId;B.searchId=null;agent.discardSearchResults.invoke({searchId:old}).catch(()=>{});}
    const query=String(p.query||'').trim();
    if(!query)return json({count:0});
    const r=await agent.performSearch.invoke({query,caseSensitive:false});
    B.searchId=r.searchId;
    const count=r.resultCount||0;
    // Searched again as the page changed: where the node shown is now.
    let at=-1;
    if(p.keep&&count){const g=await agent.getSearchResults.invoke({searchId:r.searchId,fromIndex:0,toIndex:Math.min(count,5000)});at=(g.nodeIds||[]).indexOf(p.keep);}
    return json({count,at});
  };
  W.fn['elements.searchResult']=async p=>{
    if(!B.searchId)return json({id:0});
    const r=await WI.mainTarget.DOMAgent.getSearchResults.invoke({searchId:B.searchId,fromIndex:p.index,toIndex:p.index+1});
    const id=(r.nodeIds||[])[0]||0;
    const n=id&&WI.domManager.nodeForId(id);const path=[];for(let a=n&&n.parentNode;a;a=a.parentNode)path.unshift(a.id);
    return json({id,path});
  };
  W.fn['elements.searchEnd']=async()=>{
    if(B.searchId){const old=B.searchId;B.searchId=null;await WI.mainTarget.DOMAgent.discardSearchResults.invoke({searchId:old}).catch(()=>{});}
    return true;
  };
  W.fn['elements.tree']=async p=>{
    const root=await documentRoot();B.root=root.id;
    if(p.reload||p.deep)await new Promise(resolve=>root.getSubtree(-1,resolve));
    if(p.expand){const n=WI.domManager.nodeForId(p.expand);if(n)await new Promise(resolve=>n.getSubtree(p.deep?-1:1,resolve));}
    // A return (DevReturn.swift): each path ({i: child indexes, p: WebKit's own path, k: its node open}) loaded down to its node, and an open node's
    // children: WebKit's paths pushed at once, one answer each, all together; what they could not reach, a level of every path at a time.
    if(p.open){if(WI.domManager.pushNodeByPathToFrontend)await Promise.all(p.open.filter(o=>o.p).map(o=>new Promise(resolve=>{try{WI.domManager.pushNodeByPathToFrontend(o.p,resolve);}catch(e){resolve();}})));
      let level=p.open.map(o=>({o,n:root,i:0}));while(level.length){const need=[...new Map(level.filter(x=>(x.i<x.o.i.length||x.o.k)&&x.n.childNodeCount&&!x.n.children?.length).map(x=>[x.n.id,x.n])).values()];if(need.length)await Promise.all(need.map(n=>new Promise(resolve=>n.getSubtree(1,resolve))));level=level.filter(x=>x.i<x.o.i.length).map(x=>({o:x.o,n:domChildren(x.n)[x.o.i[x.i]],i:x.i+1})).filter(x=>x.n);}}
    if(p.deep||p.reload){const visited=new Set;async function descend(n){if(visited.has(n.id))return;visited.add(n.id);if(n.childNodeCount&&!n.children?.length)await new Promise(resolve=>n.getSubtree(-1,resolve));for(const child of domChildren(n))await descend(child);}await descend(root);}
    return json(treeOf(root));
  };
  // Chrome's inspect mode (inspect_tools.cc, SearchingForNodeTool): the
  // page gets no pointer while picking (no :hover, no mouseover, no
  // click), a clear layer over it in the top layer takes it; the node
  // under the pointer is found as Blink's hit test finds it (an element,
  // pointer-events: none passed through), into frames and open shadow
  // roots; a cross-origin frame is looked into from its own document by
  // the inspector (into). The press picks, as Chromium's mouse down does,
  // and the release and click that follow are the layer's too. The wheel
  // still scrolls what is under the pointer, the node pointed at let go
  // until the pointer moves, as Chromium clears it on a scroll.
  // Shift (Chrome's HoveredNodeForEvent with kIgnorePointerEventsNone):
  // a node with pointer-events: none is hit too, for the hit test alone; a
  // sheet of Yab's in the document (or shadow root) for that one call, the
  // page's own sheets as they were before and after it.
  const UNDER=`function hits(root,x,y,all){
    if(!all)return root.elementsFromPoint(x,y);
    const win=(root.ownerDocument||root).defaultView;let kept=null;
    try{const sheet=new win.CSSStyleSheet();sheet.replaceSync('*,*::before,*::after{pointer-events:auto!important}');kept=[...root.adoptedStyleSheets];root.adoptedStyleSheets=[...kept,sheet];}catch(_){kept=null;}
    try{return root.elementsFromPoint(x,y);}finally{if(kept){try{root.adoptedStyleSheets=kept;}catch(_){}}}
  }
  function under(doc,x,y,skip,out,all){
    let e=hits(doc,x,y,all).find(n=>n!==skip&&(doc.nodeType===9||doc.contains(n)));
    if(!e)return null;
    for(let i=0;i<32;i++){
      if(e.shadowRoot){const r=e.shadowRoot,inner=hits(r,x,y,all).find(n=>n!==e&&r.contains(n));if(inner&&inner!==e){e=inner;continue;}}
      if(e.localName==='iframe'||e.localName==='frame'){
        const r=e.getBoundingClientRect(),cs=e.ownerDocument.defaultView.getComputedStyle(e);
        const ix=x-r.left-parseFloat(cs.borderLeftWidth)-parseFloat(cs.paddingLeft),iy=y-r.top-parseFloat(cs.borderTopWidth)-parseFloat(cs.paddingTop);
        let d=null;try{d=e.contentDocument;}catch(_){}
        if(d){const inner=hits(d,ix,iy,all)[0];if(inner){e=inner;x=ix;y=iy;continue;}}
        else if(out)out.cross=[ix,iy];
      }
      break;
    }
    if(out)out.at=[x,y];
    return e;
  }`;
  // Chrome's SearchingForNodeTool: a move finds the node (Shift: through
  // pointer-events: none, the node the event itself would reach drawn
  // too, as event_target_node_); the press picks.
  const HANDS=`S.move=(x,y,all)=>{const p=point(x,y,all);if(!p.e)return;S.hover=p.e;S.cross=p.cross;S.at=p.at;S.all=!!all;
      S.target=all?point(x,y,false).e:null;if(S.target===S.hover)S.target=null;};
    S.press=(x,y,all)=>{const p=point(x,y,all);S.picked=p.e||S.hover;S.pickedCross=p.e?p.cross:S.cross;S.pickedAt=p.e?p.at:S.at;S.pickedAll=p.e?!!all:!!S.all;S.target=null;};`;
  const PICKER=`(()=>{window.__yabNativePicker?.remove?.();
    const S=window.__yabNativePicker={hover:null,picked:null,cross:null,pickedCross:null,down:false};
    const host=document.createElement('yab-picker');host.setAttribute('popover','manual');
    const root=host.attachShadow({mode:'closed'});
    root.innerHTML='<style>:host{all:initial!important;position:fixed!important;inset:0!important;margin:0!important;padding:0!important;border:0!important;width:auto!important;height:auto!important;max-width:none!important;max-height:none!important;background:transparent!important;z-index:2147483646!important}div{position:absolute;inset:0;cursor:default}</style><div></div>';
    const layer=root.querySelector('div');
    ${UNDER}
    function scroller(e,dx,dy){
      for(let n=e;n&&n.nodeType===1;n=n.parentElement||n.getRootNode().host){
        const cs=n.ownerDocument.defaultView.getComputedStyle(n);
        if((dy&&/(auto|scroll|overlay)/.test(cs.overflowY)&&n.scrollHeight>n.clientHeight)||(dx&&/(auto|scroll|overlay)/.test(cs.overflowX)&&n.scrollWidth>n.clientWidth))return n;
      }
      return e?.ownerDocument?.scrollingElement||document.scrollingElement;
    }
    const point=(x,y,all)=>{const out={};const e=under(document,x,y,host,out,all);return {e,cross:out.cross||null,at:out.at||null};};
    const stopped=e=>{e.preventDefault();e.stopPropagation();};
    let gone=false,late=0;
    S.remove=()=>{if(gone)return;gone=true;clearTimeout(late);try{host.hidePopover();}catch(e){}host.remove();if(window.__yabNativePicker===S)delete window.__yabNativePicker;window.__yabNativePickerLast=S;};
    // Put away; with the button still down, once it is up (its release
    // and click are the layer's), or in a second at the latest.
    S.stop=()=>{if(!S.down){S.remove();return;}S.stopping=true;clearTimeout(late);late=setTimeout(S.remove,1000);};
    layer.addEventListener('pointermove',e=>S.move(e.clientX,e.clientY,e.shiftKey));
    layer.addEventListener('pointerdown',e=>{stopped(e);if(e.button!==0)return;S.down=true;S.press(e.clientX,e.clientY,e.shiftKey);});
    const release=e=>{stopped(e);if(!S.down)return;S.down=false;if(S.stopping||S.picked)setTimeout(S.remove,0);};
    layer.addEventListener('pointerup',release);layer.addEventListener('pointercancel',release);
    for(const type of ['click','auxclick','dblclick','contextmenu','mousedown','mouseup'])layer.addEventListener(type,stopped);
    layer.addEventListener('wheel',e=>{stopped(e);const k=e.deltaMode===1?16:e.deltaMode===2?innerHeight:1;const t=scroller(point(e.clientX,e.clientY).e,e.deltaX,e.deltaY);t?.scrollBy({left:e.deltaX*k,top:e.deltaY*k,behavior:'instant'});S.hover=null;S.cross=null;S.target=null;},{passive:false});
    ${HANDS}
    document.documentElement.appendChild(host);try{host.showPopover();}catch(e){}
    return true;})()`;
  // The same with WebKit's own switch on (DevPicker.swift): the page gets
  // no mouse at all and no layer is needed; Yab hands the pointer's place
  // over (move, press), a scroll lets go of the node.
  const PICKER_NATIVE=`(()=>{window.__yabNativePicker?.remove?.();
    const S=window.__yabNativePicker={hover:null,picked:null,cross:null,pickedCross:null,native:true};
    ${UNDER}
    const point=(x,y,all)=>{const out={};const e=under(document,x,y,null,out,all);return {e,cross:out.cross||null,at:out.at||null};};
    ${HANDS}
    S.scrolled=()=>{S.hover=null;S.cross=null;S.target=null;};
    const scrolled=()=>S.scrolled();
    addEventListener('scroll',scrolled,{capture:true,passive:true});
    S.remove=()=>{removeEventListener('scroll',scrolled,{capture:true});if(window.__yabNativePicker===S)delete window.__yabNativePicker;window.__yabNativePickerLast=S;};
    S.stop=S.remove;
    return true;})()`;
  // The node under a point of a frame the page can't look into, found
  // from that frame's own document: [node, and a point in a frame inside it
  // it can't look into either].
  const INTO=`function(x,y,all){${UNDER}const out={};const e=under(this,x,y,null,out,all);return [e,out.cross?out.cross[0]:null,out.cross?out.cross[1]:null,out.at?out.at[0]:null,out.at?out.at[1]:null];}`;
  async function intoFrames(id,cross,all){
    let point=null;
    for(let i=0;i<8&&cross;i++){
      const n=WI.domManager.nodeForId(id),d=n&&(n._contentDocument||n.contentDocument);
      if(!d)break;
      const o=await call('DOM.resolveNode',{nodeId:d.id,objectGroup:'yab-picker'});
      if(!o.object?.objectId)break;
      const r=await call('Runtime.callFunctionOn',{objectId:o.object.objectId,functionDeclaration:INTO,arguments:[{value:cross[0]},{value:cross[1]},{value:!!all}],objectGroup:'yab-picker'});
      if(r.wasThrown||!r.result?.objectId)break;
      const props=(await call('Runtime.getProperties',{objectId:r.result.objectId,ownProperties:true})).properties||[];
      const at=k=>props.find(q=>q.name===k)?.value;
      const el=at('0');
      if(el?.subtype!=='node'||!el.objectId)break;
      id=(await call('DOM.requestNode',{objectId:el.objectId})).nodeId||id;
      const cx=at('1')?.value,cy=at('2')?.value,ax=at('3')?.value,ay=at('4')?.value;
      cross=typeof cx==='number'&&typeof cy==='number'?[cx,cy]:null;
      point=typeof ax==='number'&&typeof ay==='number'?[ax,ay]:point;
    }
    return {id,at:point};
  }
  // Into a closed shadow root, which the page's own script can't look into
  // and Chrome's hit test does: the inspector holds the root, and finds the
  // node under the point from it (open roots inside it too).
  const INSIDE=`function(x,y,all){${UNDER}let r=this,e=null;for(let i=0;i<16;i++){const hit=hits(r,x,y,all).find(n=>r.contains(n));if(!hit)break;e=hit;if(hit.shadowRoot){r=hit.shadowRoot;continue;}break;}return e;}`;
  async function intoClosed(id,at,all){
    for(let i=0;i<8&&at;i++){
      const n=WI.domManager.nodeForId(id);
      const root=(n?.shadowRoots?.()||[]).find(r=>(r.shadowRootType?.()||r._shadowRootType)==='closed');
      if(!root)break;
      const o=await call('DOM.resolveNode',{nodeId:root.id,objectGroup:'yab-picker'});
      if(!o.object?.objectId)break;
      const r=await call('Runtime.callFunctionOn',{objectId:o.object.objectId,functionDeclaration:INSIDE,arguments:[{value:at[0]},{value:at[1]},{value:!!all}],objectGroup:'yab-picker'});
      if(r.wasThrown||r.result?.subtype!=='node'||!r.result.objectId)break;
      const inner=(await call('DOM.requestNode',{objectId:r.result.objectId})).nodeId;
      if(!inner||inner===id)break;
      id=inner;
    }
    return id;
  }
  W.fn['elements.pickStart']=async p=>{
    await page(p&&p.native?PICKER_NATIVE:PICKER);B.pickNative=!!(p&&p.native);
    B.picking=true;W.post('workbench',{kind:'picking',on:true});return true;
  };
  W.fn['elements.pickStop']=async()=>{
    B.picking=false;W.post('workbench',{kind:'picking',on:false});
    await page('(()=>{window.__yabNativePicker?.stop();delete window.__yabNativePickerLast;return true})()');
    B.pickHover=0;B.pickTarget=0;await highlight(0);
    await call('DOM.hideHighlight').catch(()=>{});return true;
  };
  W.beats.push(async()=>{
    if(!B.picking||B.pickPending||performance.now()-(B.pickAt||0)<120)return;
    B.pickAt=performance.now();B.pickPending=true;
    try{
      const S='(window.__yabNativePicker||window.__yabNativePickerLast)';
      const [remote,state]=await Promise.all([
        call('Runtime.evaluate',{expression:'(()=>{const S='+S+';return S?.picked||S?.hover||null})()',objectGroup:'yab-picker'}),
        call('Runtime.evaluate',{expression:'(()=>{const S='+S+',p=!!S?.picked;return {picked:p,cross:(p?S.pickedCross:S?.cross)||null,at:(p?S.pickedAt:S?.at)||null,all:!!(p?S.pickedAll:S?.all),target:!p&&!!S?.target}})()',returnByValue:true})]);
      if(!B.picking)return;
      const v=state.result?.value||{},clicked=!!v.picked,cross=v.cross;
      if(remote.result?.subtype==='node'&&remote.result.objectId){
        let id=(await call('DOM.requestNode',{objectId:remote.result.objectId})).nodeId,at=v.at;
        if(cross){const into=await intoFrames(id,cross,v.all);id=into.id;at=into.at;}
        id=await intoClosed(id,at,v.all);
        let target=0;
        if(!clicked&&v.target){
          const t=await call('Runtime.evaluate',{expression:'(()=>{const S='+S+';return S?.target||null})()',objectGroup:'yab-picker'});
          if(t.result?.subtype==='node'&&t.result.objectId)target=(await call('DOM.requestNode',{objectId:t.result.objectId})).nodeId||0;
        }
        if(clicked){await W.fn['elements.pickStop']();W.post('workbench',{kind:'picked',id});}
        else if(id!==B.pickHover||target!==(B.pickTarget||0)||performance.now()-(B.pickDrawn||0)>500){B.pickHover=id;B.pickTarget=target;B.pickDrawn=performance.now();await highlight(id,true,target);}
      }else if(!clicked&&B.pickHover){B.pickHover=0;B.pickTarget=0;await highlight(0);}
    }catch(e){W.post('workbench',{kind:'error',message:'Element picker: '+String(e)});}
    finally{await call('Runtime.releaseObjectGroup',{objectGroup:'yab-picker'}).catch(()=>{});B.pickPending=false;}
  });
  // Elements on WebKit's own inspector models: the rules in cascade order,
  // what each overrides, the inherited ones, the attributes' style.
  function crumb(n){if(!n)return '';if(n.nodeType()===9)return '#document';const id=n.getAttribute?.('id'),cls=(n.getAttribute?.('class')||'').trim().split(/\s+/)[0];return (n.localName?.()||n.nodeName().toLowerCase())+(id?'#'+id:'')+(cls?'.'+cls:'');}
  function nodeName(n){const pseudo=n.pseudoType?.();if(pseudo)return '::'+pseudo;const t=n.nodeType();if(t===1)return n.localName?.()||n.nodeName().toLowerCase();if(t===10)return n.nodeName();return n.nodeName();}
  function layoutOf(n){const t=n.layoutContextType;const v=typeof t==='function'?t.call(n):t;if(v)return /grid/i.test(v)?'grid':/flex/i.test(v)?'flex':null;const f=n.layoutFlags;const flags=typeof f==='function'?f.call(n):f;if(Array.isArray(flags))return flags.includes('grid')?'grid':flags.includes('flex')?'flex':null;return null;}
  function origin(rule){if(!rule)return '';const T=WI.CSSStyleSheet?.Type||{};switch(rule.type){case T.UserAgent:return 'user-agent';case T.User:return 'user';case T.Inspector:return 'inspector';default:return 'author';}}
  function inheritable(name){try{if(WI.CSSProperty.isInheritedPropertyName)return WI.CSSProperty.isInheritedPropertyName(name);if(WI.CSSKeywordCompletions?.InheritedProperties)return WI.CSSKeywordCompletions.InheritedProperties.has(name);}catch(e){}return /^(color|font|line-height|letter-spacing|word-spacing|text-(align|indent|transform|shadow|rendering)|white-space|direction|visibility|cursor|quotes|list-style|color-scheme|-webkit-locale|tab-size|hyphens|caret-color|accent-color|border-collapse|border-spacing|caption-side|empty-cells|orphans|widows|writing-mode)/.test(name)||name.startsWith('--');}
  function treeOf(n,depth=0){if(!n||depth>100)return null;const type=n.nodeType(),name=n.nodeName(),attributes=n.attributes()||[];let label=type===1?'<'+name.toLowerCase():name;for(const a of attributes)label+=' '+a.name+'="'+a.value+'"';if(type===1)label+='>';else if(n.nodeValue())label+=' '+n.nodeValue();const children=domChildren(n);
    const out={id:n.id,type,label,count:n.childNodeCount||children.length,children:children.map(c=>treeOf(c,depth+1)).filter(Boolean),name:nodeName(n)};
    if(type===1){out.attrs=attributes.map(a=>[a.name,a.value]);const l=layoutOf(n);if(l)out.layout=l;}
    else if(type===3||type===8)out.value=n.nodeValue();
    else if(type===11)out.value=n.shadowRootType?.()||null;
    else if(type===9)out.value=n.documentURL||null;
    return out;}
  function stylesOf(node){const s=WI.cssManager.stylesForNode(node);return s;}
  async function fresh(s){if(s.refreshIfNeeded)await s.refreshIfNeeded();else if(s.refresh)await s.refresh();}
  function declOut(st,key,node){
    const T=WI.CSSStyleDeclaration.Type,rule=st.ownerRule,kind=st.type===T.Inline?'inline':st.type===T.Attribute?'attributes':'rule';
    const o=kind==='rule'?origin(rule):'author';
    const tag=(st.node&&nodeName(st.node))||nodeName(node);
    const selector=kind==='inline'?'element.style':kind==='attributes'?tag+'[Attributes Style]':(rule?.selectorText||'');
    const loc=rule?.sourceCodeLocation;const source=loc?.sourceCode?.url||rule?.sourceURL||'';
    const line=loc?(loc.lineNumber+1):0;
    const ua=o==='user-agent';
    const all=st.properties||[];
    // The declarations written in the rule; WebKit's own sheet has only
    // longhands, its shorthands' parts marked implicit, and all of them show.
    const shown=all.filter(q=>ua||!q.implicit);
    const seen=new Set();
    const properties=shown.filter(q=>{if(!ua)return true;if(seen.has(q.name))return false;seen.add(q.name);return true;}).map(q=>({index:all.indexOf(q),name:q.name,value:q.value,text:q.text||'',enabled:q.enabled!==false,overridden:!!q.overridden,valid:q.valid!==false,
      dim:!!st.inherited&&!inheritable(q.name),longhands:(q.relatedLonghandProperties||[]).map(l=>({name:l.name,value:l.value,overridden:!!l.overridden}))}));
    return {key,selector,origin:o,source,line,kind,inheritedFrom:st.inherited?crumb(st.node):'',editable:!!st.editable&&!ua,text:st.text||'',styleId:st.id||{},properties};
  }
  W.fn['elements.select']=async p=>{
    B.selected=p.id;
    await call('DOM.setInspectedNode',{nodeId:p.id});
    const node=WI.domManager.nodeForId(p.id);
    const [ax,listeners]=await Promise.all([call('DOM.getAccessibilityPropertiesForNode',{nodeId:p.id}).catch(e=>({error:e.message})),
      call('DOM.getEventListenersForNode',{nodeId:p.id,includeAncestors:true}).catch(e=>({error:e.message}))]);
    const out={id:p.id,styles:[],computed:[],from:{},accessibility:ax.properties||ax,listeners:[]};
    B.styleKeys=new Map();
    if(node&&node.nodeType()===1){
      const s=stylesOf(node);await fresh(s);
      let k=0;
      for(const st of s.orderedStyles||[]){
        if(st.type===WI.CSSStyleDeclaration.Type.Computed)continue;
        if(st.ownerRule&&origin(st.ownerRule)==='user')continue;
        if(st.inherited&&!(st.properties||[]).some(q=>inheritable(q.name)))continue;
        const key='s'+(k++);B.styleKeys.set(key,st);out.styles.push(declOut(st,key,node));
      }
      const computed=s.computedStyle?.properties||[];
      out.computed=computed.map(q=>({name:q.name,value:q.value,implicit:!!q.implicit}));
      for(const q of computed){
        const e=s.effectivePropertyForName?.(q.name);if(!e)continue;
        const st=e.ownerStyle,rule=st?.ownerRule;if(rule&&origin(rule)==='user')continue;
        const T=WI.CSSStyleDeclaration.Type;
        out.from[q.name]={value:e.value,selector:st?.type===T.Inline?'element.style':st?.type===T.Attribute?crumb(st.node||node)+'[Attributes Style]':(rule?.selectorText||''),
          source:rule?.sourceCodeLocation?.sourceCode?.url||'',line:rule?.sourceCodeLocation?(rule.sourceCodeLocation.lineNumber+1):0,origin:rule?origin(rule):'author'};
      }
    }
    const scripts=new Map();for(const t of WI.targets||[]){try{for(const sc of WI.debuggerManager.dataForTarget(t).scripts)scripts.set(String(sc.id),sc);}catch(e){}}
    for(const [k,v] of B.scripts)if(!scripts.has(String(v.id)))scripts.set(String(v.id),v);
    for(const l of listeners.listeners||[]){
      const sc=l.location?scripts.get(String(l.location.scriptId)):null;
      // yab's relays are user scripts (user-script:N, in their world or the
      // page's): the browser's, not the page's listeners.
      if(sc&&(/^user-script:/.test(sc.url||'')||sc.sourceURL?.startsWith('__yab')))continue;
      const owner=l.onWindow?'window':crumb(WI.domManager.nodeForId(l.nodeId));
      out.listeners.push({id:l.eventListenerId,type:l.type,owner,ownerId:l.onWindow?0:(l.nodeId||0),useCapture:!!l.useCapture,passive:!!l.passive,once:!!l.once,disabled:!!l.disabled,
        handler:l.handlerName||'',url:sc?.url||sc?.sourceURL||'',line:l.location?l.location.lineNumber+1:0});
    }
    return json(out);
  };
  // What a Styles name or value being typed may become, from WebKit's own
  // CSS completions: every property name, or the keywords of a property,
  // starting with the words typed (WI.CSSCompletions), the likeliest first.
  W.fn['elements.complete']=async p=>{
    const prefix=String(p.prefix||'').toLowerCase(),most=p.max||12;
    let source=null;
    try{source=p.part==='name'?WI.cssManager?.propertyNameCompletions:WI.CSSKeywordCompletions?.forProperty?.(p.property);}catch(e){}
    if(!source)return json([]);
    let list=[];
    try{list=typeof source.startsWith==='function'?source.startsWith(prefix):[];}catch(e){}
    if(!Array.isArray(list)||!list.length){const all=source.values||source._values||[];list=all.filter(x=>String(x).toLowerCase().startsWith(prefix));}
    list=[...new Set(list.map(String))].filter(x=>!x.startsWith('-webkit-')||prefix.startsWith('-'));
    list.sort((a,b)=>a.length-b.length||a.localeCompare(b));
    return json(list.slice(0,most));
  };
  W.fn['elements.prop']=async p=>{
    const st=B.styleKeys?.get(p.key);if(!st)throw new Error('This rule changed; select the element again');
    await call('DOM.markUndoableState').catch(()=>{});
    const all=st.properties||[];
    if(p.add){
      const text=(st.text||'').replace(/\s*$/,'');
      const sep=text&&!/;\s*$/.test(text)?';':'';
      await setText(st,text+sep+(text?'\n':'')+p.name+': '+p.value+';');
    }else{
      const q=all[p.index];if(!q)throw new Error('This declaration changed; select the element again');
      if(typeof p.enabled==='boolean'){
        if(q.commentOut)q.commentOut(!p.enabled);else await replace(st,q,p.enabled?q.text.replace(/^\/\*\s*|\s*\*\/$/g,''):'/* '+q.text+' */');
      }else{
        const name=p.name??q.name,value=p.value??q.value;
        if(!name)await replace(st,q,'');else await replace(st,q,name+': '+value+';');
      }
    }
    await new Promise(r=>setTimeout(r,60));
    const sheet=st.ownerRule?.ownerStyleSheet||st.ownerStyleSheet;const id=sheet?.id||st.id?.styleSheetId;
    if(!id)return json({});
    const t=await call('CSS.getStyleSheetText',{styleSheetId:id}).catch(()=>null);
    return json({url:sheet?.url||st.ownerRule?.sourceCodeLocation?.sourceCode?.url||'',text:t?.text||''});
  };
  async function setText(st,text){if(Object.getOwnPropertyDescriptor(WI.CSSStyleDeclaration.prototype,'text')?.set){st.text=text;await new Promise(r=>setTimeout(r,50));return;}await call('CSS.setStyleText',{styleId:st.id,text});}
  async function replace(st,q,text){
    const old=q.text||'';const body=st.text||'';const at=old?body.indexOf(old):-1;
    const next=at>=0?body.slice(0,at)+text+body.slice(at+old.length):body+(text?'\n'+text:'');
    await setText(st,next);
  }
  W.fn['elements.addRule']=async p=>{
    const node=WI.domManager.nodeForId(p.id);if(!node)throw new Error('No element');
    const selector=crumb(node);
    const s=stylesOf(node);
    if(s.addRule){await s.addRule(selector,'');await new Promise(r=>setTimeout(r,300));return true;}
    const tree=await call('Page.getResourceTree');const sheet=await call('CSS.createStyleSheet',{frameId:tree.frameTree.frame.id});
    await call('CSS.addRule',{styleSheetId:sheet.styleSheetId,selector});return true;
  };
  W.fn['elements.class']=async p=>{
    const r=await call('DOM.resolveNode',{nodeId:p.id,objectGroup:'yab-elements'});
    await call('Runtime.callFunctionOn',{objectId:r.object.objectId,functionDeclaration:'function(n,on){this.classList.toggle(n,on);return true}',arguments:[{value:p.name},{value:!!p.on}],returnByValue:true});return true;
  };
  W.fn['elements.attributes']=async p=>{
    const node=WI.domManager.nodeForId(p.id);if(!node)throw new Error('No element');
    await call('DOM.markUndoableState').catch(()=>{});
    const parsed=new DOMParser().parseFromString('<x '+p.text+'></x>','text/html').body.firstElementChild;
    const keep=new Set(parsed?[...parsed.attributes].map(a=>a.name):[]);
    for(const a of node.attributes()||[])if(!keep.has(a.name))await call('DOM.removeAttribute',{nodeId:p.id,name:a.name});
    if(p.text.trim())await call('DOM.setAttributesAsText',{nodeId:p.id,text:p.text});
    return true;
  };
  W.fn['elements.nodeProperties']=async p=>{
    const r=await call('DOM.resolveNode',{nodeId:p.id,objectGroup:'yab-elements'});
    const v=await call('Runtime.callFunctionOn',{objectId:r.object.objectId,returnByValue:true,functionDeclaration:`function(){const out=[];const own=new Set(Object.keys(this));for(const k in this){let v;try{v=this[k]}catch(e){continue}const t=v===null?'object':typeof v;let preview;if(t==='string')preview=JSON.stringify(v.length>200?v.slice(0,200)+'…':v);else if(t==='object'&&v){preview=v.constructor?.name||'Object';if(v instanceof Node)preview=v.nodeName.toLowerCase()+(v.id?'#'+v.id:'');else if(typeof v.length==='number')preview+=' ('+v.length+')';}else if(t==='function')preview='ƒ '+(v.name||k)+'()';else preview=String(v);out.push({name:k,type:t,preview:v===null?'null':preview,own:own.has(k)||this.hasAttribute?.(k)});}out.sort((a,b)=>a.name.localeCompare(b.name,'en',{sensitivity:'base'}));return out}`});
    const rows=v.result?.value||[];
    // Objects open as the console's trees: their handles asked for once the list is in.
    const handles=await call('Runtime.getProperties',{objectId:r.object.objectId,ownProperties:false,generatePreview:false}).catch(()=>({}));
    const ids=new Map();for(const x of handles.result||handles.properties||[])if(x.value?.objectId&&x.value.type==='object')ids.set(x.name,{id:x.value.objectId,subtype:x.value.subtype||''});
    for(const row of rows){const h=ids.get(row.name);if(h&&row.type==='object'&&row.preview!=='null'){row.objectId=h.id;row.subtype=h.subtype;}}
    return json(rows);
  };
  W.fn['elements.layouts']=async()=>{
    const r=await call('Runtime.evaluate',{expression:"[...document.querySelectorAll('*')].filter(e=>{const d=getComputedStyle(e).display;return /grid|flex/.test(d)}).slice(0,200)",objectGroup:'yab-layouts'});
    const out=[];if(!r.result?.objectId)return json(out);
    const props=await call('Runtime.getProperties',{objectId:r.result.objectId,ownProperties:true});
    for(const x of props.result||props.properties||[]){
      if(!/^\d+$/.test(x.name)||!x.value?.objectId)continue;
      const n=await call('DOM.requestNode',{objectId:x.value.objectId}).catch(()=>null);if(!n)continue;
      const d=await call('Runtime.callFunctionOn',{objectId:x.value.objectId,functionDeclaration:'function(){return getComputedStyle(this).display}',returnByValue:true});
      const node=WI.domManager.nodeForId(n.nodeId);
      out.push({id:n.nodeId,kind:/grid/.test(d.result?.value||'')?'grid':'flex',label:node?crumb(node):''});
    }
    await call('Runtime.releaseObjectGroup',{objectGroup:'yab-layouts'}).catch(()=>{});
    return json(out);
  };
  W.fn['elements.axTree']=async()=>{
    const root=await documentRoot();
    const body=WI.domManager.nodeForId(root.id)?.body||[...(root.children||[])].flatMap(c=>c.children||[]).find(c=>c.nodeName?.()==='BODY');
    let count=0;
    async function ax(id,depth){
      if(count++>800||depth>40)return null;
      const a=(await call('DOM.getAccessibilityPropertiesForNode',{nodeId:id}).catch(()=>null))?.properties;
      if(!a||!a.exists)return null;
      const kids=[];for(const c of a.childNodeIds||[]){const x=await ax(c,depth+1);if(x)kids.push(x);}
      if(a.ignored)return kids.length===1?kids[0]:{id,role:'',name:'',children:kids};
      const words=a.label||(a.role==='text'?(WI.domManager.nodeForId(id)?.nodeValue?.()||'').trim():'');
      return {id,role:a.role==='text'?'StaticText':(a.role||''),name:words,children:kids};
    }
    const top=await ax(body?body.id:root.id,0);const title=(await call('Runtime.evaluate',{expression:'document.title',returnByValue:true}).catch(()=>null))?.result?.value||'';
    return json({id:root.id,role:'RootWebArea',name:title,children:top?(top.role?[top]:top.children):[]});
  };
  W.fn['elements.html']=async p=>json(await call('DOM.getOuterHTML',{nodeId:p.id}));
  W.fn['elements.editHTML']=async p=>{await call('DOM.markUndoableState');await call('DOM.setOuterHTML',{nodeId:p.id,outerHTML:p.html});return true;};
  W.fn['elements.style']=async p=>{await call('DOM.markUndoableState');return json(await call('CSS.setStyleText',{styleId:p.styleId,text:p.text}));};
  // The node pointed at, measured for Chrome's drawing of it (DevHighlight
  // .swift), as Blink's InspectorHighlight builds it: its four boxes as
  // quads in the top page's CSS pixels, through the frames it is in; a
  // node with no box (display: none, head, a comment, collapsed white
  // space) draws nothing; a text node its own box; an SVG shape its box
  // alone; an inline's top and bottom margins left out; a scrollbar in
  // the padding box, not the content; a transformed box turned as it is
  // drawn. `inspect`, the picker's, adds Chrome's style and accessibility
  // rows. Read only, in the page's world.
  // The boxes a node scrolls with, between it and its document (and the
  // document itself in a frame), each by its path from the document
  // (children's places, "s" a shadow root's way in) and how far it was
  // scrolled: Yab's drawing finds them in its own world and moves the
  // node's boxes with them on each scroll, at once, as Chromium's overlay
  // follows the node. Not past a fixed box, which they don't move.
  const SCROLLERS=`function pathOf(a){
      const steps=[];
      for(let n=a;n;){
        const p=n.parentNode;
        if(!p)return null;
        if(p.nodeType===11){if(!p.host||p.mode!=='open')return null;steps.push([...p.children].indexOf(n),'s');n=p.host;continue;}
        steps.push([...p.children].indexOf(n));
        if(p.nodeType===9)break;
        n=p;
      }
      return steps.reverse();
    }
    function scrollers(e){
      const out=[];
      if(!e)return out;
      const doc=e.ownerDocument,win=doc.defaultView,lift=a=>a.parentElement||(a.parentNode&&a.parentNode.host)||null;
      if(win.getComputedStyle(e).position==='fixed')return out;
      for(let a=lift(e);a;a=lift(a)){
        const cs=win.getComputedStyle(a),clipped=v=>v!=='visible'&&v!=='clip';
        if(a!==doc.scrollingElement&&(clipped(cs.overflowX)||clipped(cs.overflowY))&&(a.scrollHeight>a.clientHeight||a.scrollWidth>a.clientWidth)){const p=pathOf(a);if(p)out.push([p,a.scrollLeft,a.scrollTop]);}
        if(cs.position==='fixed')return out;
      }
      let top=true;try{top=win===win.top;}catch(_){top=false;}
      const se=doc.scrollingElement;
      if(!top&&se){const p=pathOf(se);if(p)out.push([p,se.scrollLeft,se.scrollTop]);}
      return out;
    }`;
  const MEASURE=`function(inspect){
    const n=this,doc=n.ownerDocument||n,win=doc.defaultView;
    if(n.nodeType!==1&&n.nodeType!==3)return null;
    const e=n.nodeType===1?n:null;
    let r;
    if(e){if(!e.getClientRects().length)return null;r=e.getBoundingClientRect();}
    else{const g=doc.createRange();g.selectNodeContents(n);if(!g.getClientRects().length)return null;r=g.getBoundingClientRect();}
    const xhtml=doc.contentType==='application/xhtml+xml';
    const out={r:[r.left,r.top,r.width,r.height],tag:e?(xhtml?e.nodeName:e.nodeName.toLowerCase()):'#text',w:r.width,h:r.height};
    const up=a=>a.parentElement||(a.parentNode&&a.parentNode.host)||null;
    out.fixed=false;
    for(let a=e||n.parentElement;a;a=up(a))if(win.getComputedStyle(a).position==='fixed'){out.fixed=true;break;}
    ${SCROLLERS}
    out.sc=scrollers(e||n.parentElement);
    const quad=(x,y,w,h)=>[[x,y],[x+w,y],[x+w,y+h],[x,y+h]];
    if(!e){out.q={content:quad(r.left,r.top,r.width,r.height)};return out;}
    const s=win.getComputedStyle(e),f=k=>parseFloat(s[k])||0;
    if(e.namespaceURI==='http://www.w3.org/2000/svg'&&e.ownerSVGElement){out.q={content:quad(r.left,r.top,r.width,r.height)};}
    else{
      const b=[f('borderTopWidth'),f('borderRightWidth'),f('borderBottomWidth'),f('borderLeftWidth')];
      const p=[f('paddingTop'),f('paddingRight'),f('paddingBottom'),f('paddingLeft')];
      const inline=s.display==='inline';
      const m=[inline?0:f('marginTop'),f('marginRight'),inline?0:f('marginBottom'),f('marginLeft')];
      out.b=b;out.p=p;out.m=m;
      const bar=(offset,client,a,z,flow)=>!inline&&flow!=='visible'&&typeof offset==='number'&&offset-client-a-z>=2?offset-client-a-z:0;
      const sv=bar(e.offsetWidth,e.clientWidth,b[1],b[3],s.overflowY),sh=bar(e.offsetHeight,e.clientHeight,b[0],b[2],s.overflowX);
      let L=new win.DOMMatrix(),turned=false;
      for(let a=e;a;a=up(a)){
        const cs=win.getComputedStyle(a),M=new win.DOMMatrix();
        if(cs.rotate&&cs.rotate!=='none'){const v=cs.rotate.trim().split(/\\s+/),t=v[v.length-1],k=/rad$/.test(t)?180/Math.PI:/turn$/.test(t)?360:/grad$/.test(t)?0.9:1;if(v.length===1||v[0]==='z'||(v.length===4&&+v[0]===0&&+v[1]===0))M.rotateSelf(parseFloat(t)*k);}
        if(cs.scale&&cs.scale!=='none'){const v=cs.scale.trim().split(/\\s+/).map(parseFloat);M.scaleSelf(v[0],v.length>1?v[1]:v[0]);}
        if(cs.transform&&cs.transform!=='none'){try{M.multiplySelf(new win.DOMMatrix(cs.transform));}catch(_){}}
        if(!M.isIdentity){turned=true;L=M.multiply(L);}
      }
      let W=r.width,H=r.height,map=(x,y)=>[r.left+x,r.top+y];
      if(turned){
        let w=parseFloat(s.width),h=parseFloat(s.height);
        if(s.boxSizing!=='border-box'){w+=p[1]+p[3]+b[1]+b[3];h+=p[0]+p[2]+b[0]+b[2];}
        if(isFinite(w)&&isFinite(h)){W=w;H=h;const cx=r.left+r.width/2,cy=r.top+r.height/2;map=(x,y)=>{const vx=x-W/2,vy=y-H/2;return [cx+L.a*vx+L.c*vy,cy+L.b*vx+L.d*vy];};}
      }
      const q=(x,y,w,h)=>{w=Math.max(0,w);h=Math.max(0,h);return [map(x,y),map(x+w,y),map(x+w,y+h),map(x,y+h)];};
      out.q={content:q(b[3]+p[3],b[0]+p[0],W-b[3]-b[1]-p[3]-p[1]-sv,H-b[0]-b[2]-p[0]-p[2]-sh),padding:q(b[3],b[0],W-b[3]-b[1],H-b[0]-b[2]),border:q(0,0,W,H),margin:q(-m[3],-m[0],W+m[3]+m[1],H+m[0]+m[2])};
    }
    out.id=e.id||'';out.cls=[...e.classList].map(c=>'.'+c).join('');
    out.layout=/grid/.test(s.display)?'grid':/flex/.test(s.display)?'flex':null;
    // A flex item's base size, as Blink's BuildFlexItemInfo: flex-basis in
    // pixels, else with flex-basis auto its width (height in a column) in
    // pixels; none known, nothing drawn. The computed values, not the used.
    const parent=up(e),ps=parent&&parent.nodeType===1?win.getComputedStyle(parent):null;
    if(ps&&/flex/.test(ps.display)&&s.position!=='absolute'&&s.position!=='fixed'&&e.computedStyleMap){
      const horizontal=/^horizontal/.test(ps.writingMode||'horizontal-tb')!==/^column/.test(ps.flexDirection);
      const map=e.computedStyleMap(),px=v=>v&&v.unit==='px'&&typeof v.value==='number'?v.value:null;
      let basis=null,size=null,auto=false;
      try{basis=map.get('flex-basis');size=map.get(horizontal?'width':'height');auto=basis&&basis.value==='auto';}catch(_){}
      const base=px(basis)!==null?px(basis):auto&&px(size)!==null?px(size):null;
      if(base!==null)out.item={base,horizontal,border:s.boxSizing==='border-box'};
    }
    // A flex container's items and a grid's tracks, for Chrome's lines and hatching.
    const rect=x=>{const q=x.getBoundingClientRect();return [q.left,q.top,q.width,q.height];};
    if(out.layout==='flex'){
      out.flex={horizontal:!/^column/.test(s.flexDirection),items:[...e.children].filter(c=>{const cs=win.getComputedStyle(c);return cs.display!=='none'&&cs.position!=='absolute'&&cs.position!=='fixed';}).map(rect)};
    }else if(out.layout==='grid'){
      const tracks=v=>(v||'').replace(/\\[[^\\]]*\\]/g,' ').trim().split(/\\s+/).map(parseFloat).filter(x=>isFinite(x));
      out.grid={cols:tracks(s.gridTemplateColumns),rows:tracks(s.gridTemplateRows),colGap:parseFloat(s.columnGap)||0,rowGap:parseFloat(s.rowGap)||0};
    }
    if(!inspect)return out;
    const rgba=c=>{const m=/^rgba?\\(([^)]+)\\)/.exec(c||'');if(!m)return null;const v=m[1].split(/[\\s,\\/]+/).filter(Boolean).map(parseFloat);return [v[0],v[1],v[2],v.length>3?v[3]:1];};
    const hex=c=>{const v=rgba(c);if(!v)return c?{css:c,text:c}:null;if(!v[3])return null;const h=x=>Math.round(x).toString(16).padStart(2,'0').toUpperCase();return {css:c,text:'#'+h(v[0])+h(v[1])+h(v[2])+(v[3]<1?h(v[3]*255):'')};};
    out.style={color:hex(s.color),font:s.fontSize!=='0px'?s.fontSize+' '+s.fontFamily:'',background:hex(s.backgroundColor),margin:s.margin,padding:s.padding};
    const a11y={focusable:e.tabIndex>=0&&!e.disabled&&!(e.localName==='a'&&!e.hasAttribute('href'))&&e.getClientRects().length>0};
    if([...e.childNodes].some(c=>c.nodeType===3&&c.nodeValue.trim())){
      const fg=rgba(s.color);let layers=[],plain=true;
      for(let a=e;a&&a.nodeType===1;a=a.parentElement){const cs=win.getComputedStyle(a);if(cs.backgroundImage!=='none'){plain=false;break;}const b=rgba(cs.backgroundColor);if(b&&b[3]){layers.push(b);if(b[3]>=1)break;}}
      if(fg&&fg[3]&&plain){
        let bg=[255,255,255];for(const l of layers.reverse())bg=bg.map((c,i)=>l[i]*l[3]+c*(1-l[3]));
        const ink=fg.slice(0,3).map((c,i)=>c*fg[3]+bg[i]*(1-fg[3]));
        const lum=c=>{const v=c.map(x=>{x/=255;return x<=0.03928?x/12.92:Math.pow((x+0.055)/1.055,2.4);});return 0.2126*v[0]+0.7152*v[1]+0.0722*v[2];};
        const L1=lum(ink),L2=lum(bg),size=parseFloat(s.fontSize),bold=parseInt(s.fontWeight)>=700;
        const css=c=>'rgb('+c.map(Math.round).join(' ')+')';
        a11y.contrast={fg:css(ink),bg:css(bg),ratio:(Math.max(L1,L2)+0.05)/(Math.min(L1,L2)+0.05),need:size>=24||(size>=18.66&&bold)?3:4.5};
      }
    }
    out.a11y=a11y;return out;
  }`;
  // A frame's content box in its parent's viewport, and whether it stays
  // put as that page scrolls (in a fixed box).
  const ORIGIN=`function(){const r=this.getBoundingClientRect(),s=getComputedStyle(this),f=k=>parseFloat(s[k])||0;let fixed=false;for(let a=this;a;a=a.parentElement||(a.parentNode&&a.parentNode.host)||null)if(getComputedStyle(a).position==="fixed"){fixed=true;break;}${SCROLLERS}return [r.left+f("borderLeftWidth")+f("paddingLeft"),r.top+f("borderTopWidth")+f("paddingTop"),fixed,pathOf(this),scrollers(this)];}`;
  async function onNode(id,fn,args=[]){
    const o=await call('DOM.resolveNode',{nodeId:id,objectGroup:'yab-highlight'});
    if(!o.object?.objectId)return null;
    const r=await call('Runtime.callFunctionOn',{objectId:o.object.objectId,functionDeclaration:fn,arguments:args,returnByValue:true});
    return r.wasThrown?null:r.result?.value;
  }
  const HL={content:'rgba(111, 168, 220, 0.66)',padding:'rgba(147, 196, 125, 0.55)',border:'rgba(255, 229, 153, 0.66)',margin:'rgba(246, 178, 107, 0.66)',target:'rgba(255, 196, 196, 0.66)'};
  // Through each frame the node is in, to the top page: the offset, whether
  // the outermost frame (or the node itself) scrolls with the page, and the
  // boxes it scrolls with, each path from the top document ("f" a frame's
  // way in).
  async function placeOf(id,m){
    let ox=0,oy=0,fixed=!!m.fixed,sc=m.sc||[];
    for(let n=WI.domManager.nodeForId(id);n;n=n.parentNode){
      if(n.nodeType()===9&&n.parentNode&&n.parentNode.nodeType()===1){
        const o=await onNode(n.parentNode.id,ORIGIN);
        if(!o)continue;
        ox+=o[0];oy+=o[1];fixed=!!o[2];
        sc=(o[3]?sc.map(x=>[o[3].concat(['f'],x[0]),x[1],x[2]]):[]).concat(o[2]?[]:o[4]||[]);
      }
    }
    return {ox,oy,fixed,sc};
  }
  async function highlightOf(id,inspect,target){
    try{
      const m=await onNode(id,MEASURE,[{value:!!inspect}]);
      if(!m)return null;
      const {ox,oy,fixed,sc}=await placeOf(id,m);
      const at=pt=>[pt[0]+ox,pt[1]+oy];
      const boxes=['content','padding','border','margin'].filter(k=>m.q&&m.q[k]).map(k=>({q:m.q[k].map(at),fill:HL[k]}));
      if(!boxes.length)return null;
      // Shift in inspect mode: the node the event itself reaches, its border
      // box in Chrome's eventTargetColor, after the node's own (AppendEventTargetQuads).
      if(target&&target!==id){
        const t=await onNode(target,MEASURE,[{value:false}]);
        const tq=t&&t.q&&(t.q.border||t.q.content);
        if(tq){const pl=await placeOf(target,t);boxes.push({q:tq.map(pt=>[pt[0]+pl.ox,pt[1]+pl.oy]),fill:HL.target});}
      }
      // A flex item's base size and flexibility, on its border box (its
      // content box under box-sizing: content-box).
      const item=m.item&&boxes.length>=3?{base:m.item.base,horizontal:m.item.horizontal,q:(m.item.border?boxes[2]:boxes[0]).q}:null;
      const cq=boxes[0].q,xs=cq.map(v=>v[0]),ys=cq.map(v=>v[1]);
      const info={tag:m.tag,id:m.id,cls:m.cls,w:m.w,h:m.h,layout:m.layout,style:m.style};
      const content=[Math.min(...xs),Math.min(...ys),Math.max(...xs)-Math.min(...xs),Math.max(...ys)-Math.min(...ys)];
      let layout=null;
      if(m.flex){
        // Items in lines, as Chromium groups them: a new line where one wraps.
        const at=r=>[r[0]+ox,r[1]+oy,r[2],r[3]],lines=[];
        for(const r of m.flex.items.map(at)){
          const line=lines[lines.length-1],h=m.flex.horizontal;
          const end=line&&Math.max(...line.map(q=>h?q[1]+q[3]:q[0]+q[2]));
          if(line&&(h?r[1]:r[0])<end-0.5)line.push(r);else lines.push([r]);
        }
        layout={kind:'flex',horizontal:m.flex.horizontal,container:content,lines};
      }else if(m.grid){
        layout=Object.assign({kind:'grid',container:content},m.grid);
      }
      if(inspect&&m.a11y){
        const a=await WI.mainTarget.DOMAgent.getAccessibilityPropertiesForNode?.invoke({nodeId:id}).catch(()=>null);
        const pr=a?.properties||{};
        info.a11y=Object.assign(m.a11y,{name:pr.label||'',role:pr.role||(pr.exists===false?'':'generic')});
      }
      return {boxes,info,layout,fixed,sc,item};
    }catch(e){return null;}
    finally{call('Runtime.releaseObjectGroup',{objectGroup:'yab-highlight'}).catch(()=>{});}
  }
  B.highlightSerial=0;
  async function highlight(id,inspect,target){
    const serial=++B.highlightSerial;
    if(!id){W.highlight(null);return true;}
    const d=await highlightOf(id,inspect,target);
    if(serial===B.highlightSerial)W.highlight(d);
    return true;
  }
  // For the bench: what would be drawn for a node, and what the picker points at.
  W.fn['elements.highlightOf']=async p=>json(await highlightOf(p.id,!!p.inspect,p.target||0));
  W.fn['elements.pickState']=async()=>{const n=B.pickHover&&WI.domManager.nodeForId(B.pickHover),t=B.pickTarget&&WI.domManager.nodeForId(B.pickTarget);return json({picking:!!B.picking,native:!!B.pickNative,hover:B.pickHover||0,name:n?nodeName(n):'',idAttr:n?.getAttribute?.('id')||'',target:B.pickTarget||0,targetIdAttr:t?.getAttribute?.('id')||''});};
  W.fn['elements.nodeOf']=async p=>{const n=WI.domManager.nodeForId(p.id);if(n&&p.children&&n.childNodeCount&&!n.children?.length)await new Promise(r=>n.getChildNodes(r));return json(n?{name:nodeName(n),idAttr:n.getAttribute?.('id')||'',type:n.nodeType(),children:(n.children||[]).map(c=>[c.id,c.nodeType(),c.nodeName()]),shadows:(n.shadowRoots?.()||[]).map(c=>c.id)}:null);};
  W.fn['elements.highlight']=async p=>{call('DOM.hideHighlight').catch(()=>{});B.hoverId=p.id||0;B.hoverAt=performance.now();return await highlight(p.id,false);};
  // Measured again while pointed at: a scroller inside the page, a
  // layout that moved, as Chromium follows the node.
  W.beats.push(async()=>{
    if(!B.hoverId||B.picking||B.hoverBusy||performance.now()-(B.hoverAt||0)<250)return;
    B.hoverBusy=true;B.hoverAt=performance.now();
    const id=B.hoverId;
    try{const serial=B.highlightSerial,d=await highlightOf(id,false);if(B.hoverId===id&&serial===B.highlightSerial)W.highlight(d);}
    finally{B.hoverBusy=false;}
  });
  W.fn['elements.properties']=async p=>{const n=await call('DOM.resolveNode',{nodeId:p.id,objectGroup:'yab-elements'});return json(await call('Runtime.getProperties',{objectId:n.object.objectId,ownProperties:true}));};
  W.fn['elements.action']=async p=>{
    await call('DOM.markUndoableState');
    const r=await call('DOM.resolveNode',{nodeId:p.id,objectGroup:'yab-elements'});
    const code={addClass:"this.classList.add(...value.split(/\\s+/).filter(Boolean))",hide:"const c='__web-inspector-hide-shortcut__';this.classList.toggle(c);let top=this;while(top.parentNode)top=top.parentNode;if(top.nodeType===9)top=top.head||top.documentElement;if(!top.querySelector('style#__web-inspector-hide-shortcut-style__')){const s=document.createElement('style');s.id='__web-inspector-hide-shortcut-style__';s.textContent='\\n.__web-inspector-hide-shortcut__, .__web-inspector-hide-shortcut__ *\\n{\\n    visibility: hidden !important;\\n}\\n';top.appendChild(s);}",duplicate:"this.after(this.cloneNode(true))",scroll:"this.scrollIntoView({block:'center',inline:'nearest'})",text:"this.textContent=value",selector:"return this.id?'#'+CSS.escape(this.id):this.tagName.toLowerCase()+[...this.classList].map(c=>'.'+CSS.escape(c)).join('')"}[p.action];
    if(!code)throw new Error('Unknown element action');
    const result=await call('Runtime.callFunctionOn',{objectId:r.object.objectId,functionDeclaration:'function(value){'+code+';return true}',arguments:[{value:p.value||''}],returnByValue:true});
    if(result.wasThrown)throw new Error(result.result.description);return result.result.value;
  };
  // Where a paused frame is in the file a source map names, when its
  // script has one: Sources shows that file, as Chromium does.
  function mappedAt(location,target){
    try{
      const s=WI.debuggerManager.scriptForIdentifier(location.scriptId,target||WI.mainTarget);
      if(!s||!s.sourceMaps?.length)return null;
      const at=s.createSourceCodeLocation(location.lineNumber,location.columnNumber||0),shown=at.displaySourceCode;
      return shown instanceof WI.SourceMapResource?{url:shown.url,line:at.displayLineNumber}:null;
    }catch(e){return null;}
  }
  W.fn['sources.files']=async()=>{
    // A bundle's own files as its source map names them (WebKit's
    // inspector fetches the maps itself, WI.SourceMapManager), listed beside
    // the bundle as Chromium's Sources lists them.
    B.mapped=new Map();
    for(const t of WI.targets||[]){try{for(const s of WI.debuggerManager.dataForTarget(t).scripts){if(s.injected||s.sourceURL?.startsWith('__yab')){B.scripts.delete(t.identifier+':'+s.id);continue;}B.scripts.set(t.identifier+':'+s.id,{id:s.id,url:s.url||'',line:s.range?.startLine||0,target:t.identifier||'',injected:s.injected,sourceURL:s.sourceURL});for(const m of s.sourceMaps||[])for(const r of m.resources||[])if(r.url&&!B.mapped.has(r.url))B.mapped.set(r.url,{resource:r,target:t.identifier||''});}}catch(e){}}
    const r=await call('Page.getResourceTree');let files=[];
    function frame(f){if(!f)return;files.push({id:'',url:f.frame.url,type:'document'});for(const x of f.resources||[])files.push({id:'',url:x.url,type:x.type,frame:f.frame.id});for(const c of f.childFrames||[])frame(c);}
    frame(r.frameTree);
    const scripts=[...B.scripts.values()].filter(s=>s.url&&!s.injected&&!s.sourceURL?.startsWith('__yab')&&/^https?:|^file:|^blob:/.test(s.url));
    const documents=new Set(files.filter(f=>f.type.toLowerCase()==='document').map(f=>f.url));const external=scripts.filter(s=>!documents.has(s.url));const urls=new Set(external.map(s=>s.url));files=files.filter(f=>!urls.has(f.url));
    const mapped=[...B.mapped.entries()].map(([url,m])=>({id:'',url,type:'source-mapped',target:m.target}));
    const unique=new Map();for(const file of external.concat(files,mapped))unique.set(file.url+':'+(file.target||''),file);return json([...unique.values()]);
  };
  W.fn['sources.content']=async p=>{
    if(p.id)return json(await call('Debugger.getScriptSource',{scriptId:p.id,__target:p.target||''}));
    const m=B.mapped?.get(p.url);
    if(m){const c=await m.resource.requestContent();return json({scriptSource:c?.content??c?.rawContent??''});}
    const r=await call('Page.getResourceTree');let frameId=p.frame||r.frameTree.frame.id;
    const c=await call('Page.getResourceContent',{frameId,url:p.url});return json({scriptSource:c.base64Encoded?atob(c.content):c.content});
  };
  // A line of a file a source map names (src/app.ts) is a place in the
  // bundle the page runs: the breakpoint goes on the bundle's line and
  // column the map gives for it, as Chromium sets it.
  W.fn['sources.breakpoint']=async p=>{
    let url=p.url,line=p.line,column=p.column||0,target=p.target||'';
    if(!B.mapped)await W.fn['sources.files']();
    const m=B.mapped?.get(p.url);
    if(m){
      const at=m.resource.createSourceCodeLocation(p.line,column),raw=at.sourceCode;
      url=raw.url||raw.resource?.url||'';line=at.lineNumber;column=at.columnNumber;target=m.target||target;
      if(!url)throw new Error('No bundle for '+p.url);
    }
    const r=await call('Debugger.setBreakpointByUrl',{url,lineNumber:line,columnNumber:column,options:{condition:p.condition||'',autoContinue:!!p.logpoint,actions:p.logpoint?[{type:'log',data:p.logpoint}]:[]},__target:target});
    return json(Object.assign({},r,{at:{url,line,column,target}}));
  };
  // { } in Sources: a file pretty printed by WebKit's own formatter (the
  // inspector's FormatterWorker), with, for each of its lines, where that
  // line starts in the file as the page has it, for breakpoints and the
  // paused line to go between the two.
  W.fn['sources.pretty']=p=>new Promise((resolve,reject)=>{
    const worker=WI.FormatterWorkerProxy?.singleton?.(),indent='    ';
    if(!worker)return reject(new Error('WebKit has no formatter'));
    const done=r=>{
      try{
        if(!r||r.formattedText==null)return reject(new Error('This file could not be formatted'));
        const map=WI.FormatterSourceMap.fromSourceMapData(r.sourceMapData),lines=r.formattedText.split('\n');
        const back=lines.map((l,i)=>{const o=map.formattedToOriginal(i,l.length-l.trimStart().length);return [o.lineNumber,o.columnNumber];});
        resolve(json({text:r.formattedText,back}));
      }catch(e){reject(e);}
    };
    if(p.language==='css'){if(typeof worker.formatCSS!=='function')return reject(new Error('WebKit has no CSS formatter'));worker.formatCSS(String(p.text||''),indent,true,done);}
    else worker.formatJavaScript(String(p.text||''),!!p.module,indent,true,done);
  });
  W.fn['sources.scope']=async p=>json(await call('Runtime.getProperties',{objectId:p.objectId,ownProperties:true,__target:p.target||''}));
  W.fn['sources.evaluate']=async p=>json(await call('Debugger.evaluateOnCallFrame',{callFrameId:p.frame,expression:p.expression,objectGroup:'yab-watch',includeCommandLineAPI:true,returnByValue:false,generatePreview:true,__target:p.target||''}));
  W.fn['performance.record']=async p=>{
    if(p.on){B.events=[];B.memory=[];B.recording=true;await call('Memory.enable').catch(e=>{if(!/already enabled/i.test(String(e)))throw e});await call('Memory.startTracking');await call('Timeline.setInstruments',{instruments:['Timeline','ScriptProfiler','CPU','Memory'].concat(p.screenshots?['Screenshot']:[])});await call('Timeline.start',{maxCallStackDepth:20});}
    else{await call('Timeline.stop');await call('Memory.stopTracking');B.recording=false;}
    return json({recording:B.recording,records:B.events,memory:B.memory});
  };
  W.fn['performance.metrics']=async()=>await page("JSON.stringify((()=>{if(!window.__yabVitals){window.__yabVitals={lcp:null,inp:null,interactions:[]};for(const type of ['largest-contentful-paint','event']){if(!PerformanceObserver.supportedEntryTypes?.includes(type))continue;new PerformanceObserver(list=>{for(const e of list.getEntries()){if(type==='largest-contentful-paint')window.__yabVitals.lcp={time:e.startTime,url:e.url,element:e.element?.outerHTML?.slice(0,300),size:e.size};else if(e.interactionId){window.__yabVitals.inp=Math.max(window.__yabVitals.inp||0,e.duration);window.__yabVitals.interactions.push({name:e.name,duration:e.duration,inputDelay:e.processingStart-e.startTime,processing:e.processingEnd-e.processingStart,presentation:e.startTime+e.duration-e.processingEnd});if(window.__yabVitals.interactions.length>100)window.__yabVitals.interactions.shift()}}}).observe({type,buffered:true,durationThreshold:16})}}return {navigation:performance.getEntriesByType('navigation').map(e=>e.toJSON()),paint:performance.getEntriesByType('paint').map(e=>e.toJSON()),measures:performance.getEntriesByType('measure').map(e=>e.toJSON()),marks:performance.getEntriesByType('mark').map(e=>e.toJSON()),nodes:document.getElementsByTagName('*').length,vitals:window.__yabVitals,supported:PerformanceObserver.supportedEntryTypes}})())");
  W.fn['application.storage']=async p=>json(await call('DOMStorage.getDOMStorageItems',{storageId:{securityOrigin:p.origin,isLocalStorage:p.local}}));
  W.fn['application.setStorage']=async p=>{await call('DOMStorage.setDOMStorageItem',{storageId:{securityOrigin:p.origin,isLocalStorage:p.local},key:p.key,value:p.value});return true;};
  W.fn['application.removeStorage']=async p=>{await call('DOMStorage.removeDOMStorageItem',{storageId:{securityOrigin:p.origin,isLocalStorage:p.local},key:p.key});return true;};
  W.fn['application.info']=async()=>{
    return await page("(async()=>JSON.stringify({url:location.href,origin:location.origin,manifest:document.querySelector('link[rel=manifest]')?.href||'',workers:navigator.serviceWorker?await navigator.serviceWorker.getRegistrations().then(rs=>rs.map(r=>({scope:r.scope,script:r.active?.scriptURL,state:r.active?.state,waiting:r.waiting?.scriptURL,installing:r.installing?.scriptURL}))):[],databases:indexedDB.databases?await indexedDB.databases():[],caches:typeof caches!=='undefined'?await caches.keys():[]}))()");
  };
  W.fn['application.manifest']=async()=>await page("(async()=>{const u=document.querySelector('link[rel=manifest]')?.href;if(!u)return JSON.stringify({status:'No web app manifest linked'});const r=await fetch(u);if(!r.ok)throw new Error('Manifest HTTP '+r.status);return JSON.stringify(await r.json())})()");
  W.fn['application.updateWorker']=async p=>await page("navigator.serviceWorker.getRegistrations().then(async rs=>{const r=rs.find(r=>r.scope==="+json(p.scope)+");if(!r)throw new Error('Service worker no longer exists');await r.update();return true})");
  W.fn['application.unregister']=async p=>await page("navigator.serviceWorker.getRegistrations().then(async rs=>{const r=rs.find(r=>r.scope==="+json(p.scope)+");return r?await r.unregister():false})");
  W.fn['application.cache']=async p=>await page("(async()=>{if(!(await caches.keys()).includes("+json(p.name)+"))throw new Error('Cache no longer exists');const c=await caches.open("+json(p.name)+");const keys=await c.keys();return JSON.stringify(await Promise.all(keys.map(async q=>{const r=await c.match(q);return {url:q.url,status:r.status,type:r.type,headers:Object.fromEntries(r.headers)}})))})()");
  W.fn['application.database']=async p=>await page("(async()=>{if(!(await indexedDB.databases()).some(d=>d.name==="+json(p.name)+"))throw new Error('Database no longer exists');return new Promise((resolve,reject)=>{const q=indexedDB.open("+json(p.name)+");q.onerror=()=>reject(q.error);q.onsuccess=()=>{const db=q.result;const r={version:db.version,stores:[...db.objectStoreNames]};db.close();resolve(JSON.stringify(r))}})})()");
  W.fn['application.records']=async p=>await page("(async()=>{const p="+json(p)+";if(!(await indexedDB.databases()).some(d=>d.name===p.name))throw new Error('Database no longer exists');return new Promise((resolve,reject)=>{const q=indexedDB.open(p.name);q.onerror=()=>reject(q.error);q.onsuccess=()=>{const db=q.result;let tx;try{tx=db.transaction(p.store,'readonly')}catch(e){db.close();reject(e);return}const s=tx.objectStore(p.store);const rows=[];const c=s.openCursor();let skip=Math.max(0,Math.floor(p.offset||0));const limit=Math.max(1,Math.min(201,Math.floor(p.limit||200)));c.onsuccess=()=>{const x=c.result;if(x&&skip){skip=0;x.advance(Math.floor(p.offset));return}if(x&&rows.length<limit){rows.push({key:x.key,value:x.value});x.continue()}else{db.close();resolve(JSON.stringify(rows))}};c.onerror=()=>{db.close();reject(c.error)}}})})()");
  W.fn['application.writeRecord']=async p=>await page("(async()=>{const p="+json(p)+";if(!(await indexedDB.databases()).some(d=>d.name===p.name))throw new Error('Database no longer exists');return new Promise((resolve,reject)=>{const q=indexedDB.open(p.name);q.onerror=()=>reject(q.error);q.onsuccess=()=>{const db=q.result;let tx;try{tx=db.transaction(p.store,'readwrite');const s=tx.objectStore(p.store);const key=JSON.parse(p.key);if(p.remove)s.delete(key);else if(s.keyPath)s.put(JSON.parse(p.value));else s.put(JSON.parse(p.value),key)}catch(e){db.close();reject(e);return}tx.oncomplete=()=>{db.close();resolve(true)};tx.onerror=()=>{db.close();reject(tx.error)}}})})()");
  W.fn['application.cacheEntry']=async p=>await page("(async()=>{const p="+json(p)+";if(!(await caches.keys()).includes(p.name))throw new Error('Cache no longer exists');const c=await caches.open(p.name);if(p.remove)return c.delete(p.url);const r=await c.match(p.url);if(!r)throw new Error('Response no longer exists');const body=await r.text();return JSON.stringify({url:p.url,status:r.status,headers:Object.fromEntries(r.headers),body:p.full?body:body.slice(0,65536),truncated:!p.full&&body.length>65536,length:body.length})})()");
  W.fn['application.clearStorage']=async()=>await page("(async()=>{localStorage.clear();sessionStorage.clear();for(const name of await caches.keys())await caches.delete(name);for(const d of await indexedDB.databases())await new Promise((resolve,reject)=>{const q=indexedDB.deleteDatabase(d.name);q.onsuccess=resolve;q.onerror=()=>reject(q.error);q.onblocked=()=>reject(new Error('Close database connections before clearing '+d.name))});return true})()");
  W.fn['application.quota']=async()=>await page("(async()=>JSON.stringify(navigator.storage?.estimate?await navigator.storage.estimate():{status:'Storage estimate is unavailable'}))()");
  W.fn['memory.snapshot']=async()=>json(await call('Heap.snapshot'));
  W.fn['audit.run']=async()=>{
    const r=await call('Runtime.evaluate',{expression:"JSON.stringify({title:document.title,url:location.href,language:document.documentElement.lang,viewport:!!document.querySelector('meta[name=viewport]'),images:[...document.images].filter(e=>!e.hasAttribute('alt')).map(e=>({url:e.src,html:e.outerHTML.slice(0,250)})),buttons:[...document.querySelectorAll('button,a[href]')].filter(e=>!e.textContent.trim()&&!e.getAttribute('aria-label')&&!e.getAttribute('aria-labelledby')).map(e=>e.outerHTML.slice(0,250)),inputs:[...document.querySelectorAll('input:not([type=hidden]),textarea,select')].filter(e=>!e.labels?.length&&!e.getAttribute('aria-label')&&!e.getAttribute('aria-labelledby')).map(e=>e.outerHTML.slice(0,250)),headings:[...document.querySelectorAll('h1')].map(e=>e.textContent),secure:isSecureContext,navigation:performance.getEntriesByType('navigation').map(e=>e.toJSON()),paint:performance.getEntriesByType('paint').map(e=>e.toJSON()),resources:performance.getEntriesByType('resource').map(e=>({url:e.name,duration:e.duration,size:e.transferSize}))})",returnByValue:true,objectGroup:'yab-audit'});return r.result.value;
  };
  W.fn['audit.axe']=async p=>await page("(()=>{"+p.script+";return axe.run(document,{resultTypes:['violations','passes','incomplete'],reporter:'v2'}).then(r=>JSON.stringify({violations:r.violations.map(v=>({id:v.id,impact:v.impact,description:v.description,help:v.help,helpUrl:v.helpUrl,nodes:v.nodes.map(n=>({html:n.html,target:n.target,failureSummary:n.failureSummary}))})),passes:r.passes.length,incomplete:r.incomplete.length}))})()");
  W.fn['tools.animations']=async()=>await page("JSON.stringify(document.getAnimations().map((a,i)=>({id:i,name:a.animationName||a.transitionProperty||'Animation',state:a.playState,time:a.currentTime,rate:a.playbackRate,timing:a.effect?.getComputedTiming(),keyframes:a.effect?.getKeyframes()})))");
  W.fn['tools.animation']=async p=>await page("(()=>{const a=document.getAnimations()["+Number(p.id)+"];if(!a)throw new Error('Animation is gone');"+(p.action==='pause'?'a.pause()':p.action==='play'?'a.play()':p.action==='rate'?'a.playbackRate='+Number(p.value):'a.currentTime='+Number(p.value))+";return true})()");
  W.fn['tools.media']=async()=>await page("JSON.stringify([...document.querySelectorAll('video,audio')].map((e,i)=>({id:i,url:e.currentSrc,paused:e.paused,time:e.currentTime,duration:Number.isFinite(e.duration)?e.duration:null,ready:e.readyState,network:e.networkState,error:e.error?.message||'',width:e.videoWidth,height:e.videoHeight,volume:e.volume,muted:e.muted})))");
  W.fn['tools.cssOverview']=async()=>await page("JSON.stringify((()=>{const colors={},fonts={},media=[];for(const e of document.querySelectorAll('*')){const s=getComputedStyle(e);for(const k of ['color','backgroundColor','borderColor']){const v=s[k];colors[v]=(colors[v]||0)+1}fonts[s.fontFamily]=(fonts[s.fontFamily]||0)+1}for(const sheet of document.styleSheets){try{for(const r of sheet.cssRules)if(r.media)media.push(r.conditionText)}catch(e){}}return {colors,fonts,media}})())");
  W.fn['tools.buffer']=async p=>await page("JSON.stringify((()=>{const a=("+p.expression+");const u=a instanceof ArrayBuffer?new Uint8Array(a):ArrayBuffer.isView(a)?new Uint8Array(a.buffer,a.byteOffset,a.byteLength):null;if(!u)throw new Error('Expression must return ArrayBuffer or typed array');return {size:u.length,bytes:[...u.slice("+Number(p.offset||0)+","+(Number(p.offset||0)+256)+")]}})())");
  W.fn['tools.coverage']=async()=>{
    const r=[];let failure='';for(const t of WI.targets||[]){for(const s of WI.debuggerManager.dataForTarget(t)?.scripts||[]){if(!s.url||s.injected||s.sourceURL?.startsWith('__yab'))continue;try{const b=await call('Runtime.getBasicBlocks',{sourceID:s.id,__target:t.identifier});r.push({url:s.url,blocks:b.basicBlocks||[]})}catch(e){failure=String(e)}}}if(!r.length&&failure)throw new Error(failure);
    return json(r);
  };
  W.fn['tools.layers']=async p=>{await call('LayerTree.enable');let id=p.id||(p.id===0?0:B.selected);if(!id){B.root=(await documentRoot()).id;const q=await call('DOM.querySelector',{nodeId:B.root,selector:'body'});id=q.nodeId;}return json(await call('LayerTree.layersForNode',{nodeId:id}));};
  W.fn['tools.forms']=async()=>await page("JSON.stringify([...document.querySelectorAll('input,textarea,select')].map(e=>({name:e.name,type:e.type,id:e.id,autocomplete:e.autocomplete,label:e.labels?.[0]?.textContent||e.getAttribute('aria-label')||'',value:e.type==='password'?'[redacted]':e.value})))");
  W.fn['tools.audioStart']=async()=>await page("(()=>{if(window.__yabAudio)return true;const S=window.__yabAudio={contexts:[],nodes:[],edges:[],original:window.AudioContext,methods:[]};const ids=new WeakMap();function node(n,context){if(ids.has(n))return n;const id=S.nodes.length;ids.set(n,id);S.nodes.push({id,node:n,context});const connect=n.connect,disconnect=n.disconnect;n.connect=function(to,...args){const result=Reflect.apply(connect,this,[to,...args]);if(ids.has(to))S.edges.push({from:id,to:ids.get(to),output:args[0]||0,input:args[1]||0});return result};n.disconnect=function(...args){const result=Reflect.apply(disconnect,this,args);S.edges=S.edges.filter(e=>e.from!==id||(args.length&&e.to!==ids.get(args[0])));return result};S.methods.push(()=>{n.connect=connect;n.disconnect=disconnect});return n}window.AudioContext=new Proxy(S.original,{construct(t,args,newTarget){const c=Reflect.construct(t,args,newTarget),index=S.contexts.length;S.contexts.push(c);node(c.destination,index);for(const key of ['createOscillator','createGain','createAnalyser','createBiquadFilter','createBufferSource','createChannelMerger','createChannelSplitter','createConvolver','createDelay','createDynamicsCompressor','createMediaElementSource','createMediaStreamSource','createMediaStreamDestination','createPanner','createStereoPanner','createWaveShaper']){if(typeof c[key]!=='function')continue;const old=c[key];c[key]=function(...a){return node(Reflect.apply(old,this,a),index)};S.methods.push(()=>{c[key]=old})}return c}});return true})()");
  W.fn['tools.audio']=async()=>await page("JSON.stringify((()=>{const S=window.__yabAudio;return {contexts:(S?.contexts||[]).map((c,id)=>({id,state:c.state,sampleRate:c.sampleRate,currentTime:c.currentTime,baseLatency:c.baseLatency,outputLatency:c.outputLatency})),nodes:(S?.nodes||[]).map(({id,node:n,context})=>({id,context,type:n.constructor.name,channels:n.channelCount,gain:n.gain?.value,frequency:n.frequency?.value})),edges:S?.edges||[]}})())");
  W.fn['tools.audioStop']=async()=>await page("(()=>{const S=window.__yabAudio;if(S){window.AudioContext=S.original;S.methods.forEach(undo=>undo());delete window.__yabAudio}return true})()");
  W.fn['tools.webmcp']=async()=>await page("(async()=>{const c=document.modelContext||navigator.modelContextTesting;if(!c)return JSON.stringify({available:false,tools:[]});const tools=await (c.getTools?c.getTools():c.listTools?c.listTools():[]);return JSON.stringify({available:true,api:document.modelContext?'document.modelContext':'navigator.modelContextTesting',tools:tools.map(t=>({name:t.name,title:t.title,description:t.description,inputSchema:t.inputSchema,annotations:t.annotations,origin:t.origin||location.origin}))})})()");
  W.fn['tools.webmcpRun']=async p=>await page("(async()=>{const c=document.modelContext||navigator.modelContextTesting;if(!c)throw Error('WebMCP is unavailable on this page');const p="+json(p)+",tools=await(c.getTools?c.getTools():c.listTools()),tool=tools.find(t=>t.name===p.name);if(!tool)throw Error('This tool has been unregistered');const args=JSON.parse(p.input||'{}');if(!args||Array.isArray(args)||typeof args!=='object')throw Error('Arguments must be a JSON object');const abort=new AbortController;window.__yabToolAbort=abort;try{return JSON.stringify({result:await c.executeTool(document.modelContext?tool:p.name,args,{signal:abort.signal})})}finally{if(window.__yabToolAbort===abort)delete window.__yabToolAbort}})()");
  W.fn['tools.webmcpCancel']=async()=>await page("(()=>{window.__yabToolAbort?.abort();return true})()");
  W.fn['tools.performanceMonitor']=async()=>await page("JSON.stringify({nodes:document.getElementsByTagName('*').length,resources:performance.getEntriesByType('resource').length,time:performance.now(),animations:document.getAnimations().length,frames:frames.length})");
  W.fn['tools.sensorsReset']=async()=>await page("(()=>{const s=window.__yabSensors;if(s){navigator.geolocation.getCurrentPosition=s.position;navigator.geolocation.watchPosition=s.watch;for(const [key,value] of [['language',s.language],['hardwareConcurrency',s.threads]]){if(value)Object.defineProperty(navigator,key,value);else delete navigator[key]}delete window.__yabSensors}return true})()");
  W.fn['tools.sensors']=async p=>await page("(()=>{const c="+json(p)+";if(!window.__yabSensors)window.__yabSensors={position:navigator.geolocation.getCurrentPosition,watch:navigator.geolocation.watchPosition,language:Object.getOwnPropertyDescriptor(navigator,'language'),threads:Object.getOwnPropertyDescriptor(navigator,'hardwareConcurrency')};if(c.latitude!=null&&c.longitude!=null){navigator.geolocation.getCurrentPosition=(ok)=>ok({coords:{latitude:c.latitude,longitude:c.longitude,accuracy:10},timestamp:Date.now()});navigator.geolocation.watchPosition=(ok)=>{ok({coords:{latitude:c.latitude,longitude:c.longitude,accuracy:10},timestamp:Date.now()});return 0}}if(c.language)Object.defineProperty(navigator,'language',{configurable:true,get:()=>c.language});if(c.concurrency)Object.defineProperty(navigator,'hardwareConcurrency',{configurable:true,get:()=>c.concurrency});if(c.alpha!=null)dispatchEvent(new DeviceOrientationEvent('deviceorientation',{alpha:c.alpha,beta:c.beta||0,gamma:c.gamma||0}));return true})()");
})();
