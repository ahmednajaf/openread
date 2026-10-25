/* Exercise real DOM ranges, the player and settings against synthetic chats.
   All requests are intercepted: no WhatsApp account or network is used. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
process.env.PLAYWRIGHT_BROWSERS_PATH ||= path.join(root, '.local/browsers');
const { webkit, chromium } = require('playwright');

(async () => {
  const browser = await (process.env.BROWSER === 'chromium' ? chromium : webkit).launch({ headless: true, timeout: 15000 });
  const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
  page.setDefaultTimeout(10000);
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  const fixture = fs.readFileSync(path.join(__dirname, 'fixtures/whatsapp.html'), 'utf8');
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/fixture') return route.fulfill({ contentType: 'text/html', body: fixture });
    if (/^\/extension\/[\w.-]+$/u.test(url.pathname)) {
      const file = path.join(root, url.pathname);
      if (fs.existsSync(file)) return route.fulfill({ contentType: file.endsWith('.css') ? 'text/css' : 'application/javascript', body: fs.readFileSync(file) });
    }
    return route.abort();
  });
  const script = name => page.addScriptTag({ path: path.join(root, `extension/${name}.js`) });
  try {
    await page.goto('https://web.whatsapp.com/fixture');
    await script('core'); await script('extract');
    const extracted = await page.evaluate(() => {
      const before = document.body.innerHTML;
      const chat = OpenReadExtract(document, { mode: 'chat' });
      const plain = OpenReadExtract(document, { mode: 'chat', announceSenders: false });
      const item = chat.items[0];
      return { text: chat.text, plain: plain.text, count: chat.messageCount, title: chat.title,
        messages: chat.blocks.map(block => block.text),
        mapping: OpenReadRanges(item, item.text.indexOf('walking route'), 13).map(range => range.toString()).join(''),
        senderRanges: OpenReadRanges(item, 0, 4).length, unchanged: before === document.body.innerHTML };
    });
    assert.deepEqual(extracted.messages, [
      'Alex says: Hello everyone! See the walking route. Bring water.',
      'Sam: Hiking says: Sounds good 🙂', 'You said: I’ll bring snacks.',
      'Alex says: Same here.', 'Alex says: Same here.', 'Message: Unknown sender, still a message.'
    ]);
    assert.equal(extracted.count, 6); assert.equal(extracted.title, 'Weekend plans');
    assert.equal(extracted.mapping, 'walking route'); assert.equal(extracted.senderRanges, 0); assert.ok(extracted.unchanged);
    assert.ok(!extracted.plain.includes('says:')); assert.ok(!extracted.plain.includes('Message:'));
    assert.ok(!/Sidebar|Quoted|reactions|Hidden|draft|voice note|00:07|React/u.test(extracted.text));
    console.log('Chat extraction and exact source ranges passed.');

    await page.evaluate(() => {
      window.heard = []; window.states = []; window.listeners = []; window.audio = [];
      window.Audio = class {
        constructor() { this.currentTime = 0; audio.push(this); }
        play() { this.playing = true; return Promise.resolve(); }
        pause() { this.playing = false; } load() {} removeAttribute() {}
      };
      window.browser = {
        runtime: { getURL: file => `/extension/${file}`,
          onMessage: { addListener: fn => listeners.push(fn), removeListener: fn => listeners.splice(listeners.indexOf(fn), 1) },
          sendMessage: async message => {
            if (message.type === 'openread:state') states.push(message.state);
            if (message.type === 'health') return { ok: true, voices: OpenReadCore.voices.map(voice => ({ id: voice.id, available: true })) };
            if (message.type === 'synthesize') { heard.push(message.text); return { ok: true, audio: 'fixture', words: [...message.text.matchAll(/\S+/gu)].map((m, i) => ({ offset: m.index, length: m[0].length, start: i, end: i + .8 })) }; }
            return { ok: true };
          } }, storage: { local: { get: async () => ({}), set: async () => {} } }
      };
      window.send = (action, value) => new Promise(resolve => listeners[0]({ type: 'openread:command', action, value }, {}, resolve));
    });
    for (const name of ['player', 'highlighter', 'glass', 'settings', 'content']) await script(name);
    console.log('Page player connected.');
    // Keep the production shadow closed; inspect a separate real Settings view.
    await page.evaluate(() => {
      window.testView = new OpenReadSettings({ container: document.body, assetURL: file => `/extension/${file}`, command: send });
      testView.update(states.at(-1));
    });
    const view = page.getByRole('region', { name: 'OpenRead settings' });
    await view.getByRole('button', { name: 'Reading options', exact: true }).click();
    assert.equal(await view.locator('#source').inputValue(), 'chat');
    assert.ok(await view.getByRole('switch', { name: 'Announce senders' }).isChecked());
    await view.getByRole('button', { name: 'Listen to chat', exact: true }).click();
    await page.waitForFunction(() => states.at(-1).status === 'playing');
    console.log('Chat playback started.');
    // Explicitly advance the controlled media clock, then finish each message.
    const highlights = await page.evaluate(() => {
      const item = OpenReadExtract(document, { mode: 'chat' }).items[0];
      let stale = false; const layer = document.createElement('div'); document.body.append(layer);
      const highlighter = new OpenReadHighlighter({ layer, follow: false, onStale: () => { stale = true; } });
      highlighter.show(item, 0, 4); const senderMarks = layer.children.length;
      highlighter.show(item, item.text.indexOf('everyone'), 8); const bodyMarks = layer.children.length;
      highlighter.clear(); const cleared = layer.children.length; highlighter.destroy(); layer.remove();
      return { stale, senderMarks, bodyMarks, cleared };
    });
    assert.deepEqual(highlights, { stale: false, senderMarks: 0, bodyMarks: 1, cleared: 0 });
    for (let i = 0; i < 6; i++) {
      await page.evaluate(() => { audio[0].onended(); });
      await page.waitForFunction(index => states.at(-1).status === 'ended' || states.at(-1).index > index && states.at(-1).status === 'playing', i);
    }
    assert.deepEqual(await page.evaluate(() => heard), extracted.messages);
    assert.equal(await page.evaluate(() => states.at(-1).status), 'ended');
    await page.evaluate(() => send('set-preference', { key: 'announceSenders', value: false }));
    assert.equal(await page.evaluate(() => states.at(-1).preferences.announceSenders), false);
    await page.evaluate(() => send('toggle-playback'));
    assert.equal(await page.evaluate(() => heard[6]), 'Hello everyone! See the walking route. Bring water.');
    await page.evaluate(() => { document.querySelector('header [title]').setAttribute('title', 'Different chat'); });
    await page.waitForFunction(() => states.at(-1).status === 'idle' && /conversation changed/u.test(states.at(-1).error));
    assert.equal(await page.evaluate(() => audio[0].playing), false);
    const beforeAppend = await page.evaluate(() => heard.length);
    await page.evaluate(() => {
      const node = document.createElement('div'); node.setAttribute('data-pre-plain-text', '[01:00, 25/10/2026] New person:');
      node.innerHTML = '<span class="selectable-text">A new arrival.</span>'; document.querySelector('#main [role=application]').append(node);
    });
    assert.equal(await page.evaluate(() => heard.length), beforeAppend);
    await page.evaluate(() => { testView.update(states.at(-1)); testView.show(); });
    await view.getByRole('button', { name: 'Refresh loaded messages', exact: false }).click();
    assert.equal(await page.evaluate(() => states.at(-1).messageCount), 7);
    assert.equal(await page.evaluate(() => states.at(-1).status), 'idle');
    // Empty/unsupported layouts stay empty instead of reading the sidebar.
    await page.evaluate(() => { document.querySelector('#main').remove(); });
    const empty = await page.evaluate(() => OpenReadExtract(document, { mode: 'chat' }).items.length);
    assert.equal(empty, 0);
    await page.evaluate(() => { __openread.close(); testView.destroy(); });
    await page.goto('https://example.com/fixture'); await script('core'); await script('extract');
    assert.equal(await page.evaluate(() => OpenReadChat.available(document)), false);
    assert.equal(await page.evaluate(() => OpenReadExtract(document, { mode: 'chat' }).items.length), 0);
    // Article extraction shares the collector; preserve links, list order,
    // metadata filtering and partial selections when chat mode is unavailable.
    await page.setContent('<header>Site navigation</header><main><article><div>Noise before title</div><h1>A reading</h1><div>4 minutes</div><p id="inline">One <strong>bold</strong> idea <a href="https://example.com">linked words</a> remains.</p><ul><li>Parent<ul><li>Child</li></ul>Ending</li></ul><p hidden>Hidden</p></article></main>');
    const article = await page.evaluate(() => {
      const reading = OpenReadExtract(); const item = reading.items.find(item => item.text.includes('linked words'));
      const selection = document.createRange(); const node = document.querySelector('strong').firstChild;
      selection.setStart(node, 1); selection.setEnd(node, 3);
      return { blocks: reading.blocks.map(block => block.text), selected: OpenReadExtract(document, { selection }).text,
        linked: OpenReadRanges(item, item.text.indexOf('linked words'), 12).map(range => range.toString()).join('') };
    });
    assert.deepEqual(article, { blocks: ['A reading', 'One bold idea linked words remains.', 'Parent', 'Child', 'Ending'], selected: 'ol', linked: 'linked words' });
    assert.deepEqual(errors, []);
    console.log('WhatsApp: loaded chat order, incoming/group/outgoing senders, duplicate messages, quote/control/draft exclusion, exact link/emoji mappings, sender highlighting, playback completion, sender toggle, refresh, conversation-change cancellation, no automatic new-message playback, closed unsupported layouts.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
