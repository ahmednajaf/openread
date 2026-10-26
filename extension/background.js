/* global browser, chrome */
const api = globalThis.browser || globalThis.chrome;
const LOCAL = "http://127.0.0.1:8765";
const VOICE_ERRORS = {
  voice_setup_required: 'Run setup/Set Up More Voices.command, then restart OpenRead.',
  voice_passage_complex: 'This passage is too complex for this voice. Try a Kokoro voice.',
  voice_alignment_failed: 'This voice could not align this passage. Try another voice.',
  voice_empty_audio: 'This voice did not produce usable audio. Try another voice.'
};
function serviceError(status, code) {
  if (status === 422 && Object.hasOwn(VOICE_ERRORS, code)) return VOICE_ERRORS[code];
  if (status === 429) return 'The local voice helper is busy. Wait a moment, then try again.';
  if (status === 403) return 'Your browser could not access the local voice helper. Reload OpenRead and check its website access permissions.';
  if (status === 400) return 'This voice request could not be read. Refresh the page and try again.';
  return 'The local voice helper could not generate this passage. Try another voice or restart OpenRead.';
}

// All local-service requests originate here, not in the website's context.
// No caller-selected URLs, arbitrary endpoints, or remote speech providers.
api.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.tab && message?.type === 'playbackState') {
    const label = message.error ? '!' : { playing: '▶', paused: 'Ⅱ', loading: '…' }[message.status] || '';
    void api.action.setBadgeText({ tabId: sender.tab.id, text: label });
    void api.action.setTitle({ tabId: sender.tab.id, title: message.error || 'OpenRead · Voice & playback settings' });
    respond({ ok: true }); return;
  }
  if (message?.type === 'openWorkspace' && (sender.tab || sender.url?.startsWith(api.runtime.getURL('')))) {
    void api.tabs.create({ url: LOCAL + '/' }).then(() => respond({ ok: true })); return true;
  }
  if (sender.tab && message?.type === 'saveDocument') {
    (async () => {
      if (typeof message.text !== 'string' || !message.text.trim() || message.text.length > 250000) throw new Error('Choose up to 250,000 characters to save.');
      const response = await fetch(LOCAL + '/library/save', { method: 'POST', headers: { 'X-OpenRead': '1', 'Content-Type': 'application/json' },
        body: JSON.stringify({ title: String(message.title || 'Saved reading').slice(0, 240), text: message.text, source: String(sender.tab.url || '').slice(0, 1000) }), signal: AbortSignal.timeout(10000) });
      const result = await response.json(); if (!response.ok) throw new Error(result.error || 'Could not save this reading.');
      await api.tabs.create({ url: LOCAL + '/?id=' + encodeURIComponent(result.id) }); return { ok: true };
    })().then(respond, error => respond({ ok: false, error: error.message || 'Start the local helper to save this reading.' })); return true;
  }
  if (!sender.tab || !["health", "synthesize"].includes(message?.type)) return;
  (async () => {
    const speech = message.type === "synthesize";
    if (speech && (typeof message.text !== "string" || message.text.length > 1600)) {
      return { ok: false, error: 'Choose a passage of up to 1,600 characters.' };
    }
    const response = await fetch(`${LOCAL}/${speech ? "synthesize" : "health"}`, {
      method: speech ? "POST" : "GET",
      headers: { "X-OpenRead": "1", ...(speech ? { "Content-Type": "application/json" } : {}) },
      ...(speech ? { body: JSON.stringify({ text: message.text, voice: message.voice || 'af_heart' }) } : {}),
      signal: AbortSignal.timeout(speech ? 90000 : 2500)
    });
    if (!response.ok) {
      const data = await response.json().catch(() => ({}));
      return { ok: false, error: serviceError(response.status, data?.code) };
    }
    const data = await response.json().catch(() => null);
    if (!data || typeof data !== 'object') return { ok: false, error: 'The local voice helper returned an unreadable response. Restart OpenRead and try again.' };
    return { ok: true, ...data };
  })().then(respond, error => respond({
    ok: false,
    error: ['TimeoutError', 'AbortError'].includes(error?.name)
      ? 'The local voice helper took too long. Try a shorter passage or restart OpenRead.'
      : "Natural voices aren't connected. Start OpenRead's local voice helper on your Mac, then try again."
  }));
  return true;
});

api.commands?.onCommand.addListener(async (command) => {
  if (command !== 'toggle-playback') return;
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (tab) try {
    let state;
    try { state = await api.tabs.sendMessage(tab.id, { type: 'openread:get-state' }); } catch { /* first use */ }
    if (!state?.preferences) await api.scripting.executeScript({ target: { tabId: tab.id }, files: ['core.js', 'extract.js', 'player.js', 'highlighter.js', 'content.js'] });
    await api.tabs.sendMessage(tab.id, { type: 'toggle-playback' });
  } catch { /* Restricted pages cannot host playback. */ }
});
