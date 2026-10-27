/* Safari's signed native host supplies on-device audio. No localhost service. */
const api = browser;
const native = message => api.runtime.sendNativeMessage('app.getopenread.reader', message);
api.runtime.onMessage.addListener((message, sender, respond) => {
  if (!sender.tab) return;
  if (message?.type === 'playbackState') {
    // Keep the toolbar quiet during normal playback. Safari's generated
    // background page can misdecode non-ASCII badge literals as mojibake.
    void api.action.setBadgeText({ tabId: sender.tab.id, text: message.error ? '!' : '' });
    void api.action.setTitle({ tabId: sender.tab.id, title: message.error || {
      playing: 'OpenRead - Playing', paused: 'OpenRead - Paused', loading: 'OpenRead - Preparing audio...'
    }[message.status] || 'OpenRead - Voice and playback settings' });
    respond({ ok: true }); return;
  }
  if (!['health', 'synthesize', 'saveDocument', 'openWorkspace'].includes(message?.type)) return;
  (async () => {
    if (message.type === 'openWorkspace') { await api.tabs.create({ url: 'openread://library' }); return { ok: true }; }
    if (message.type === 'synthesize' && (typeof message.text !== 'string' || message.text.length > 1600 || !/^kitten:(kiki|rosie|jasper|luna|bruno|hugo|leo|bella)$/u.test(message.voice))) return { ok: false, error: 'Choose an OpenRead voice and a shorter passage.' };
    if (message.type === 'saveDocument' && (typeof message.text !== 'string' || !message.text.trim() || message.text.length > 250000)) return { ok: false, error: 'Choose up to 250,000 characters to save.' };
    const request = message.type === 'saveDocument'
      ? { type: 'saveDocument', title: String(message.title || 'Saved reading').slice(0, 240), text: message.text, source: String(sender.tab.url || '').slice(0, 1000) }
      : { type: message.type, ...(message.type === 'synthesize' ? { text: message.text, voice: message.voice } : {}) };
    const result = await native(request);
    if (message.type === 'saveDocument' && result?.ok) await api.tabs.create({ url: 'openread://library' });
    return result;
  })().then(respond, () => respond({ ok: false, error: "OpenRead's Safari voice process could not respond. Try again, or save this page to the OpenRead app to listen." }));
  return true;
});
api.commands?.onCommand.addListener(async command => {
  if (command !== 'toggle-playback') return;
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (!tab || !/^https?:/u.test(tab.url || '')) return;
  try {
    let state; try { state = await api.tabs.sendMessage(tab.id, { type: 'openread:get-state' }); } catch { /* first use */ }
    if (!state?.preferences) await api.scripting.executeScript({ target: { tabId: tab.id }, files: ['core.js', 'extract.js', 'player.js', 'highlighter.js', 'content.js'] });
    await api.tabs.sendMessage(tab.id, { type: 'toggle-playback' });
  } catch { /* Safari restricts injection into protected pages. */ }
});
