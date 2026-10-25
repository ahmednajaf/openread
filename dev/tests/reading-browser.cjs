/* Complete a real multi-passage reading; check every replaced word marker. */
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
process.env.PLAYWRIGHT_BROWSERS_PATH ||= path.join(root, '.local/browsers');
const { webkit, chromium } = require('playwright');
const chromiumMode = process.env.BROWSER === 'chromium';
(async () => {
  const browser = await (chromiumMode ? chromium : webkit).launch({ headless: true, ...(chromiumMode ? { executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' } : {}) });
  const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
  if (chromiumMode) await page.context().grantPermissions(['local-network-access'], { origin: 'http://127.0.0.1:4173' });
  const errors = []; const spoken = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('requestfailed', r => console.error('Request failed:', r.url().split('?')[0], r.failure()?.errorText));
  page.on('console', m => { if (m.type() === 'error') console.error(m.text()); });
  page.on('request', r => { if (r.url().endsWith('/synthesize')) spoken.push(r.postDataJSON().text); });
  await page.addInitScript(() => {
    const play = HTMLMediaElement.prototype.play; window.testMedia = [];
    HTMLMediaElement.prototype.play = function () { if (!window.testMedia.includes(this)) window.testMedia.push(this); return play.call(this); };
  });
  await page.route('**/demo/reading-regression.html', route => route.fulfill({ contentType: 'text/html', body: `<!doctype html><html lang="en"><head><title>Reading regression</title><style>body{font:24px/1.7 Georgia;margin:80px;max-width:620px}a{color:blue}</style>${['core','extract','player','highlighter','glass','settings'].map(name => `<script defer src="/extension/${name}.js"></script>`).join('')}<script defer src="/demo/bridge.js"></script></head><body><header>Website navigation</header><button id="launch">Open OpenRead</button><main><article><div>Top-of-page clutter</div><h1>Read this page.</h1><div>4 minutes</div><p class="readingTime">7 min read</p><p>First <a href="https://example.com/destination">linked words</a> stay together.</p><ul><li>A parent bullet.<ul><li>A nested bullet.</li></ul>Parent ending.</li></ul><p>This is the final sentence.</p></article><footer>Subscribe and share</footer></main></body></html>` }));
  await page.route('**/extension/highlighter.js', async route => {
    const source = await fs.readFile(path.join(root, 'extension/highlighter.js'), 'utf8');
    await route.fulfill({ contentType: 'application/javascript', body: source + `\nwindow.testWords=[];window.testSticky=0;const originalShow=OpenReadHighlighter.prototype.show;OpenReadHighlighter.prototype.show=function(item,offset,length){const old=[...this.layer.children];const text=OpenReadRanges(item,offset,length).map(r=>r.toString()).join('');originalShow.call(this,item,offset,length);if(old.some(n=>n.isConnected))window.testSticky++;window.testWords.push(text);};` });
  });
  try {
    await page.goto('http://127.0.0.1:4173/demo/reading-regression.html');
    const settings = page.getByRole('region', { name: 'OpenRead settings' }); await settings.waitFor();
    await settings.locator('#speed').evaluate(input => { input.value = '2.5'; input.dispatchEvent(new Event('input', { bubbles: true })); });
    const original = await page.locator('article').innerHTML();
    await settings.getByRole('button', { name: 'Listen to page', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('[data-openread-host]').shadowRoot.querySelectorAll('.word-marker').length, null, { timeout: 90000 });
    await page.screenshot({ path: path.join(root, 'test-results/reading-linked-words.png') });
    await page.waitForFunction(() => document.querySelector('[data-openread-host]').shadowRoot.querySelector('.session-label').textContent === 'Finished', null, { timeout: 120000 });
    const reading = await page.evaluate(() => ({ words: window.testWords, sticky: window.testSticky, media: window.testMedia.length, marks: document.querySelector('[data-openread-host]').shadowRoot.querySelectorAll('.word-marker').length, oldCSS: CSS.highlights?.has('openread-word') }));
    assert.deepEqual(spoken, ['Read this page.', 'First linked words stay together.', 'A parent bullet.', 'A nested bullet.', 'Parent ending.', 'This is the final sentence.']);
    assert.equal(reading.media, 1); assert.equal(reading.sticky, 0); assert.equal(reading.marks, 0); assert.ok(!reading.oldCSS);
    assert.ok(reading.words.includes('linked')); assert.ok(reading.words.includes('words')); assert.ok(reading.words.includes('sentence.'));
    assert.equal(await page.locator('article').innerHTML(), original);
    await page.locator('#launch').click(); await settings.waitFor();
    assert.equal(await settings.locator('.session-label').textContent(), 'Finished');
    await settings.getByRole('button', { name: 'Listen again', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('[data-openread-host]').shadowRoot.querySelector('.popover').hidden);
    await page.locator('#launch').click(); await settings.waitFor(); await settings.getByRole('button', { name: 'Stop', exact: true }).click();
    assert.equal(await page.evaluate(() => document.querySelector('[data-openread-host]').shadowRoot.querySelectorAll('.word-marker').length), 0);
    assert.deepEqual(errors, []);
    console.log(`${chromiumMode ? 'Chromium' : 'WebKit'}: completed all 6 real voice passages on one media element, linked words spoken and highlighted, metadata excluded, no retained marks, restart and stop work.`);
  } catch (error) {
    console.error(await page.evaluate(() => ({ notice: document.querySelector('[data-openread-host]')?.shadowRoot?.querySelector('.notice')?.textContent, session: document.querySelector('[data-openread-host]')?.shadowRoot?.querySelector('.session-label')?.textContent, words: window.testWords?.length, media: window.testMedia?.map(a => ({ paused:a.paused, time:a.currentTime, error:a.error?.message })) })));
    await page.screenshot({ path: path.join(root, 'test-results/reading-failure.png') }); throw error;
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
