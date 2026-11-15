(() => {
  const W=window.__yabWire;if(!W||W.application)return;W.application=true;
  const call=(m,p={})=>W.call(m,p),json=v=>JSON.stringify(v);let callID=0;
  function frames(tree,out=[],depth=0){if(!tree)return out;out.push({...tree.frame,resources:tree.resources||[],depth});for(const c of tree.childFrames||[])frames(c,out,depth+1);return out;}
  function context(frameID){const f=[...WI.networkManager.frames].find(f=>f.id===frameID);return f?.executionContextList?.contexts?.find(c=>c.type==='normal')||null;}
  async function page(p,fn,args={}){
    const tree=frames((await call('Page.getResourceTree')).frameTree);
    const selected=p.frame?tree.find(f=>f.id===p.frame):p.origin?tree.find(f=>{try{return new URL(f.url).origin===p.origin}catch(e){return false}}):tree[0];
    if(!selected)throw Error('The selected origin is no longer loaded. Refresh the Application tree.');
    const c=context(selected.id),main=selected.id===tree[0]?.id;
    let target=c?.target?.identifier||'';
    const expression='('+fn.toString()+')('+json(args)+')\n//# sourceURL=__yab_application';
    const group='yab-application-'+(++callID),params={expression,objectGroup:group,returnByValue:false,__target:target};if(c)params.contextId=c.id;
    try{
      let r;
      try{if(!c&&!main)throw Error('No execution context');r=await call('Runtime.evaluate',params)}catch(error){
        if(!/Missing injected script|No execution context/.test(String(error)))throw error;
        // A restored iframe can leave stale Runtime context ids in WebKit.
        // Resolve its actual document, never execute in a different frame.
        const root=await new Promise(resolve=>WI.domManager.requestDocument(resolve));
        if(!root)throw error;await new Promise(resolve=>root.getSubtree(-1,resolve));
        const seen=new Set();let documentNode=null;
        function walk(n){if(!n||seen.has(n.id))return;seen.add(n.id);if(n.nodeType()===9&&n.frame?.id===selected.id)documentNode=n;for(const child of n.children||[])walk(child);if(n._contentDocument)walk(n._contentDocument)}walk(root);
        if(!documentNode)throw Error('The selected frame document is no longer available');
        target=documentNode.owningTarget?.identifier||target;
        const resolved=await call('DOM.resolveNode',{nodeId:documentNode.backendNodeId??documentNode.id,objectGroup:group,__target:target});
        const declaration='function(){if(location.href!=='+json(selected.url)+')throw Error("Frame navigated during inspection");return ('+fn.toString()+')('+json(args)+')}';
        r=await call('Runtime.callFunctionOn',{objectId:resolved.object.objectId,functionDeclaration:declaration,returnByValue:false,__target:target});
      }
      if(r.wasThrown)throw Error(r.result?.description||'Application operation failed');
      if(r.result?.className==='Promise'||r.result?.subtype==='promise')r=await call('Runtime.awaitPromise',{promiseObjectId:r.result.objectId,returnByValue:true,__target:target});
      if(r.wasThrown)throw Error(r.result?.description||'Application operation failed');
      const v=r.result?.value;return typeof v==='string'?JSON.parse(v):v;
    }finally{await call('Runtime.releaseObjectGroup',{objectGroup:group,__target:target}).catch(()=>{});}
  }
  // Values remain JSON data. Structured-clone values have explicit previews.
  W.fn['application.snapshot']=async()=>{
    const list=frames((await call('Page.getResourceTree')).frameTree),origins=[];
    for(const f of list){try{f.origin=new URL(f.url).origin}catch(e){f.origin='null'};if(f.origin==='null'||origins.some(o=>o.origin===f.origin))continue;
      try{const data=await page({frame:f.id},async()=>{
        const workers=navigator.serviceWorker?await navigator.serviceWorker.getRegistrations():[];
        const dbs=indexedDB.databases?await indexedDB.databases():[];
        return JSON.stringify({origin:location.origin,url:location.href,secure:isSecureContext,notificationPermission:typeof Notification!=='undefined'?Notification.permission:'unavailable',databases:dbs,caches:typeof caches!=='undefined'?await caches.keys():[],workers:workers.map(r=>({scope:r.scope,updateViaCache:r.updateViaCache,active:r.active?{url:r.active.scriptURL,state:r.active.state}:null,waiting:r.waiting?{url:r.waiting.scriptURL,state:r.waiting.state}:null,installing:r.installing?{url:r.installing.scriptURL,state:r.installing.state}:null})),capabilities:{serviceWorker:'serviceWorker'in navigator,backgroundSync:typeof SyncManager!=='undefined',periodicSync:typeof PeriodicSyncManager!=='undefined',backgroundFetch:typeof BackgroundFetchManager!=='undefined',notifications:typeof Notification!=='undefined',push:typeof PushManager!=='undefined',reporting:typeof ReportingObserver!=='undefined',sharedStorage:'sharedStorage'in window,quota:!!navigator.storage?.estimate}});
      });origins.push({...data,frame:f.id})}catch(e){origins.push({origin:f.origin,frame:f.id,error:String(e),databases:[],caches:[],workers:[]})}
    }
    return json({frames:list,origins,top:list[0]?.id||''});
  };
  W.fn['application.manifest']=async p=>json(await page(p||{},async()=>{
    const link=document.querySelector('link[rel~=manifest]');if(!link)return JSON.stringify({missing:true,url:location.href});
    const response=await fetch(link.href,{credentials:link.crossOrigin==='use-credentials'?'include':'same-origin'});
    if(!response.ok)throw Error('Manifest HTTP '+response.status);
    let manifest;try{manifest=await response.json()}catch(e){throw Error('Manifest is not valid JSON: '+e.message)};
    if(!manifest||typeof manifest!=='object'||Array.isArray(manifest))throw Error('Manifest must be a JSON object');
    const warnings=[],resolve=s=>{try{return new URL(s,link.href).href}catch(e){return ''}};
    if(!manifest.name&&!manifest.short_name)warnings.push('No name or short_name specified.');
    const start=resolve(manifest.start_url||location.href),scope=resolve(manifest.scope||new URL('.',start).href);
    if(new URL(start).origin!==location.origin)warnings.push('start_url must have the same origin as the document.');
    if(!start.startsWith(scope))warnings.push('start_url is outside the manifest scope.');
    if(!['fullscreen','standalone','minimal-ui','browser'].includes(manifest.display||'browser'))warnings.push('Unrecognized display mode.');
    const icons=Array.isArray(manifest.icons)?manifest.icons.map(i=>({...i,url:resolve(i.src||'')})):[];
    if(!icons.length)warnings.push('No icons specified.');
    for(const icon of icons)if(!icon.src)warnings.push('An icon is missing its src.');
    return JSON.stringify({...manifest,url:link.href,manifest,start,scope,icons,screenshots:(manifest.screenshots||[]).map(i=>({...i,url:resolve(i.src||'')})),warnings});
  }));
  W.fn['application.frame']=async p=>{
    const list=frames((await call('Page.getResourceTree')).frameTree),f=list.find(f=>f.id===p.frame);if(!f)throw Error('Frame is no longer loaded');
    const details=await page(p,()=>JSON.stringify({url:location.href,origin:location.origin,title:document.title,secure:isSecureContext,isolated:crossOriginIsolated,referrer:document.referrer,policy:document.permissionsPolicy?.allowedFeatures?.()||document.featurePolicy?.allowedFeatures?.()||[],csp:[...document.querySelectorAll('meta[http-equiv="Content-Security-Policy" i]')].map(e=>e.content),api:{SharedArrayBuffer:typeof SharedArrayBuffer!=='undefined',serviceWorker:'serviceWorker'in navigator,WebMCP:!!document.modelContext,CacheStorage:'caches'in window},navigation:performance.getEntriesByType('navigation').map(n=>({type:n.type,activationStart:n.activationStart||0}))}));
    const resource=[...WI.networkManager.frames].find(x=>x.id===p.frame)?.mainResource;
    if(resource?.responseHeaders){details.headers=resource.responseHeaders;for(const [k,v]of Object.entries(details.headers))if(k.toLowerCase()==='content-security-policy')details.csp.push(v)}
    return json({...f,...details});
  };
  W.fn['application.notificationPermission']=async p=>json(await page(p,()=>JSON.stringify(typeof Notification==='undefined'?'unavailable':Notification.permission)));
  W.fn['application.quota']=async p=>json(await page(p||{},async()=>JSON.stringify(navigator.storage?.estimate?{...(await navigator.storage.estimate()),persistent:navigator.storage.persisted?await navigator.storage.persisted():null}:{unavailable:true})));
  W.fn['application.storage']=async p=>json(await call('DOMStorage.getDOMStorageItems',{storageId:{securityOrigin:p.origin,isLocalStorage:p.local}}));
  W.fn['application.clearDOMStorage']=async p=>{
    const id={securityOrigin:p.origin,isLocalStorage:p.local},r=await call('DOMStorage.getDOMStorageItems',{storageId:id});
    for(const entry of r.entries||[])await call('DOMStorage.removeDOMStorageItem',{storageId:id,key:entry[0]});return true;
  };
  W.fn['application.database']=async p=>json(await page(p,async p=>{
    if(!(await indexedDB.databases()).some(d=>d.name===p.name))throw Error('Database no longer exists');
    return new Promise((resolve,reject)=>{const q=indexedDB.open(p.name);q.onupgradeneeded=()=>{q.transaction.abort();reject(Error('Database no longer exists'))};q.onerror=()=>reject(q.error);q.onsuccess=()=>{const db=q.result,stores=[...db.objectStoreNames],schemas=stores.map(name=>{const s=db.transaction(name).objectStore(name);return{name,keyPath:s.keyPath,autoIncrement:s.autoIncrement,indexes:[...s.indexNames].map(name=>{const i=s.index(name);return{name,keyPath:i.keyPath,unique:i.unique,multiEntry:i.multiEntry}})}});db.close();resolve(JSON.stringify({name:db.name,version:db.version,stores,schemas}))}});
  },p));
  W.fn['application.records']=async p=>json(await page(p,async p=>{
    if(!(await indexedDB.databases()).some(d=>d.name===p.name))throw Error('Database no longer exists');
    return new Promise((resolve,reject)=>{const q=indexedDB.open(p.name);q.onupgradeneeded=()=>{q.transaction.abort();reject(Error('Database no longer exists'))};q.onerror=()=>reject(q.error);q.onsuccess=()=>{const db=q.result;let tx,s;try{tx=db.transaction(p.store,'readonly');s=tx.objectStore(p.store);if(p.index)s=s.index(p.index)}catch(e){db.close();reject(e);return};const keyValue=x=>x instanceof Date?{$type:'Date',value:x.toISOString()}:x instanceof ArrayBuffer||ArrayBuffer.isView(x)?(()=>{const b=x instanceof ArrayBuffer?new Uint8Array(x):new Uint8Array(x.buffer,x.byteOffset,x.byteLength);let raw='';for(let i=0;i<b.length;i+=8192)raw+=String.fromCharCode(...b.subarray(i,i+8192));return{$type:'Binary',base64:btoa(raw)}})():Array.isArray(x)?x.map(keyValue):x;
    const keyParse=x=>Array.isArray(x)?x.map(keyParse):x&&x.$type==='Date'?new Date(x.value):x&&x.$type==='Binary'?Uint8Array.from(atob(x.base64),c=>c.charCodeAt(0)).buffer:x;
    const rows=[];
    const preview=value=>{const seen=new WeakSet();let editable=true;const dates=new WeakSet();const scan=x=>{if(!x||typeof x!=='object'||dates.has(x))return;dates.add(x);if(x instanceof Date)editable=false;else if(Array.isArray(x)||Object.getPrototypeOf(x)===Object.prototype)Object.values(x).forEach(scan)};scan(value);const encoded=JSON.stringify(value,(_,x)=>{
      if(typeof x==='bigint'){editable=false;return{type:'BigInt',value:String(x)}}
      if(x===undefined){editable=false;return{type:'undefined'}}
      if(typeof x==='number'&&!Number.isFinite(x)){editable=false;return{type:'Number',value:String(x)}}
      if(x&&typeof x==='object'){
        if(seen.has(x)){editable=false;return{type:'Reference',value:'[Circular or shared reference]'}}seen.add(x);
        if(x instanceof Map){editable=false;return{type:'Map',entries:[...x]}}
        if(x instanceof Set){editable=false;return{type:'Set',values:[...x]}}
        if(x instanceof ArrayBuffer){editable=false;return{type:'ArrayBuffer',byteLength:x.byteLength}}
        if(ArrayBuffer.isView(x)){editable=false;return{type:x.constructor.name,byteLength:x.byteLength,values:Array.from(new Uint8Array(x.buffer,x.byteOffset,Math.min(x.byteLength,256)))}}
        if(typeof Blob!=='undefined'&&x instanceof Blob){editable=false;return{type:x.constructor.name,size:x.size,mime:x.type}}
        if(x instanceof RegExp){editable=false;return{type:'RegExp',value:String(x)}}
      }return x;
    });return{value:JSON.parse(encoded),editable}};
    let offset=Math.max(0,p.offset||0);const range=p.startKey?IDBKeyRange.lowerBound(keyParse(JSON.parse(p.startKey))):null;const req=s.openCursor(range);req.onsuccess=()=>{const c=req.result;if(c&&offset){const n=offset;offset=0;c.advance(n);return}if(c&&rows.length<Math.max(1,Math.min(501,p.limit||201))){rows.push({key:keyValue(c.key),primaryKey:keyValue(c.primaryKey),...preview(c.value)});c.continue()}else{db.close();resolve(JSON.stringify(rows))}};req.onerror=()=>{db.close();reject(req.error)}}});
  },p));
  W.fn['application.writeRecord']=async p=>json(await page(p,async p=>{
    const keyParse=x=>Array.isArray(x)?x.map(keyParse):x&&x.$type==='Date'?new Date(x.value):x&&x.$type==='Binary'?Uint8Array.from(atob(x.base64),c=>c.charCodeAt(0)).buffer:x;
    if(!(await indexedDB.databases()).some(d=>d.name===p.name))throw Error('Database no longer exists');
    return new Promise((resolve,reject)=>{const q=indexedDB.open(p.name);q.onerror=()=>reject(q.error);q.onupgradeneeded=()=>{q.transaction.abort();reject(Error('Database no longer exists'))};q.onsuccess=()=>{const db=q.result;let tx;try{tx=db.transaction(p.store,'readwrite');const s=tx.objectStore(p.store);if(p.remove)s.delete(keyParse(JSON.parse(p.key)));else if(s.keyPath!==null)s.put(JSON.parse(p.value));else if(p.key?.trim())s.put(JSON.parse(p.value),keyParse(JSON.parse(p.key)));else s.put(JSON.parse(p.value))}catch(e){db.close();reject(e);return}tx.oncomplete=()=>{db.close();resolve(true)};tx.onabort=tx.onerror=()=>{const e=tx.error;db.close();reject(e||Error('Database transaction failed'))}}});
  },p));
  W.fn['application.deleteDatabase']=async p=>json(await page(p,p=>new Promise((resolve,reject)=>{const q=indexedDB.deleteDatabase(p.name);q.onsuccess=()=>resolve(true);q.onerror=()=>reject(q.error);q.onblocked=()=>reject(Error('Close open database connections before deleting '+p.name))}),p));
  W.fn['application.clearStore']=async p=>json(await page(p,async p=>new Promise((resolve,reject)=>{const q=indexedDB.open(p.name);q.onerror=()=>reject(q.error);q.onupgradeneeded=()=>{q.transaction.abort();reject(Error('Database no longer exists'))};q.onsuccess=()=>{const db=q.result;let tx;try{tx=db.transaction(p.store,'readwrite');tx.objectStore(p.store).clear()}catch(e){db.close();reject(e);return}tx.oncomplete=()=>{db.close();resolve(true)};tx.onabort=()=>{db.close();reject(tx.error)}}}),p));
  W.fn['application.cache']=async p=>json(await page(p,async p=>{if(!(await caches.keys()).includes(p.name))throw Error('Cache no longer exists');const c=await caches.open(p.name);return JSON.stringify(await Promise.all((await c.keys()).map(async q=>{const r=await c.match(q);return{url:q.url,method:q.method,status:r.status,type:r.type,mime:r.headers.get('Content-Type')||'',headers:Object.fromEntries(r.headers)}})))},p));
  W.fn['application.cacheEntry']=async p=>json(await page(p,async p=>{if(!(await caches.keys()).includes(p.name))throw Error('Cache no longer exists');const c=await caches.open(p.name);if(p.remove)return JSON.stringify(await c.delete(p.url));const r=await c.match(p.url);if(!r)throw Error('Response no longer exists');const bytes=new Uint8Array(await r.arrayBuffer()),mime=r.headers.get('Content-Type')||'',text=/^(text\/|application\/(json|.*\+json|javascript|xml|.*\+xml))/i.test(mime),preview=p.full?bytes:bytes.slice(0,65536);let body;if(text)body=new TextDecoder().decode(preview);else{let raw='';for(let i=0;i<preview.length;i+=8192)raw+=String.fromCharCode(...preview.subarray(i,i+8192));body=btoa(raw)}return JSON.stringify({url:p.url,status:r.status,type:r.type,headers:Object.fromEntries(r.headers),body,base64:!text,truncated:!p.full&&bytes.length>65536,length:bytes.length})},p));
  W.fn['application.deleteCache']=async p=>json(await page(p,async p=>JSON.stringify(await caches.delete(p.name)),p));
  W.fn['application.workerAction']=async p=>json(await page(p,async p=>{
    const r=(await navigator.serviceWorker.getRegistrations()).find(r=>r.scope===p.scope);if(!r)throw Error('Service worker no longer exists');
    if(p.action==='update')await r.update();else if(p.action==='unregister')await r.unregister();else if(p.action==='skipWaiting'){if(!r.waiting)throw Error('No waiting worker');r.waiting.postMessage({type:'SKIP_WAITING'})}else throw Error('This worker action is not supported');return JSON.stringify(true);
  },p));
  W.fn['application.clearStorage']=async p=>json(await page(p||{},async p=>{
    const types=p.types||['local','session','indexedDB','cache'];const cleared=[];
    if(types.includes('workers')&&navigator.serviceWorker){for(const r of await navigator.serviceWorker.getRegistrations())await r.unregister();cleared.push('workers')}
    if(types.includes('local')){localStorage.clear();cleared.push('local')}if(types.includes('session')){sessionStorage.clear();cleared.push('session')}
    if(types.includes('cache')){for(const name of await caches.keys())await caches.delete(name);cleared.push('cache')}
    if(types.includes('indexedDB')){for(const d of await indexedDB.databases())await new Promise((resolve,reject)=>{const q=indexedDB.deleteDatabase(d.name);q.onsuccess=resolve;q.onerror=()=>reject(q.error);q.onblocked=()=>reject(Error('Close database connections before clearing '+d.name))});cleared.push('indexedDB')}
    return JSON.stringify({cleared});
  },p||{}));
  W.fn['application.resource']=async p=>{const r=await call('Page.getResourceContent',{frameId:p.frame,url:p.url});return json({body:r.base64Encoded?r.content:r.content,base64:!!r.base64Encoded})};
})();
