// @vite/client: hot updates from the dev server, and what transformed
// modules call to take part in them.
const hmrHost = location.host;
const socketProtocol = location.protocol === 'https:' ? 'wss' : 'ws';
const sheets = new Map();

console.debug('[vite] connecting...');

// The socket is up once the dev server answers its first ping.
setTimeout(() => {
  console.debug('[vite] connected.');
  document.documentElement.dataset.viteHmr = `${socketProtocol}://${hmrHost}/`;
}, 30);

export function createHotContext(ownerPath) {
  const data = {};
  const noop = () => {};
  return {
    ownerPath,
    get data() {
      return data;
    },
    accept: noop,
    acceptExports: noop,
    dispose: noop,
    prune: noop,
    decline: noop,
    invalidate: noop,
    on: noop,
    off: noop,
    send: noop,
  };
}

export function updateStyle(id, content) {
  let style = sheets.get(id);
  if (!style) {
    style = document.createElement('style');
    style.setAttribute('type', 'text/css');
    style.setAttribute('data-vite-dev-id', id);
    document.head.appendChild(style);
    sheets.set(id, style);
  }
  style.textContent = content;
}

export function removeStyle(id) {
  const style = sheets.get(id);
  if (style) {
    style.remove();
    sheets.delete(id);
  }
}

export function injectQuery(url, queryToInject) {
  if (url[0] !== '.' && url[0] !== '/') return url;
  const { pathname, search, hash } = new URL(url, 'http://vite.dev');
  return `${pathname}?${queryToInject}${search ? '&' + search.slice(1) : ''}${hash || ''}`;
}
