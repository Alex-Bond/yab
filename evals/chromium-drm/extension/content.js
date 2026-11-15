// This exact installed extension file executes on the WebKit page.
globalThis.bridgeEvents=[];
chrome.storage.onChanged.addListener((changes,area)=>bridgeEvents.push({changes,area}));
chrome.runtime.onMessage.addListener((message,sender,reply)=>{
  if(message.kind==='reverse')reply({nonce:message.nonce,id:chrome.runtime.id,url:location.href});
});
(async()=>{
  try{
    const nonce=crypto.randomUUID();
    const background=await chrome.runtime.sendMessage({kind:'acceptance',nonce});
    if(background.error)throw Error(background.error);
    const storage=await chrome.storage.local.get('witness');
    await chrome.runtime.sendMessage({kind:'storage-access',allow:false});
    let trustedStorageDenied=false;
    try{await chrome.storage.local.get('witness')}catch(error){trustedStorageDenied=true}
    await chrome.runtime.sendMessage({kind:'storage-access',allow:true});
    const allowedStorage=await chrome.storage.local.get('witness');
    const port=chrome.runtime.connect({name:'acceptance'});
    const portReply=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Port timeout')),10000);port.onMessage.addListener(value=>{clearTimeout(timer);resolve(value)});port.postMessage({nonce})});
    port.disconnect();
    globalThis.bridgeResult={id:chrome.runtime.id,nonce,background,storage,portReply,trustedStorageDenied,allowedStorage,i18n:chrome.i18n.getMessage('witness',['WebKit']),manifest:chrome.runtime.getManifest().name};
    const show=()=>{const marker=document.createElement('p');marker.id='bridge-witness';marker.textContent='Chromium extension background, storage, ports and WebKit scripting verified';document.body.append(marker)};
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',show,{once:true});else show();
  }catch(error){globalThis.bridgeResult={error:String(error)}}
})();
