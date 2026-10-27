/* Page playback stays alive independently of the short-lived toolbar popup. */
(() => {
  if (globalThis.__openread?.version === 6) { globalThis.__openread.toggle(); return; }
  globalThis.__openread?.close();
  const api = globalThis.browser || globalThis.chrome;
  const { voices, words, passages } = OpenReadCore;
  const preview = !api.runtime.id;
  const previousFocus = document.activeElement;
  const chatAvailable = OpenReadChat.available(document);
  const chatChanged = 'The conversation changed. Press Listen to chat again, or refresh loaded messages in Reading options.';
  let selection = null; let source = chatAvailable ? 'chat' : 'page'; let sample; let view; let unlockButton; let destroyed = false; let interacted = false; let error = '';
  let preferences = { voice: OpenReadCore.defaultVoice, voiceRevision: 2, rate: 1, highlight: true, follow: true, announceSenders: true };
  let availableVoices = voices.filter(v => !v.pack).map(v => v.id); let voiceAvailabilityKnown = false;
  let sleepTimer; let sleepMinutes = 0;
  let phase = { status: 'idle', index: 0, total: 0 };
  let article = { title: document.title, text: '', items: [], source: 'page' };
  const host = document.createElement('div'); host.dataset.openreadHost = '';
  host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;pointer-events:none!important;display:block!important;';
  const shadow = host.attachShadow({ mode: 'closed' });
  const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = api.runtime.getURL('reader.css'); shadow.append(link);
  const layer = document.createElement('div'); layer.className = 'highlight-layer'; layer.setAttribute('aria-hidden', 'true'); shadow.append(layer);
  document.documentElement.append(host);
  const request = message => api.runtime.sendMessage(message);
  function snapshot() {
    return { ...phase, preferences: { ...preferences }, source, sleepMinutes, availableVoices, hasSelection: !!selection, chatAvailable, messageCount: article.messageCount || 0, error,
      title: article.title, sourceName: source === 'chat' ? 'WhatsApp Web' : source === 'paste' ? 'Pasted text' : source === 'selection' ? 'Selected text' : location.hostname.replace(/^www\./u, ''),
      minutes: Math.max(1, Math.ceil(words(article.text) / (165 * preferences.rate))), previewStatus: sample?.status || 'idle', needsPageGesture: !!(player.needsPageGesture || sample?.needsPageGesture) };
  }
  function publish() {
    if (destroyed) return;
    const needsGesture = player.needsPageGesture || sample?.needsPageGesture;
    if (!preview && needsGesture && !unlockButton) {
      unlockButton = document.createElement('button'); unlockButton.className = 'audio-permission';
      unlockButton.textContent = player.needsPageGesture ? 'Start listening' : 'Preview voice'; unlockButton.title = 'Safari requires one click on this webpage to enable audio.';
      unlockButton.addEventListener('click', () => { void command(player.needsPageGesture ? 'toggle-playback' : 'preview'); }); shadow.append(unlockButton);
    } else if (!needsGesture && unlockButton) { unlockButton.remove(); unlockButton = null; }
    const state = snapshot(); view?.update(state);
    void request({ type: 'openread:state', state }).catch(() => {});
    void request({ type: 'playbackState', status: phase.status, error }).catch(() => {});
  }
  function notice(text = '') { error = text; publish(); }
  function validateChat(item) {
    if (article.source !== 'chat') return;
    const current = OpenReadChat.identity(document);
    if (!article.chatRoot?.isConnected || current.root !== article.chatRoot || current.title !== article.title
      || !item?.element?.isConnected || item.element.getAttribute('data-pre-plain-text') !== item.chatHeader
      || item.runs?.some(run => !run.node.isConnected || run.node.data !== run.snapshot)) {
      throw new Error(chatChanged);
    }
  }
  let highlighter;
  const player = new OpenReadPlayer({ request, AudioClass: Audio,
    validate: validateChat,
    onChange: state => { phase = state; if (state.status === 'idle' || state.status === 'ended') highlighter?.clear(); publish(); },
    onWordClear: () => highlighter?.clear(),
    onWord: (offset, length) => { if (preferences.highlight && article.source !== 'paste') highlighter.show(player.items[player.index], offset, length); },
    onError: message => { if (message === chatChanged) player.stop(); notice(message); } });
  highlighter = new OpenReadHighlighter({ layer, follow: preferences.follow,
    onStale: () => { player.pause(); highlighter.clear(); notice('The page changed. Stop and start listening to refresh its text.'); } });
  function captureSelection() {
    const current = window.getSelection();
    if (current && !current.isCollapsed && current.rangeCount && !host.contains(current.anchorNode)) {
      selection = current.getRangeAt(0).cloneRange();
      if (!['playing', 'loading', 'paused'].includes(player.status)) source = 'selection';
    }
  }
  function load() {
    highlighter.clear(); sample?.stop(); error = '';
    if (source !== 'paste') article = OpenReadExtract(document, { selection: source === 'selection' ? selection : null, mode: source, announceSenders: preferences.announceSenders });
    player.load(article.items, article.lang);
    if (!article.items.length) notice(source === 'chat' ? 'No loaded text messages found. Open a WhatsApp conversation, then use Refresh loaded messages in Reading options. You can also select message text to read it.' : 'No article text found. Select text on the page or use Paste text in Reading options.');
    publish();
  }
  function save() { void api.storage.local.set({ preferences }).catch(() => notice('Your preferences could not be saved.')); }
  function apply() { highlighter.follow = preferences.follow; player.configure({ voice: preferences.voice, rate: preferences.rate }); publish(); }
  async function command(action, value) {
    interacted = true;
    switch (action) {
      case 'toggle-playback':
        sample?.stop(); error = '';
        if (['playing', 'loading'].includes(player.status)) player.pause();
        else { if (voiceAvailabilityKnown && !availableVoices.includes(preferences.voice)) { notice('Open the OpenRead app and download natural voices first.'); break; } if (player.status === 'idle' || player.status === 'ended') load(); await player.play(); }
        break;
      case 'open-workspace': { const result = await request({ type: 'openWorkspace' }); if (!result?.ok) notice('Open the OpenRead app to view your library.'); break; }
      case 'save-document': {
        if (!article.text.trim()) { notice('Add a reading first.'); break; }
        const result = await request({ type: 'saveDocument', title: article.title, text: article.text });
        if (!result?.ok) notice(result?.error || 'OpenRead could not save this page. Open the app and try again.'); break;
      }
      case 'set-sleep': {
        const minutes = Number(value); if (![0, 5, 15, 30, 60].includes(minutes)) break;
        clearTimeout(sleepTimer); sleepMinutes = minutes;
        if (minutes) sleepTimer = setTimeout(() => { sleepMinutes = 0; player.pause(); sample?.pause(); highlighter.clear(); publish(); }, minutes * 60000); break;
      }
      case 'previous': case 'next': sample?.stop(); highlighter.clear(); player.seek(player.index + (action === 'next' ? 1 : -1)); break;
      case 'stop': sample?.stop(); player.stop(); highlighter.clear(); break;
      case 'set-rate': preferences.rate = Math.max(.5, Math.min(5, Number(value) || 1)); sample?.configure({ rate: preferences.rate }); player.configure({ rate: preferences.rate }); save(); break;
      case 'set-voice':
        if (!voices.some(v => v.id === value)) break;
        sample?.stop(); error = ''; preferences.voice = value; player.configure({ voice: value }); save(); break;
      case 'set-preference':
        if (!value || !['highlight', 'follow', 'announceSenders'].includes(value.key)) break;
        if (typeof value.value !== 'boolean') break;
        preferences[value.key] = value.value; highlighter.follow = preferences.follow;
        if (!preferences.highlight) highlighter.clear();
        if (value.key === 'announceSenders' && source === 'chat') load(); save(); break;
      case 'set-source': if (value === 'page' || value === 'selection' && selection || value === 'chat' && chatAvailable) { source = value; load(); } break;
      case 'refresh-chat': if (chatAvailable) { source = 'chat'; load(); } break;
      case 'paste': {
        const text = typeof value === 'string' ? value.trim().slice(0, 100000) : '';
        if (!text) { notice('Paste some text first.'); break; }
        source = 'paste'; article = { title: 'Your text', text, lang: 'en', source: 'paste', items: passages(text) }; load(); break;
      }
      case 'preview':
        if (voiceAvailabilityKnown && !availableVoices.includes(preferences.voice)) { notice('Open the OpenRead app and download natural voices first.'); break; }
        if (sample && ['playing', 'loading'].includes(sample.status)) { sample.stop(); break; }
        player.pause(); error = '';
        sample = new OpenReadPlayer({ request, AudioClass: Audio, onError: notice, onChange: publish });
        sample.load([{ text: OpenReadCore.samples[voices.find(v => v.id === preferences.voice)?.lang] || OpenReadCore.samples['en-us'] }]);
        sample.configure({ voice: preferences.voice, rate: preferences.rate }); await sample.play(); break;
      default: break;
    }
    publish(); return snapshot();
  }
  function toggleSettings() {
    if (!view) return;
    if (!view.popover.hidden) view.hide();
    else { const oldSource = source; captureSelection(); if (oldSource !== source) load(); view.update(snapshot()); view.show(); }
  }
  if (preview) view = new OpenReadSettings({ container: shadow, assetURL: file => api.runtime.getURL(file), command,
    dismiss: () => { if (shadow.activeElement) previousFocus?.focus?.({ preventScroll: true }); } });
  function keydown(event) {
    if (preview && event.key === 'Escape') view?.hide();
    if (preview && event.altKey && event.shiftKey && event.code === 'KeyP') { event.preventDefault(); void command('toggle-playback'); }
  }
  function outside(event) { if (view && !view.popover.hidden && !event.composedPath().includes(host)) view.hide(); }
  function message(message, _sender, respond) {
    if (message?.type === 'openread:get-state') { const oldSource = source; captureSelection(); if (oldSource !== source) load(); respond(snapshot()); return; }
    if (message?.type === 'openread:command' || message?.type === 'toggle-playback') {
      void command(message.type === 'toggle-playback' ? 'toggle-playback' : message.action, message.value)
        .then(respond, () => { notice('This page could not be read. Try selecting its text.'); respond(snapshot()); });
      return true;
    }
  }
  // WhatsApp changes conversations without a full navigation. Stop queued audio
  // when its source disappears/changes; never auto-read a newly opened chat.
  const chatObserver = chatAvailable ? new MutationObserver(() => {
    if (article.source !== 'chat' || !['playing', 'loading', 'paused'].includes(player.status)) return;
    try { validateChat(player.items[player.index]); }
    catch (error) { player.stop(); highlighter.clear(); notice(error.message); }
  }) : null;
  chatObserver?.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['title'] });
  function close() {
    if (destroyed) return; destroyed = true; chatObserver?.disconnect(); clearTimeout(sleepTimer); player.destroy(); sample?.destroy(); highlighter.destroy(); view?.destroy();
    document.removeEventListener('keydown', keydown); document.removeEventListener('pointerdown', outside, true);
    api.runtime.onMessage?.removeListener(message); window.removeEventListener('pagehide', close); host.remove();
    void request({ type: 'playbackState', status: 'idle' }).catch(() => {}); globalThis.__openread = null;
  }
  document.addEventListener('keydown', keydown); document.addEventListener('pointerdown', outside, true);
  api.runtime.onMessage?.addListener(message); window.addEventListener('pagehide', close);
  globalThis.__openread = { version: 6, toggle: toggleSettings, close };
  captureSelection(); load(); apply();
  void api.storage.local.get('preferences').then(result => {
    if (interacted || destroyed || !result.preferences) return;
    const old = result.preferences;
    preferences = { ...preferences, ...old, voice: old.voiceRevision === 2 && voices.some(v => v.id === old.voice) ? old.voice : OpenReadCore.defaultVoice, voiceRevision: 2, rate: Math.max(.5, Math.min(5, Number(old.rate) || 1)) };
    delete preferences.skipLinks; delete preferences.appearance; save(); apply(); load();
  }).catch(() => {});
  void request({ type: 'health' }).then(result => {
    if (!result?.ok || destroyed) return;
    voiceAvailabilityKnown = true;
    availableVoices = result.voices?.filter(v => v.available !== false).map(v => v.id) || availableVoices;
    if (!availableVoices.includes(preferences.voice)) notice('Open the OpenRead app and download natural voices first.');
    publish();
  }).catch(() => {});
})();
