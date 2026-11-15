#pragma once
// Compatibility for source SDKs predating the native options-creation receipt.
// Only an extension's own main-world document can use these native bindings.
// tabs.create supplies the original native receipt that runtime.openOptionsPage
// omitted in those SDKs. No WebKit manifest or content-script adaptation.
namespace yab_extension_options {
static const char kInstall[] = R"JS((()=>{
 if(location.protocol!=='chrome-extension:'||!globalThis.chrome?.runtime||
    chrome.runtime.id!==location.hostname||!chrome.tabs?.create||!chrome.tabs?.query)return;
 const runtime=chrome.runtime,tabs=chrome.tabs;
 if(runtime.openOptionsPage?.__yabOptionsReceipt)return;
 const original=runtime.openOptionsPage.bind(runtime);
 const manifest=runtime.getManifest(),path=manifest.options_ui?.page||manifest.options_page;
 if(!path)return;
 const url=runtime.getURL(path),query=tabs.query.bind(tabs),create=tabs.create.bind(tabs),update=tabs.update.bind(tabs);
 const open=done=>query({currentWindow:true},rows=>{
   if(runtime.lastError){done();return;}
   const existing=rows.find(t=>{try{const a=new URL(t.url),b=new URL(url);return a.protocol===b.protocol&&a.host===b.host&&a.pathname===b.pathname}catch{return false}});
   if(existing)update(existing.id,{active:true},()=>done());
   else create({url,active:true},()=>done());
 });
 runtime.openOptionsPage=function(callback){
   if(arguments.length>1||(callback!==undefined&&typeof callback!=='function'))return original(...arguments);
   if(typeof callback==='function'){open(callback);return;}
   return new Promise((resolve,reject)=>open(()=>{const error=runtime.lastError;if(error)reject(new Error(error.message));else resolve()}));
 };
 Object.defineProperty(runtime.openOptionsPage,'__yabOptionsReceipt',{value:true});
})())JS";
}
