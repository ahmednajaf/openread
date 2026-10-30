/* Shared settings view: Safari's toolbar popup and the development preview. */
(() => {
  class Settings {
    constructor({ container, assetURL, command, dismiss = () => {}, popup = false }) {
      this.command = command; this.dismiss = dismiss; this.state = {}; this.hideWhenPlaying = false; this.popup = popup;
  const symbols = {
    close: '<path d="m7 7 10 10M7 17 17 7"/>',
    play: '<path d="m9 5 11 7-11 7Z"/>', pause: '<path d="M9 5v14M16 5v14"/>',
    previous: '<path d="M6 5v14m13-14L8 12l11 7Z"/>', next: '<path d="M18 5v14M5 5l11 7-11 7Z"/>',
    voice: '<path d="M4 10v4m4-8v12m4-15v18m4-15v12m4-8v4"/>',
    chevron: '<path d="m9 5 7 7-7 7"/>', stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    reader: '<path d="M5 4h14M5 8h14M5 12h14M5 16h10M5 20h8"/>',
    check: '<path d="m5 12 4 4L19 6"/>'
  };
  const icon = (name) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${symbols[name]}</svg>`;
  const ui = document.createElement('div'); ui.className = 'shell';
  ui.innerHTML = `
    <div class="highlight-layer" aria-hidden="true"></div>
    <section class="popover glass" role="region" aria-label="OpenRead settings" tabindex="-1" lang="en">
      <header><div class="brand"><img class="logo" alt="" width="30" height="30"><span>openread<span class="brand-dot">.</span></span></div><button class="icon-button dismiss" aria-label="Hide settings" title="Hide settings (Escape)">${icon('close')}</button></header>
      <div class="document"><div class="document-meta"><span class="source-name"></span><span class="document-duration"></span></div><h1 class="document-title"></h1></div>
      <div class="transport"><button class="icon-button previous" aria-label="Previous passage">${icon('previous')}</button><button class="listen" aria-label="Listen to page">${icon('play')}<span>Listen to page</span></button><button class="icon-button next" aria-label="Next passage">${icon('next')}</button></div>
      <div class="voice-row"><span class="setting-icon">${icon('voice')}</span><label for="voice">Voice</label><select id="voice" aria-label="Natural voice"></select><button class="preview icon-button" aria-label="Preview voice" title="Preview selected voice">${icon('play')}</button></div>
      <div class="speed-setting"><div class="setting-heading"><label for="speed">Speed</label><output for="speed" class="speed-value">1×</output></div><input id="speed" aria-label="Reading speed" type="range" min="0.5" max="5" value="1" step="0.05"><div class="speed-labels"><span>0.5×</span><span>5×</span></div></div>
      <button class="options-button" aria-expanded="false" aria-controls="options"><span>Reading options</span>${icon('chevron')}</button>
      <div id="options" class="options" hidden>
        <label class="option"><span>Highlight words</span><input id="highlight" type="checkbox" role="switch" checked></label>
        <label class="option"><span>Follow along as I scroll</span><input id="follow" type="checkbox" role="switch" checked></label>
        <div class="option"><label for="sleep">Sleep timer</label><select id="sleep"><option value="0">Off</option><option value="5">5 minutes</option><option value="15">15 minutes</option><option value="30">30 minutes</option><option value="60">1 hour</option></select></div>
        <button class="workspace secondary">OpenRead library<span aria-hidden="true">↗</span></button>
        <button class="save-document secondary">Open page in OpenRead<span aria-hidden="true">＋</span></button>
        <p class="reader-help">Download voices in OpenRead first. Kitten TTS 2 opens the app for playback; return to Safari to follow the highlighted words.</p><div class="option"><label for="source">Read from</label><select id="source"><option value="page">This page</option><option value="selection">Selected text</option><option value="chat" hidden>WhatsApp chat</option></select></div>
        <label class="option chat-option" hidden><span>Announce senders</span><input id="announceSenders" type="checkbox" role="switch" checked></label>
        <button class="refresh-chat secondary" hidden>Refresh loaded messages<span aria-hidden="true">↻</span></button>
        <p class="reader-help chat-help" hidden></p>
        <button class="reader-option secondary" aria-label="Safari Reader">${icon('reader')}<span>Safari Reader</span><kbd>⇧⌘R</kbd></button>
        <p class="reader-help safari-reader-help" hidden>Use Safari’s Show Reader shortcut, ⇧⌘R. OpenRead cannot switch Safari’s native Reader itself. Word highlighting stays on the original webpage.</p>
        <button class="paste-toggle secondary">Paste text<span aria-hidden="true">＋</span></button>
        <div class="paste-box" hidden><label class="sr-only" for="paste">Text to read</label><textarea id="paste" maxlength="100000" placeholder="Paste something to listen to…"></textarea><button class="load-paste">Use this text</button></div>
        <p class="licence-notice">© 2026 Ahmed Najaf and contributors. <a href="https://github.com/ahmednajaf/openread/blob/master/LICENSING.md" target="_blank" rel="noreferrer">Free software · GPL-3.0-or-later · source</a>. You may modify and share it under those terms. No warranty.</p>
      </div>
      <div class="notice" role="status" aria-live="polite" hidden></div>
      <div class="session-row"><span class="session-label">Ready to listen</span><button class="stop text-button" hidden>${icon('stop')} Stop</button></div>
      <footer><span class="local-dot"></span><span>Natural voices · On-device</span><kbd title="Play or pause from the page">⌥⇧P</kbd></footer>
    </section>`;
      container.append(ui); this.ui = ui; this.$ = selector => ui.querySelector(selector);
      // Safari already provides the real native glass for its toolbar popover.
      // Keep that surface visible instead of stacking a simulated card over it.
      if (popup) {
        const surface = this.$('.popover'); const content = document.createElement('div'); content.className = 'glass-content';
        content.append(...surface.childNodes); surface.append(content);
      }
      this.material = popup ? { element: this.$('.popover'), destroy() {} } : OpenReadGlass.enhance(this.$('.popover'));
      this.primaryMaterial = OpenReadGlass.enhance(this.$('.listen'), true);
      this.popover = this.material.element;
      if (popup) ui.classList.add('toolbar-popup');
      this.$('.logo').src = assetURL('icons/128.png');
      for (const group of OpenReadCore.voiceGroups()) {
        const optgroup = document.createElement('optgroup'); optgroup.label = group.label;
        for (const voice of group.voices) { const option = document.createElement('option'); option.value = voice.id;
          option.textContent = `${voice.name} · ${voice.pack === 'kitten' ? 'Kitten' : voice.detail.split(' · ')[0]}`; optgroup.append(option); }
        this.$('#voice').append(optgroup);
      }
      const send = (action, value) => {
        Promise.resolve(command(action, value)).then(state => { if (state) this.update(state); })
          .catch(() => { this.$('.notice').textContent = 'OpenRead lost contact with this tab. Reopen the extension to reconnect.'; this.$('.notice').hidden = false; });
      };
      this.$('.dismiss').addEventListener('click', () => this.hide());
      this.$('.listen').addEventListener('click', () => {
        this.gestureAction = true; this.hideWhenPlaying = !['playing', 'loading'].includes(this.state.status); send('toggle-playback');
      });
      for (const action of ['previous', 'next', 'stop', 'preview']) this.$(`.${action}`).addEventListener('click', () => { this.gestureAction = true; send(action); });
      this.$('#speed').addEventListener('input', event => {
        const rate = Number(event.target.value); this.speed(rate); send('set-rate', rate);
      });
      this.$('#voice').addEventListener('change', event => send('set-voice', event.target.value));
      for (const key of ['highlight', 'follow', 'announceSenders']) this.$(`#${key}`).addEventListener('change', event => send('set-preference', { key, value: event.target.checked }));
      this.$('.refresh-chat').addEventListener('click', () => send('refresh-chat'));
      this.$('.workspace').addEventListener('click', () => send('open-workspace'));
      this.$('.save-document').addEventListener('click', () => send('save-document'));
      this.$('#sleep').addEventListener('change', event => send('set-sleep', Number(event.target.value)));
      this.$('#source').addEventListener('change', event => send('set-source', event.target.value));
      this.$('.options-button').addEventListener('click', () => {
        const options = this.$('#options'); options.hidden = !options.hidden;
        this.$('.options-button').setAttribute('aria-expanded', String(!options.hidden));
      });
      const isSafari = /Safari/u.test(navigator.userAgent) && !/Chrome|Chromium/u.test(navigator.userAgent);
      this.$('.reader-option').hidden = !isSafari; this.$('.safari-reader-help').hidden = true;
      this.$('.reader-option').addEventListener('click', () => { this.$('.safari-reader-help').hidden = !this.$('.safari-reader-help').hidden; });
      this.$('.paste-toggle').addEventListener('click', () => { this.$('.paste-box').hidden = !this.$('.paste-box').hidden; if (!this.$('.paste-box').hidden) this.$('#paste').focus(); });
      this.$('.load-paste').addEventListener('click', () => { send('paste', this.$('#paste').value); this.$('.paste-box').hidden = true; });
      this.onKey = event => { if (event.key === 'Escape' && !this.popover.hidden) { event.preventDefault(); this.hide(); } };
      ui.addEventListener('keydown', this.onKey);
      this.systemAppearance = matchMedia('(prefers-color-scheme: dark)');
      this.appearanceChanged = () => this.appearance();
      this.systemAppearance.addEventListener('change', this.appearanceChanged);
      this.icon = icon;
    }
    speed(rate) {
      this.$('#speed').value = rate;
      this.$('#speed').style.setProperty('--speed-progress', `${Number(((rate - .5) / (Number(this.$('#speed').max) - .5) * 100).toFixed(3))}%`);
      this.$('.speed-value').textContent = `${Number(rate.toFixed(2))}×`;
    }
    appearance() {
      this.ui.dataset.appearance = this.systemAppearance.matches ? 'dark' : 'light';
      this.ui.dataset.foreground = this.ui.dataset.appearance;
    }
    update(state) {
      const oldError = this.state.error; this.state = state;
      const { status, index, total, preferences } = state;
      const active = ['playing', 'loading'].includes(status);
      const label = status === 'loading' ? 'Preparing…' : status === 'playing' ? 'Pause' : status === 'paused' ? 'Resume listening' : status === 'ended' ? 'Listen again' : state.source === 'chat' ? 'Listen to chat' : 'Listen to page';
      this.$('.glass-button-content').innerHTML = `${this.icon(active ? 'pause' : 'play')}<span>${label}</span>`;
      this.$('.listen').setAttribute('aria-label', active ? 'Pause' : label);
      this.$('.listen').classList.toggle('loading', status === 'loading'); this.$('.listen').disabled = !total;
      this.$('.previous').disabled = !total || index === 0; this.$('.next').disabled = !total || index >= total - 1;
      this.$('.stop').hidden = status === 'idle' || status === 'ended';
      this.$('.session-label').textContent = status === 'playing' ? `Listening · ${index + 1} of ${total}` : status === 'loading' ? 'Preparing on this device…' : status === 'paused' ? 'Paused' : status === 'ended' ? 'Finished' : 'Ready to listen';
      this.$('.document-title').textContent = state.title;
      this.$('.source-name').textContent = state.sourceName;
      this.$('.document-duration').textContent = `${state.minutes} min`;
      this.$('#sleep').value = String(state.sleepMinutes || 0);
      this.$('#source option[value=chat]').hidden = !state.chatAvailable;
      this.$('#source option[value=chat]').disabled = !state.chatAvailable;
      this.$('#source').value = ['selection', 'chat'].includes(state.source) ? state.source : 'page';
      const chat = state.source === 'chat';
      for (const selector of ['.chat-option', '.refresh-chat', '.chat-help']) this.$(selector).hidden = !chat;
      this.$('.chat-help').textContent = `${state.messageCount || 0} loaded text messages · oldest first. Scroll up in the chat and refresh to include older messages. New messages need a refresh too. Photos, stickers and voice notes are skipped.`;
      this.$('#source option[value=selection]').disabled = !state.hasSelection;
      for (const option of this.$('#voice').options) { const voice = OpenReadCore.voices.find(v => v.id === option.value); option.disabled = !!voice?.pack && !(state.availableVoices || []).includes(option.value); option.textContent = `${voice.name} · ${voice.pack === 'kitten' ? 'Kitten' : voice.detail.split(' · ')[0]}${option.disabled ? ' (setup needed)' : ''}`; }
      this.$('#voice').value = preferences.voice; this.$('#speed').max = preferences.voice.startsWith('kitten2:') ? 2 : 5; this.$('.speed-labels span:last-child').textContent = this.$('#speed').max + '×'; this.speed(preferences.rate);
      for (const key of ['highlight', 'follow']) this.$(`#${key}`).checked = preferences[key];
      this.$('#announceSenders').checked = preferences.announceSenders !== false;
      this.appearance();
      const previewing = ['playing', 'loading'].includes(state.previewStatus);
      this.$('.preview').innerHTML = this.icon(previewing ? 'stop' : 'play');
      this.$('.preview').setAttribute('aria-label', previewing ? 'Stop preview' : 'Preview voice');
      this.$('.notice').textContent = state.error || state.notice || ''; this.$('.notice').hidden = !(state.error || state.notice);
      if (state.error && state.error !== oldError) this.show();
      if (state.needsPageGesture && this.popup && this.gestureAction) { this.gestureAction = false; this.hideWhenPlaying = false; this.hide(); }
      if (status === 'playing' && this.hideWhenPlaying) { this.hideWhenPlaying = false; this.hide(); }
    }
    show() { this.popover.hidden = false; }
    hide() { this.popover.hidden = true; this.dismiss(); }
    destroy() {
      this.systemAppearance.removeEventListener('change', this.appearanceChanged);
      this.ui.removeEventListener('keydown', this.onKey); this.primaryMaterial.destroy(); this.material.destroy(); this.ui.remove();
    }
  }
  globalThis.OpenReadSettings = Settings;
})();
