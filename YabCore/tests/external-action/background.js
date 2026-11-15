// Exercise the original background-worker query used by Dark Reader. Unlike
// a popup's currentWindow, this has no sender BrowserWindow controller.
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message?.method !== 'native-active-tab') return false;
  (async () => {
    const queries = [];
    for (const query of [
      {active: true, lastFocusedWindow: true, windowType: 'normal'},
      {active: true, lastFocusedWindow: true, windowType: 'app'},
      {active: true, windowType: 'normal'},
      {active: true, windowType: 'app'},
    ]) {
      const tabs = await chrome.tabs.query(query);
      queries.push({query, tabs});
      if (tabs.length) return {tab: tabs[0], queries};
    }
    return {tab: null, queries};
  })().then(reply, error => reply({error: String(error)}));
  return true;
});
