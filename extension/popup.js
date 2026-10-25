/* The browser owns this toolbar popover; audio remains in the active page. */
(async () => {
  const api = globalThis.browser || globalThis.chrome;
  if (/Chrome|Chromium/u.test(navigator.userAgent)) document.documentElement.classList.add('chrome-popup');
  const connection = document.querySelector('#connection');
  let view; let tabId;
  api.runtime.onMessage.addListener((message, sender) => {
    if (message?.type === 'openread:state' && sender.tab?.id === tabId) view?.update(message.state);
  });
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true }); tabId = tab?.id;
    if (!tabId || !/^https?:/u.test(tab.url || '')) throw new Error('Open an article webpage to use OpenRead. Browser settings and PDF viewers cannot be read.');
    // Reconnect first. Reinjection must never reset an active page player when
    // the toolbar popup is reopened or recreated by Safari.
    let state;
    try { state = await api.tabs.sendMessage(tabId, { type: 'openread:get-state' }); } catch { /* first use on this page */ }
    if (!state?.preferences) {
      await api.scripting.executeScript({ target: { tabId }, files: ['core.js', 'extract.js', 'player.js', 'highlighter.js', 'content.js'] });
      state = await api.tabs.sendMessage(tabId, { type: 'openread:get-state' });
    }
    if (!state?.preferences) throw new Error('Could not connect to this page. Refresh it and reopen OpenRead.');
    view = new OpenReadSettings({ container: document.body, assetURL: file => api.runtime.getURL(file), popup: true,
      command: (action, value) => api.tabs.sendMessage(tabId, { type: 'openread:command', action, value }), dismiss: () => window.close() });
    view.update(state); connection.remove();
  } catch (error) {
    connection.textContent = error.message || 'OpenRead cannot read this page. Try a regular article webpage.';
    const link = document.createElement('a'); link.href = 'http://127.0.0.1:8765/'; link.target = '_blank'; link.textContent = 'Open library & tools';
    const paragraph = document.createElement('p'); paragraph.append(link); connection.append(paragraph);
  }
})();
