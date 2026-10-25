/* Local companion workspace. No cloud SDKs, analytics, or remote assets. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  let chatHistory = []; let lastAnswer = '';
  let current = { title: 'Make a little room.', text: '', source: '', bookmarks: [], position: 0 };
  let entries = []; let items = []; let busy = null; let sleepTimer; let podcast; let transcript = ''; let sample; let recorder; let recordingTarget; let recordingTimer; let podcastURL; let activeRange; let saveTimer; let restoring = false; let saveQueue = Promise.resolve();
  const preferences = (() => { try { return JSON.parse(localStorage.getItem('openread-workspace') || '{}'); } catch { return {}; } })();
  function notice(message = '') { $('#notice').textContent = message; $('#notice').hidden = !message; }
  async function api(path, payload) {
    const response = await fetch(path, { method: payload === undefined ? 'GET' : 'POST', headers: { 'X-OpenRead': '1', ...(payload === undefined ? {} : { 'Content-Type': 'application/json' }) }, ...(payload === undefined ? {} : { body: JSON.stringify(payload) }) });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'This local request failed.');
    return result;
  }
  function action(selector, callback) {
    $(selector).addEventListener('click', () => { notice(); Promise.resolve().then(callback).catch(error => notice(error.message)); });
  }
  function clearWord() { activeRange = null; $('#word-layer').replaceChildren(); }
  function paintWord() {
    $('#word-layer').replaceChildren();
    if (!activeRange) return;
    const rectangles = [...activeRange.getClientRects()];
    for (const rect of rectangles) {
      const marker = document.createElement('i');
      Object.assign(marker.style, { left: `${rect.left - 1}px`, top: `${rect.top}px`, width: `${rect.width + 2}px`, height: `${rect.height}px` });
      $('#word-layer').append(marker);
    }
  }
  const player = new OpenReadPlayer({ AudioClass: Audio,
    request: async message => ({ ok: true, ...await api('/synthesize', { text: message.text, voice: message.voice }) }),
    onError: notice, onWordClear: clearWord,
    onWord: (offset, length) => {
      clearWord();
      const paragraph = $('#reading').children[player.index]; const node = paragraph?.firstChild;
      if (!node || offset + length > node.length) return;
      const range = document.createRange(); range.setStart(node, offset); range.setEnd(node, offset + length); activeRange = range; paintWord();
      const rect = range.getBoundingClientRect();
      if (rect.top < 90 || rect.bottom > innerHeight - 80) paragraph.scrollIntoView({ block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
    }, onChange: state => {
      $('#play span').textContent = state.status === 'playing' ? 'Pause' : state.status === 'loading' ? 'Preparing…' : state.status === 'paused' ? 'Resume' : 'Listen';
      $('#play').setAttribute('aria-label', state.status === 'playing' || state.status === 'loading' ? 'Pause' : 'Listen');
      $('#previous').disabled = !state.total || !state.index; $('#next').disabled = !state.total || state.index >= state.total - 1;
      $('#playback-status').textContent = state.status === 'idle' ? 'Ready when you are' : state.status === 'ended' ? 'Finished' : `${state.status === 'playing' ? 'Listening' : state.status === 'loading' ? 'Preparing' : 'Paused'} · ${state.index + 1} of ${state.total}`;
      if (state.status !== 'playing') clearWord();
      if (state.total && !restoring) {
        current.position = state.status === 'ended' ? 0 : state.index;
        scheduleProgressSave();
      }
    }
  });
  function scheduleProgressSave() {
    if (!current.id || saveTimer) return;
    saveTimer = setTimeout(() => { saveTimer = null; void persist().catch(error => notice(error.message)); }, 3000);
  }
  function updateMeta() {
    const count = OpenReadCore.words(current.text);
    $('#document-detail').textContent = count ? `${count.toLocaleString()} words · about ${Math.max(1, Math.ceil(count / (165 * player.rate)))} min at this speed` : 'Paste something below, or bring a document along.';
  }
  function renderReading(position = 0) {
    restoring = true; sample?.destroy(); clearWord();
    items = OpenReadCore.passages(current.text, selectedVoice()?.lang || 'en');
    player.load(items);
    $('#reading').replaceChildren(...items.map(item => { const p = document.createElement('p'); p.textContent = item.text; return p; }));
    if (items.length && position > 0) player.seek(Math.min(position, items.length - 1), false);
    current.position = Math.max(0, Math.min(position, items.length - 1));
    restoring = false;
    $('#reading').hidden = !current.text; $('#editor').hidden = !!current.text; $('#text').value = current.text;
    $('#title').value = current.title; $('#source-label').textContent = current.source || 'A little room to think.';
    $('#save').textContent = current.id ? 'Save changes' : 'Save to library'; $('#delete').hidden = !current.id;
    $('#play').disabled = !items.length;
    updateMeta(); renderBookmarks();
  }
  function renderLibrary() {
    const query = $('#search').value.toLowerCase();
    const matching = entries.filter(item => item.title.toLowerCase().includes(query));
    $('#library').replaceChildren();
    for (const entry of matching) {
      const button = document.createElement('button'); button.classList.toggle('active', entry.id === current.id);
      const title = document.createElement('span'); title.textContent = entry.title; const detail = document.createElement('small');
      detail.textContent = entry.source || 'Saved on this device'; button.append(title, detail);
      button.addEventListener('click', () => { void openSaved(entry.id).catch(error => notice(error.message)); }); $('#library').append(button);
    }
    if (!matching.length) { const p = document.createElement('p'); p.textContent = entries.length ? 'No matching readings.' : 'Save a reading to keep it here.'; $('#library').append(p); }
  }
  async function refreshLibrary() { entries = (await api('/library')).documents; renderLibrary(); }
  function renderBookmarks() {
    $('#bookmarks').replaceChildren();
    for (const mark of current.bookmarks || []) {
      const button = document.createElement('button'); button.textContent = `⚑ ${mark.label}`;
      button.title = 'Jump to this bookmark'; button.addEventListener('click', () => { player.seek(mark.position); $('#reading').children[mark.position]?.scrollIntoView({ block: 'center' }); });
      const remove = document.createElement('button'); remove.textContent = '×'; remove.setAttribute('aria-label', `Remove bookmark ${mark.label}`);
      remove.addEventListener('click', () => { current.bookmarks = current.bookmarks.filter(item => item !== mark); renderBookmarks(); if (current.id) void persist().catch(error => notice(error.message)); });
      const wrapper = document.createElement('span'); wrapper.append(button, remove); $('#bookmarks').append(wrapper);
    }
  }
  function persist() {
    if (!current.text.trim()) return Promise.reject(new Error('Add some text first.'));
    const document = current; document.title = $('#title').value.trim() || 'Untitled';
    const snapshot = structuredClone(document);
    const operation = saveQueue.then(async () => {
      if (document.id) snapshot.id = document.id;
      const saved = await api('/library/save', snapshot);
      document.id = saved.id; document.updated = saved.updated;
      if (current === document) { $('#save').textContent = 'Save changes'; $('#delete').hidden = false; }
      await refreshLibrary(); return saved;
    });
    saveQueue = operation.catch(() => {}); return operation;
  }

  async function flushProgress() { clearTimeout(saveTimer); saveTimer = null; if (current.id) await persist(); }
  async function openSaved(id) {
    await flushProgress(); const document = await api(`/library/${encodeURIComponent(id)}`);
    current = document; resetResults(); renderReading(document.position); renderLibrary(); notice();
  }
  function resetResults() {
    chatHistory = []; lastAnswer = '';

    for (const selector of ['#summary', '#answer', '#podcast-script', '#notes']) $(selector).textContent = '';
    for (const selector of ['#listen-summary', '#listen-answer', '#sources', '#podcast-audio', '#podcast-player', '#podcast-sources']) $(selector).hidden = true;
    $('#podcast-player').pause(); $('#podcast-player').removeAttribute('src'); if (podcastURL) URL.revokeObjectURL(podcastURL); podcastURL = null; podcast = null;
  }
  function selectedVoice() { return OpenReadCore.voices.find(voice => voice.id === $('#voice').value); }
  for (const group of OpenReadCore.voiceGroups()) { const optgroup = document.createElement('optgroup'); optgroup.label = group.label;
    for (const voice of group.voices) { const option = document.createElement('option'); option.value = voice.id; option.textContent = `${voice.name} · ${voice.pack ? 'English' : voice.detail}`; optgroup.append(option); }
    $('#voice').append(optgroup);
  }
  $('#voice').value = preferences.voiceRevision === 2 && OpenReadCore.voices.some(v => v.id === preferences.voice) ? preferences.voice : OpenReadCore.defaultVoice;
  $('#speed').value = Math.min(5, Math.max(.5, Number(preferences.rate) || 1));
  function configure() {
    player.configure({ voice: $('#voice').value, rate: Number($('#speed').value) });
    $('#speed-value').textContent = `${Number(player.rate.toFixed(2))}×`; updateMeta();
    localStorage.setItem('openread-workspace', JSON.stringify({ voice: player.voice, rate: player.rate, voiceRevision: 2 }));
  }
  $('#voice').addEventListener('change', configure); $('#speed').addEventListener('input', configure); configure();
  action('#play', async () => { sample?.destroy(); $('#podcast-player').pause(); if (['playing', 'loading'].includes(player.status)) player.pause(); else await player.play(); });
  action('#stop', () => { player.stop(); sample?.stop(); $('#podcast-player').pause(); clearWord(); });
  $('#podcast-player').addEventListener('play', () => { player.pause(); sample?.pause(); clearWord(); });
  action('#previous', () => player.seek(player.index - 1)); action('#next', () => player.seek(player.index + 1));
  $('#sleep').addEventListener('change', () => { clearTimeout(sleepTimer); const minutes = Number($('#sleep').value); if (minutes) sleepTimer = setTimeout(() => { player.pause(); sample?.pause(); clearWord(); $('#sleep').value = '0'; notice('Your sleep timer paused playback.'); }, minutes * 60000); });
  action('#new-document', async () => { await flushProgress(); current = { title: 'Untitled reading', text: '', source: '', bookmarks: [], position: 0 }; resetResults(); renderReading(); renderLibrary(); $('#text').focus(); });
  action('#edit', () => { player.pause(); clearWord(); $('#text').value = current.text; $('#editor').hidden = false; $('#reading').hidden = true; $('#text').focus(); });
  action('#use-text', () => { const text = $('#text').value.trim(); if (!text) throw new Error('Paste some text first.'); current.text = text; current.title = $('#title').value.trim() || 'Untitled'; current.bookmarks = []; current.position = 0; resetResults(); renderReading(); if (current.id) void persist().catch(error => notice(error.message)); });
  action('#save', async () => { await persist(); notice('Saved on this device.'); });
  action('#delete', async () => { clearTimeout(saveTimer); saveTimer = null; if (!current.id) return; await saveQueue; await api('/library/delete', { id: current.id }); current = { ...current, id: undefined }; $('#delete').hidden = true; $('#save').textContent = 'Save to library'; await refreshLibrary(); notice('Deleted from your saved library. This open copy stays in memory.'); });
  action('#bookmark', async () => { if (!items.length) throw new Error('Add a reading first.'); if (current.bookmarks.length >= 200) throw new Error('This reading already has 200 bookmarks.'); const position = player.index; current.bookmarks.push({ position, label: items[position].text.slice(0, 55) }); renderBookmarks(); if (current.id) await persist(); else notice('Bookmark added. Save this reading to keep it.'); });
  $('#search').addEventListener('input', renderLibrary);
  async function runJob(path, payload) {
    if (busy) throw new Error('Let the current task finish, or cancel it first.');
    const token = {}; busy = token; $('#task').hidden = false; $('#task-message').textContent = 'Starting on your device…';
    try {
      const start = await api(path, payload); token.id = start.id;
      while (true) {
        const job = await api(`/jobs/${start.id}`); $('#task-message').textContent = job.message;
        if (job.status === 'done') { await api(`/jobs/${start.id}?consume=1`); return job.result; }
        if (job.status === 'error' || job.status === 'cancelled') { await api(`/jobs/${start.id}?consume=1`); throw new Error(job.message); }
        await sleep(700);
      }
    } finally { if (busy === token) { busy = null; $('#task').hidden = true; } }
  }
  action('#cancel-task', async () => { if (busy?.id) { await api('/jobs/cancel', { id: busy.id }); $('#task-message').textContent = 'Cancelling after the current local step…'; } });
  function requireText() { if (!current.text) throw new Error('Add a reading first.'); return current.text; }
  async function filePayload(file) {
    if (!file || file.size > 20 * 1024 * 1024) throw new Error('Choose a file smaller than 20 MB.');
    return new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve({ name: file.name || 'recording.webm', data: String(reader.result).split(',')[1] }); reader.onerror = () => reject(new Error('Could not read this file.')); reader.readAsDataURL(file); });
  }
  $('#import-file').addEventListener('change', async event => { try { const file = event.target.files[0]; if (!file) return; await flushProgress(); const imported = await runJob('/import', await filePayload(file)); current = { ...imported, position: 0, bookmarks: [] }; resetResults(); renderReading(); renderLibrary(); notice('Imported. Choose Save to keep this reading in your library.'); } catch (error) { notice(error.message); } finally { event.target.value = ''; } });
  function download(blob, filename) { const url = URL.createObjectURL(blob); const link = document.createElement('a'); link.href = url; link.download = filename; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); }
  function audioBlob(result) { const data = atob(result.audio); const bytes = new Uint8Array(data.length); for (let i = 0; i < data.length; i++) bytes[i] = data.charCodeAt(i); return new Blob([bytes], { type: 'audio/wav' }); }
  function safeName(title) { return title.replace(/[^\p{L}\p{N}\s_-]/gu, '').slice(0, 80).trim() || 'openread'; }
  action('#download-text', () => download(new Blob([requireText()], { type: 'text/plain;charset=utf-8' }), `${safeName(current.title)}.txt`));
  action('#download-audio', async () => { const name = current.title; const result = await runJob('/export', { text: requireText(), voice: player.voice }); download(audioBlob(result), `${safeName(name)}.wav`); notice('Audio exported at natural speed. Your reading speed setting affects playback only.'); });
  action('#backup', async () => { const documents = []; for (const entry of entries) documents.push(await api(`/library/${entry.id}`)); download(new Blob([JSON.stringify({ format: 'openread-library-v1', documents }, null, 2)], { type: 'application/json' }), 'openread-library.json'); });
  $('#restore-file').addEventListener('change', async event => { try { const file = event.target.files[0]; if (!file) return; if (file.size > 25 * 1024 * 1024) throw new Error('Choose a backup smaller than 25 MB.'); const backup = JSON.parse(await file.text()); if (backup.format !== 'openread-library-v1' || !Array.isArray(backup.documents) || backup.documents.length > 200) throw new Error('This is not a valid OpenRead backup.'); for (const document of backup.documents) await api('/library/save', document); await refreshLibrary(); notice('Library restored. Matching document IDs were updated.'); } catch (error) { notice(error.message); } finally { event.target.value = ''; } });
  const tabs = [...document.querySelectorAll('[role=tab]')];
  function selectTab(tab) { for (const item of tabs) { const selected = item === tab; item.setAttribute('aria-selected', String(selected)); item.tabIndex = selected ? 0 : -1; $(`#${item.getAttribute('aria-controls')}`).hidden = !selected; } }
  tabs.forEach((tab, index) => { tab.addEventListener('click', () => selectTab(tab)); tab.addEventListener('keydown', event => { if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return; event.preventDefault(); const next = event.key === 'Home' ? tabs[0] : event.key === 'End' ? tabs.at(-1) : tabs[(index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length]; selectTab(next); next.focus(); }); });
  action('#summarize', async () => { const document = current; const result = await runJob('/ai', { text: requireText(), mode: 'summary' }); if (document !== current) return; $('#summary').textContent = result.text; $('#listen-summary').hidden = false; });
  async function ask() {
    const document = current; const result = await runJob('/ai', { text: requireText(), mode: 'chat', question: $('#question').value, history: chatHistory.slice(-6) }); if (document !== current) return;
    chatHistory.push({ role: 'user', content: $('#question').value }, { role: 'assistant', content: result.text }); lastAnswer = result.text;
    $('#answer').textContent = chatHistory.map(message => (message.role === 'user' ? 'You: ' : 'OpenRead: ') + message.content).join('\n\n'); $('#listen-answer').hidden = false; $('#sources').hidden = false;
    $('#sources div').replaceChildren(...result.sources.map(source => { const p = document.createElement('p'); p.textContent = `[Passage ${source.passage}] ${source.text}`; return p; }));
  }
  $('#chat-form').addEventListener('submit', event => { event.preventDefault(); notice(); void ask().catch(error => notice(error.message)); });
  async function listenResult(selector) { const text = selector === '#answer' ? lastAnswer : $(selector).textContent; if (!text) return; player.pause(); $('#podcast-player').pause(); sample?.destroy(); sample = new OpenReadPlayer({ AudioClass: Audio, request: async message => ({ ok: true, ...await api('/synthesize', { text: message.text, voice: message.voice }) }), onError: notice }); sample.load(OpenReadCore.passages(text)); sample.configure({ voice: player.voice, rate: player.rate, voiceRevision: 2 }); await sample.play(); }
  action('#listen-summary', () => listenResult('#summary')); action('#listen-answer', () => listenResult('#answer'));
  action('#podcast', async () => { const document = current; const result = await runJob('/ai', { text: requireText(), mode: 'podcast' }); if (document !== current) return; podcast = result; $('#podcast-script').textContent = result.text; $('#podcast-audio').hidden = false; $('#podcast-sources').hidden = false; $('#podcast-sources div').replaceChildren(...result.sourceFacts.map(fact => { const p = document.createElement('p'); p.textContent = `[${fact.id}] ${fact.claim}\nSource: “${fact.quote}”`; return p; })); });
  action('#podcast-audio', async () => { if (!podcast) return; const script = podcast; const result = await runJob('/export', { turns: script.turns }); if (script !== podcast) return; const blob = audioBlob(result); if (podcastURL) URL.revokeObjectURL(podcastURL); podcastURL = URL.createObjectURL(blob); $('#podcast-player').src = podcastURL; $('#podcast-player').hidden = false; download(blob, `${safeName(script.title)}.wav`); });
  async function transcribeFile(file, target = 'transcript') {
    const result = await runJob('/transcribe', await filePayload(file));
    if (target === 'question') { $('#question').value = result.text.slice(0, 2000); selectTab($('#tab-chat')); await ask(); return; }
    transcript = result.text; $('#transcript').textContent = transcript; $('#use-transcript').hidden = false; $('#copy-transcript').hidden = false; $('#meeting-notes').hidden = false;
  }
  $('#audio-file').addEventListener('change', async event => { try { if (event.target.files[0]) await transcribeFile(event.target.files[0]); } catch (error) { notice(error.message); } finally { event.target.value = ''; } });
  async function toggleRecording(target) {
    if (recorder?.state === 'recording') { recorder.stop(); return; }
    if (busy) throw new Error('Wait for the current task before recording.');
    if (!navigator.mediaDevices?.getUserMedia || !globalThis.MediaRecorder) throw new Error('Microphone recording is unavailable in this browser. Import an audio file instead.');
    player.pause(); sample?.pause();
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    try {
      const mime = ['audio/webm;codecs=opus', 'audio/mp4'].find(type => MediaRecorder.isTypeSupported(type));
      recorder = new MediaRecorder(stream, mime ? { mimeType: mime } : {}); recordingTarget = target;
      const chunks = []; let size = 0;
      recorder.ondataavailable = event => { if (event.data.size) { chunks.push(event.data); size += event.data.size; if (size > 19 * 1024 * 1024 && recorder.state === 'recording') recorder.stop(); } };
      recorder.onerror = () => { stream.getTracks().forEach(track => track.stop()); notice('Recording failed. Try importing an audio file.'); };
      recorder.onstop = () => {
        clearTimeout(recordingTimer); stream.getTracks().forEach(track => track.stop());
        $('#record').textContent = 'Start recording'; $('#ask-voice').textContent = 'Record question'; $('#record').disabled = false; $('#ask-voice').disabled = false;
        const file = new File(chunks, mime?.includes('mp4') ? 'recording.m4a' : 'recording.webm', { type: recorder.mimeType });
        void transcribeFile(file, recordingTarget).catch(error => notice(error.message));
      };
      recorder.start(1000); $('#record').textContent = target === 'transcript' ? 'Stop recording' : 'Start recording'; $('#ask-voice').textContent = target === 'question' ? 'Stop recording' : 'Record question';
      $('#record').disabled = target === 'question'; $('#ask-voice').disabled = target === 'transcript';
      recordingTimer = setTimeout(() => { if (recorder.state === 'recording') recorder.stop(); }, target === 'question' ? 90000 : 300000);
    } catch (error) { stream.getTracks().forEach(track => track.stop()); throw error; }
  }
  action('#record', () => toggleRecording('transcript')); action('#ask-voice', () => toggleRecording('question'));
  action('#copy-transcript', async () => { await navigator.clipboard.writeText(transcript); notice('Transcript copied. Paste it into any app.'); });
  action('#use-transcript', async () => { await flushProgress(); current = { title: 'Your transcript', text: transcript, source: 'Local dictation', position: 0, bookmarks: [] }; resetResults(); renderReading(); renderLibrary(); });
  action('#meeting-notes', async () => { if (!transcript) return; const result = await runJob('/ai', { text: transcript, mode: 'notes' }); $('#notes').textContent = result.text; });
  action('#setup-toggle', async () => { $('#setup').hidden = !$('#setup').hidden; if ($('#setup').hidden) return; const status = await api('/capabilities'); $('#capabilities').replaceChildren(...[['Local voices', true], ['PDF import', status.pdf], ['Scan & Listen', status.ocr], ['AI · Qwen3 4B', status.ai], ['Dictation · Whisper', status.transcription], ['Extra voices · Kitten Mini', status.extraVoices]].map(([label, ready]) => { const span = document.createElement('span'); span.textContent = `${ready ? '✓' : '○'} ${label}${ready ? '' : ' · setup needed'}`; return span; })); });
  document.addEventListener('scroll', paintWord, true); window.addEventListener('resize', paintWord);
  window.addEventListener('pagehide', () => { clearTimeout(sleepTimer); clearTimeout(recordingTimer); clearTimeout(saveTimer); player.destroy(); sample?.destroy(); if (recorder?.state === 'recording') { recorder.onstop = null; recorder.stop(); recorder.stream.getTracks().forEach(track => track.stop()); } });
  renderReading();
  void api('/health').then(status => { for (const option of $('#voice').options) { const info = status.voices.find(v => v.id === option.value); if (info?.available === false) { option.disabled = true; option.textContent += ' (setup needed)'; if (option.selected) notice('Run Set Up OpenRead.command and restart the helper to enable the featured Kitten voices.'); } } }).catch(() => {});
  void refreshLibrary().then(async () => { const id = new URL(location.href).searchParams.get('id'); if (id) await openSaved(id); }).catch(error => notice(error.message));
})();
