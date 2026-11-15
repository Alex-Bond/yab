// What an extension may ask of any window: minimize it, then bring it back
// (chrome.windows.update state). Yab's page windows are hosted elsewhere and
// must stay ordered out through both.
chrome.runtime.onInstalled.addListener(async () => {
  for (const state of ['minimized', 'normal', 'minimized', 'normal']) {
    for (const window of await chrome.windows.getAll()) {
      try { await chrome.windows.update(window.id, {state}); } catch (error) {}
    }
    await new Promise(done => setTimeout(done, 750));
  }
});
