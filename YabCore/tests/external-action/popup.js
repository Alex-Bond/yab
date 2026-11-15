// Use the original popup's own Chrome context and original current tab.
(async () => {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  const url = new URL(tab.url);
  const host = url.host;
  const key = 'site:' + host;
  const button = document.querySelector('#toggle');
  // A green-to-blue result only counts for the actual fixture owner returned
  // by the original popup's native tabs API, not the management browser.
  if (url.hostname !== '127.0.0.1' || url.pathname !== '/' || tab.title !== 'Popup owner') {
    button.textContent = 'Wrong native owner: ' + host;
    document.body.style.background = '#bc3543';
    return;
  }
  const background = await chrome.runtime.sendMessage({method: 'native-active-tab'});
  if (background?.error || background?.tab?.id !== tab.id || background?.tab?.url !== tab.url) {
    button.textContent = 'Wrong background owner: ' + (background?.tab?.url || background?.error || 'none');
    document.body.style.background = '#bc3543';
    return;
  }
  const state = await chrome.storage.local.get(key);
  let enabled = !!state[key];
  const paint = () => {
    button.textContent = host + ': ' + (enabled ? 'On' : 'Off');
    document.body.style.background = enabled ? '#1d4ed8' : '#12783c';
  };
  button.onclick = async () => {
    enabled = !enabled;
    await chrome.storage.local.set({[key]: enabled});
    paint();
  };
  paint();
})();
