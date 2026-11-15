// Pages for linking an assistant with a code. No page on the relay can approve
// an action: those requests stay on the person's devices in sealed Sync.

export function escape(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// JSON that is safe inside a <script> element.
function data(value: unknown): string {
  return JSON.stringify(value).replace(/</g, "\\u003c").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
}

const STYLE = `
:root{color-scheme:light dark;--bg:#f2f2f7;--card:#fff;--ink:#1c1c1e;--muted:#6c6c70;--line:rgba(60,60,67,.14);
--well:#f2f2f7;--accent:#0a7cff;--accent-ink:#fff;--good:#1f9d55;--bad:#d70015}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--ink:#f2f2f7;--muted:#98989f;
--line:rgba(235,235,245,.16);--well:#2c2c2e;--accent:#0a84ff;--good:#30d158;--bad:#ff453a}}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--ink)}
body{min-height:100vh;min-height:100dvh;display:flex;align-items:center;justify-content:center;
padding:24px 16px calc(24px + env(safe-area-inset-bottom));
font:16px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;
-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%}
main{width:100%;max-width:420px;background:var(--card);border-radius:22px;padding:28px 24px 24px;
box-shadow:0 1px 2px rgba(0,0,0,.04),0 8px 28px rgba(0,0,0,.06)}
.brand{font-size:13px;font-weight:600;letter-spacing:.02em;color:var(--muted);margin:0 0 14px}
h1{font-size:22px;line-height:1.25;font-weight:700;margin:0 0 10px;letter-spacing:-.01em;overflow-wrap:anywhere}
p{margin:0 0 14px;color:var(--muted);overflow-wrap:anywhere}
p strong{color:var(--ink);font-weight:600}
.code{font:600 34px/1 ui-monospace,"SF Mono",Menlo,monospace;letter-spacing:.08em;text-align:center;
padding:22px 8px;margin:6px 0 18px;border-radius:16px;background:var(--well);color:var(--ink);
-webkit-user-select:all;user-select:all;white-space:nowrap}
ul{margin:4px 0 20px;padding:0;list-style:none;border-top:1px solid var(--line)}
li{padding:11px 0;border-bottom:1px solid var(--line);overflow-wrap:anywhere}
button{appearance:none;-webkit-appearance:none;display:block;width:100%;border:0;border-radius:14px;
font:inherit;font-weight:600;font-size:17px;padding:15px 16px;cursor:pointer;touch-action:manipulation}
button.primary{background:var(--accent);color:var(--accent-ink)}
button.quiet{background:transparent;color:var(--accent);margin-top:6px}
button:disabled{opacity:.45;cursor:default}
.status{display:flex;align-items:center;gap:10px;font-size:15px;color:var(--muted);margin:0;min-height:22px}
.spin{width:16px;height:16px;flex:none;border-radius:50%;border:2px solid var(--line);border-top-color:var(--muted);
animation:spin .9s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.outcome{margin:18px 0 0;padding:14px 16px;border-radius:14px;background:var(--well);color:var(--ink);font-weight:600}
.outcome.good{color:var(--good)} .outcome.bad{color:var(--bad)}
.outcome span{display:block;font-weight:400;color:var(--muted);margin-top:4px}
.foot{font-size:13px;margin:16px 0 0}
[hidden]{display:none!important}
`;

const HELPERS = `
const b64d=s=>{s=s.replace(/-/g,'+').replace(/_/g,'/');while(s.length%4)s+='=';return Uint8Array.from(atob(s),c=>c.charCodeAt(0));};
const b64e=b=>{b=new Uint8Array(b);let s='';for(const x of b)s+=String.fromCharCode(x);return btoa(s).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');};
const $=id=>document.getElementById(id);
function show(kind,title,text){const o=$('outcome');o.hidden=false;o.className='outcome '+(kind||'');o.textContent=title;
if(text){const s=document.createElement('span');s.textContent=text;o.appendChild(s);}}
async function post(body){const r=await fetch(location.pathname,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
try{return await r.json();}catch(e){return {};}}
`;

function page(title: string, body: string, script = "", brand = "Yab"): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex">
<title>${escape(title)}</title>
<style>${STYLE}</style>
</head>
<body>
<main>
<p class="brand">${escape(brand)}</p>
${body}
</main>
${script ? `<script>${script}</script>` : ""}
</body>
</html>`;
}

export function messagePage(title: string, text: string): string {
  return page(title, `<h1>${escape(title)}</h1><p>${escape(text)}</p>`);
}

const WHERE = "Settings › AI › Assistants › Enter Code";

export function authorizePage(o: { client: string; code: string; link: string }): string {
  const body = `
<h1>Connect ${escape(o.client)} to Yab</h1>
<p>Yab opens the consent sheet automatically when this page is in Yab. Otherwise choose <strong>${escape(WHERE)}</strong> and type:</p>
<div class="code" aria-label="Code">${escape(o.code)}</div>
<p class="status" id="status"><span class="spin" aria-hidden="true"></span><span id="status-text">Waiting for your yes in Yab on the Mac</span></p>
<p class="foot">The code works for 10 minutes. You can leave this page open; it moves on by itself.</p>`;
  const script = `
const link=${data(o.link)};
const text=t=>{document.getElementById('status-text').textContent=t;};
const stop=t=>{const s=document.querySelector('.spin');if(s)s.remove();text(t);};
async function poll(){
  try{
    const r=await fetch('/oauth/link/'+link,{cache:'no-store'});
    const s=await r.json();
    if(s.status==='allowed'){stop('Connected. Going back to '+${data(o.client)}+'.');location.replace(s.redirect);return;}
    if(s.status==='denied'){stop('Not connected.');location.replace(s.redirect);return;}
    if(s.status==='expired'){stop('This code expired. Start again from the assistant.');return;}
  }catch(e){}
  setTimeout(poll,2000);
}
setTimeout(poll,2000);`;
  return page(`Connect ${o.client} to Yab`, body, script);
}

export function connectPage(): string {
  return page(
    "Connect an assistant to Yab",
    `
<h1>Connect an assistant to Yab</h1>
<p>Your assistant showed you a code like <strong>K7QM-2XPA</strong>.</p>
<p>In Yab on your Mac, choose <strong>${escape(WHERE)}</strong>, type the code, and say yes. The assistant connects by itself a moment later.</p>
<p class="foot">Codes work for 10 minutes. Nothing needs to be typed on this page.</p>`,
  );
}
